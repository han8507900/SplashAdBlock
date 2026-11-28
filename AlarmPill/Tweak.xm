#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

@interface SpringBoard : UIApplication
@end

// ============================================================================
// 隐藏睡眠闹钟胶囊 · v9（v8 基础上的耗电/内存加固版）
//
// v8 已经把"20ms 常驻全树扫描"改成 swizzle 事件驱动，方向是对的；v9 只做加固，
// 不改变任何"隐藏哪些视图"的判定，视觉行为与 v8 一致（不闪现、大时间日期正常）。
//
// v9 修掉的 4 处（逐行审计发现）：
//   ① 探测定时器**没有超时上限**：若 CSAdjunctItemView 一直不加载（用户不开睡眠模式、
//      或将来系统改类名），1Hz 主队列 timer 会在 SpringBoard 里**永久运行**到重启。
//      → 探测封顶 30 次（约 30s）后自我停止；之后改由「锁屏完成」事件驱动的一次性
//        探测链（0.3s ×4）补装，依旧不常驻。
//   ② 兜底全树扫描原来**每次锁屏都跑**，而 swizzle 装好后它纯属冗余。
//      → 每个进程最多 3 次（AxsScanBudget），用完不再扫。
//   ③ 扫描里每个节点都调 NSStringFromClass 分配一个 NSString。
//      → 改用 object_getClassName 的 C 字符串 + strcmp，零分配。
//   ④ 每次 SpringBoard 启动都重写日志文件（与"定版不产生日志文件"的既定规矩冲突）。
//      → 编译期开关 AXS_DEBUG_LOG 默认 0：不写日志，并在启动时删除历史残留文件；
//        需要排查时改成 1 重新编译即可（日志仍是固定单文件、每次启动截断，不累积）。
//
// 内存审计结论（无泄漏）：class_copyMethodList 有对应 free；dispatch_source_t 在 ARC 下
// 由 ARC 管理，cancel 后无残留；无全局可变集合；AxsHideTree 递归不分配；3 个 IMP 是常量。
// 常驻的只有 1 个 Darwin 通知观察者（SpringBoard 生命周期内不摘除，属必要开销）。
// ============================================================================

// 诊断日志：0 = 定版（不写文件 + 启动清残留）；1 = 排查用
#define AXS_DEBUG_LOG 0

static NSString *const AxsLogPath = @"/var/mobile/Documents/AxsHideAlarmPill.log";

static dispatch_source_t AxsProbeTimer = nil;   // 仅用于等待类加载，装好 swizzle 或超限即停
static BOOL AxsSwizzled = NO;
static int AxsProbeAttempts = 0;
static BOOL AxsLoggedOnce = NO;
static NSInteger AxsScanBudget = 3;             // 兜底扫描额度（每个进程最多 3 次）
static int AxsScanCount = 0;

// 原始实现保存
static void (*AxsOrigSetHidden)(id, SEL, BOOL) = NULL;
static void (*AxsOrigDidMove)(id, SEL) = NULL;
static void (*AxsOrigLayout)(id, SEL) = NULL;

#if AXS_DEBUG_LOG
static void AxsLog(NSString *line) {
    NSString *s = [line stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:AxsLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [s writeToFile:AxsLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
#define AXS_LOG(...) AxsLog([NSString stringWithFormat:__VA_ARGS__])
#else
#define AXS_LOG(...) do {} while (0)
#endif

static void AxsForceHideView(UIView *v) {
    if (!v) return;
    if (!v.hidden) v.hidden = YES;
    if (v.alpha != 0.0) v.alpha = 0.0;
    if (v.userInteractionEnabled) v.userInteractionEnabled = NO;
}

// —— 被 swizzle 的方法实现（事件驱动，零轮询）——

static void AxsForcedSetHidden(id self, SEL _cmd, BOOL hidden) {
    if (AxsOrigSetHidden) AxsOrigSetHidden(self, _cmd, YES);
}

static void AxsForcedDidMove(id self, SEL _cmd) {
    if (AxsOrigDidMove) AxsOrigDidMove(self, _cmd);
    AxsForceHideView((UIView *)self);
}

static void AxsForcedLayout(id self, SEL _cmd) {
    if (AxsOrigLayout) AxsOrigLayout(self, _cmd);
    AxsForceHideView((UIView *)self);
}

// 判断类自身是否实现了某方法（不含继承）
static BOOL AxsClassOwnsMethod(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL own = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(list[i]) == sel) { own = YES; break; }
    }
    free(list);
    return own;
}

static void AxsOverrideMethod(Class cls, SEL sel, IMP newImp, void **origOut) {
    if (AxsClassOwnsMethod(cls, sel)) {
        Method own = class_getInstanceMethod(cls, sel);
        *origOut = (void *)method_getImplementation(own);
        method_setImplementation(own, newImp);
    } else {
        Method inherited = class_getInstanceMethod(class_getSuperclass(cls), sel);
        if (inherited) {
            *origOut = (void *)method_getImplementation(inherited);
            class_addMethod(cls, sel, newImp, method_getTypeEncoding(inherited));
        }
    }
}

// ★ 省电关键：停止探测定时器（异步 cancel，避免在 handler 内取消自身）
static void AxsStopProbeTimer(void) {
    if (!AxsProbeTimer) return;
    dispatch_source_t t = AxsProbeTimer;
    AxsProbeTimer = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_source_cancel(t);
    });
}

// —— 超时上限：类一直不出现时定时器必须自停，不能永久 1Hz 空转 ——
#define AXS_PROBE_MAX 30

// —— 一次性兜底扫描（额度制，非轮询）——

// 用 C 字符串比较，避免每个节点一次 NSString 分配
static BOOL AxsIsTargetView(UIView *v) {
    const char *n = object_getClassName(v);
    if (!n) return NO;
    return strcmp(n, "CSAdjunctItemView") == 0 ||
           strcmp(n, "CSRemoteContentInlineView") == 0 ||
           strcmp(n, "_UIRemoteView") == 0;
}

static int AxsHideTree(UIView *v) {
    if (!v) return 0;
    int n = 0;
    if (AxsIsTargetView(v)) {
        if (!v.hidden) { v.hidden = YES; n++; }
        if (v.alpha != 0.0) v.alpha = 0.0;
        if (v.userInteractionEnabled) v.userInteractionEnabled = NO;
    }
    for (UIView *sub in v.subviews) {
        n += AxsHideTree(sub);
    }
    return n;
}

static void AxsScanOnce(void) {
    if (AxsScanBudget <= 0) return;      // 额度用完：swizzle 已在拦，无需再扫
    AxsScanBudget--;
    AxsScanCount++;

    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *cover = nil;
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.hidden) continue;
            const char *wc = object_getClassName(w);
            if (wc && strstr(wc, "CoverSheet") != NULL) {
                cover = w;
                break;
            }
        }
        if (cover) break;
    }
    if (!cover) return;

    int hidden = AxsHideTree(cover);
    if (!AxsLoggedOnce) {
        AxsLoggedOnce = YES;
        AXS_LOG(@"=== one-shot scan#%d hidden=%d (budget left %ld) ===",
                AxsScanCount, hidden, (long)AxsScanBudget);
    }
}

// 一旦 CSAdjunctItemView 类出现，装 swizzle 并立即停掉定时器
static void AxsInstallSwizzleIfReady(void) {
    if (AxsSwizzled) return;
    Class cls = objc_getClass("CSAdjunctItemView");
    if (!cls) return;

    AxsOverrideMethod(cls, @selector(setHidden:), (IMP)AxsForcedSetHidden,
                      (void **)&AxsOrigSetHidden);
    AxsOverrideMethod(cls, @selector(didMoveToWindow), (IMP)AxsForcedDidMove,
                      (void **)&AxsOrigDidMove);
    AxsOverrideMethod(cls, @selector(layoutSubviews), (IMP)AxsForcedLayout,
                      (void **)&AxsOrigLayout);

    AxsSwizzled = YES;
    AXS_LOG(@"=== swizzle installed -> probe timer STOPPED (zero polling) ===");
    AxsStopProbeTimer();
}

// 定时器每次 fire：先试装，装不上就计数，满 30 次自停
static void AxsProbeTick(void) {
    if (AxsSwizzled) { AxsStopProbeTimer(); return; }
    AxsInstallSwizzleIfReady();
    if (AxsSwizzled) return;
    if (++AxsProbeAttempts >= AXS_PROBE_MAX) {
        AXS_LOG(@"=== probe give-up after %d attempts (class never loaded) ===", AXS_PROBE_MAX);
        AxsStopProbeTimer();
    }
}

// 低频探测定时器：仅在启动初期等待懒加载类出现（有上限，见 AXS_PROBE_MAX）
static void AxsStartProbe(void) {
    if (AxsProbeTimer || AxsSwizzled) return;
    AxsProbeTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                           dispatch_get_main_queue());
    dispatch_source_set_timer(AxsProbeTimer,
                              dispatch_walltime(NULL, 0),
                              1 * NSEC_PER_SEC,
                              500 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(AxsProbeTimer, ^{
        AxsProbeTick();
    });
    dispatch_resume(AxsProbeTimer);
}

// 事件驱动的补装探测：锁屏时若还没装上，用 4 次一次性 tick（0.3s 间隔）重试，
// 不引入任何常驻 timer。装上后立刻补一次兜底扫描。
static void AxsProbeBurst(int remaining) {
    if (AxsSwizzled || remaining <= 0) return;
    AxsInstallSwizzleIfReady();
    if (AxsSwizzled) {
        AXS_LOG(@"=== swizzle installed via lock-event burst ===");
        AxsScanOnce();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AxsProbeBurst(remaining - 1);
    });
}

// 锁屏完成事件：一次性兜底（非持续轮询）
static void AxsOnLockComplete(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object,
                              CFDictionaryRef userInfo) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (AxsSwizzled) {
            AxsScanOnce();
        } else {
            AxsProbeBurst(4);       // 类晚加载时靠事件重试，定时器已超限停掉也不影响
        }
    });
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
#if AXS_DEBUG_LOG
    [@"" writeToFile:AxsLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    AXS_LOG(@"=== tweak v9 loaded (audited: bounded probe, budgeted scan) ===");
#else
    // 定版：不生成任何日志文件，并清掉历史残留（只删本插件自己的那个文件）
    [[NSFileManager defaultManager] removeItemAtPath:AxsLogPath error:nil];
#endif

    // 注册锁屏通知：仅在锁屏那一刻做一次性兜底
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        &AxsOnLockComplete,
        CFSTR("com.apple.springboard.lockcomplete"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    // 1 秒后启动有上限的低频探测，等待懒加载类出现（装好即停，最多 30 次）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        AxsStartProbe();
    });
}

%end
