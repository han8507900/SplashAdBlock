#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用屏蔽插件（v0.2.0）
//
// 已精准适配（屏蔽逻辑一行未改）：
//  · 掌盟 com.tencent.ied.app.lolbible —— 广点通 GDT 开屏（透明化）
//  · 闪联 com.shanlian.pro             —— 评分弹窗
//  · 什么值得买 com.smzdm.client.ios   —— SMFullWindowAdView 开屏（精准透明化）
//  · 直播吧 com.zhibo8.tenyears        —— ZBSplashView 开屏（精准透明化）
//                                        + 提前 displayRootViewController 消黑屏
//
// v0.2.0 微博启动图长等待修复（相对 v0.1.9）：
//  背景：v0.1.9 在「广告 VC」WBAdSdkNewRootViewController 上找切主界面入口，
//        真机日志证实该 VC 仅有 12 个生命周期方法，只命中无效的
//        dismissViewControllerAnimated:（关广告 VC 不切主界面），启动图仍等满 ~12s。
//        v0.1.9 的 [SIG] 日志给出正解：启动页 VC WBLaunchNewViewController（66 方法）
//        自带 adld_advanceShowAppContent（官方"广告完成→进主界面"推进方法）、
//        adld_preloadHomeViewController、_showAppContent，以及 splashWaitSemaphore
//        （正是 12s 等待的信号量根源）。竞品 WeiboNoAds.dylib 只过滤信息流，
//        开屏不归它管，故不能照抄；正解是走微博自己的完成路径。
//  本版：hook 启动页 VC WBLaunchNewViewController 的 viewDidLoad 保存活实例（__weak）；
//        广告出现时在「活的启动页 VC」上调用 adld_advanceShowAppContent 等官方方法，
//        主界面立即挂载，不等广告计时。保留 WBAdSdkFlashAdView 精准 fade 兜底。
//  · 移除 v0.1.9 的 SIG 签名 dump 探针与广告 VC 上的无效 dismiss 尝试。
//  日志仍为固定单文件覆盖写（v0.1.9 改造，用户已确认）：首行带版本+时间戳，
//  启动时清理历史累积日志；无常驻轮询；block 用 __weak；
//  包名不变。其他 App hook 一行未改。
// ============================================================================

static BOOL splash_adblock_enabled(void) {
    return [[SplashAdBlockConfig splash_adblock_shared] splash_adblock_isEnabled];
}

static BOOL splash_adblock_isShanlian(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.shanlian.pro"];
}

static BOOL splash_adblock_isLolbible(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.tencent.ied.app.lolbible"];
}

static BOOL splash_adblock_isSmzdm(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.smzdm.client.ios"];
}

static BOOL splash_adblock_isZhibo8(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.zhibo8.tenyears"];
}

static BOOL splash_adblock_isWeibo(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.sina.weibo"];
}

// ---------- 轻量日志（固定单文件覆盖写，无常驻监听、无轮询） ----------
#define SPLASH_ADBLOCK_VERSION @"0.2.0"

// 本次会话的唯一标志（版本号 + 启动时间戳），进程内只生成一次。
// 日志文件名继续带标志位，沿用既有约定，便于确认是哪一版、哪一次启动。
static NSString *splash_adblock_runStamp(void) {
    static NSString *stamp = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"MMdd-HHmmss"];
        NSString *ts = [fmt stringFromDate:[NSDate date]];
        stamp = [NSString stringWithFormat:@"v%@_%@", SPLASH_ADBLOCK_VERSION, ts];
    });
    return stamp;
}

static NSString *splash_adblock_logTag(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSArray *parts = [bundle componentsSeparatedByString:@"."];
    NSString *tag = parts.lastObject ?: bundle;
    // 什么值得买末段是 "ios"、直播吧末段是 "tenyears"，都太通用，特判便于查找
    if ([bundle isEqualToString:@"com.smzdm.client.ios"]) tag = @"smzdm";
    if ([bundle isEqualToString:@"com.zhibo8.tenyears"]) tag = @"zhibo8";
    return tag;
}

// v0.1.9：固定单文件名，覆盖写——不再每次启动生成一个新文件（用户反馈日志累积）。
// 可追溯性改由「首行内容」承载：版本 + 时间戳 stamp + bundle 都写在第一行。
static NSString *splash_adblock_logName(void) {
    return [NSString stringWithFormat:@"SplashAdBlock_%@.log", splash_adblock_logTag()];
}

// 只写 App 沙盒 Documents（已验证目标 App 均可写），不再四路径全写。
static NSString *splash_adblock_logPath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = docs.firstObject ?: @"/tmp";
    return [dir stringByAppendingPathComponent:splash_adblock_logName()];
}

// 本次进程是否已经写过首行（决定覆盖 vs 追加）。进程内只判定一次。
static BOOL splash_adblock_logSessionStarted = NO;

static void splash_adblock_log(NSString *line) {
    NSString *path = splash_adblock_logPath();
    NSString *fullLine = [line stringByAppendingString:@"\n"];
    @try {
        if (!splash_adblock_logSessionStarted) {
            // 首次写：覆盖旧内容，先写带标志位的首行，再写本行。
            NSString *header = [NSString stringWithFormat:
                @"=== SplashAdBlock v%@ bundle=%@ stamp=%@ ===\n",
                SPLASH_ADBLOCK_VERSION,
                [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
                splash_adblock_runStamp()];
            NSString *initText = [header stringByAppendingString:fullLine];
            [[initText dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
            splash_adblock_logSessionStarted = YES;
            return;
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[fullLine dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (NSException *e) {
        // 写日志失败不影响屏蔽功能
    }
}

// v0.1.9：启动时清理历史累积的带时间戳日志（旧命名 SplashAdBlock_<tag>_v<...>_<ts>.log），
// 以及旧的固定文件（下次首次写会重建）。只删本插件前缀，不碰 App 自己的数据。
static void splash_adblock_pruneOldLogs(void) {
    NSString *prefix = [NSString stringWithFormat:@"SplashAdBlock_%@_", splash_adblock_logTag()];
    NSString *current = splash_adblock_logName();
    NSMutableArray *dirs = [NSMutableArray array];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.firstObject) [dirs addObject:docs.firstObject];
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (caches.firstObject) [dirs addObject:caches.firstObject];
    [dirs addObject:@"/tmp"];
    [dirs addObject:@"/var/mobile/Documents"];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            // 删所有本插件前缀的 .log（含旧的带时间戳文件与旧固定文件）；
            // 当前固定文件马上会在首次 log 时重建，这里删掉可保证本次是干净的单文件。
            if (![f hasPrefix:prefix] || ![f hasSuffix:@".log"]) continue;
            if ([f isEqualToString:current]) continue;
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
    }
    // 当前固定文件：启动时截断为 0，保证「单文件、只含本次启动」。
    NSString *docDir = docs.firstObject;
    if (!docDir) docDir = @"/tmp";
    NSString *curPath = [docDir stringByAppendingPathComponent:current];
    if ([[NSFileManager defaultManager] fileExistsAtPath:curPath]) {
        [@"" writeToFile:curPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    splash_adblock_logSessionStarted = NO;
}

// /tmp 加载标记：固定文件名覆盖写，内容里带 stamp，一眼可见且不累积。
static void splash_adblock_writeLoadedMarker(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSString *content = [NSString stringWithFormat:
        @"SplashAdBlock LOADED\nbundle=%@\nversion=%@\nstamp=%@\ntime=%.0f\n",
        bundle, SPLASH_ADBLOCK_VERSION, splash_adblock_runStamp(), [[NSDate date] timeIntervalSince1970]];
    NSString *marker = [NSString stringWithFormat:@"/tmp/SplashAdBlock_LOADED_%@",
                        splash_adblock_logTag()];
    [content writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---------- 透明化工具（保留完整展示/计时/回调链） ----------
static void splash_adblock_fadeTree(UIView *view) {
    if (!view) return;
    view.alpha = 0.0;
    for (UIView *sub in view.subviews) splash_adblock_fadeTree(sub);
}

static void splash_adblock_scheduleFade(UIViewController *vc) {
    __weak UIViewController *weakVC = vc;
    NSArray *delays = @[@0.02, @0.1, @0.3, @0.7, @1.5];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongVC = weakVC;
            if (!strongVC) return;
            UIView *adWindow = strongVC.view.window;
            if (!adWindow) return;
            splash_adblock_fadeTree(adWindow);
        });
    }
}

// ---------- 评分弹窗检测（闪联） ----------
static BOOL splash_adblock_textLooksLikeRating(NSString *s) {
    if (!s || s.length == 0) return NO;
    NSArray *keys = @[@"评分", @"评价", @"好评", @"打分", @"星级", @"五星", @"评论一下",
                      @"rate", @"rating", @"review", @"star"];
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL splash_adblock_viewLooksLikeRating(UIView *view, NSString **matchedText) {
    if (!view) return NO;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)view).text;
        if (splash_adblock_textLooksLikeRating(t)) { if (matchedText) *matchedText = t; return YES; }
    }
    if ([view isKindOfClass:[UIButton class]]) {
        NSString *t = [((UIButton *)view) titleForState:UIControlStateNormal];
        if (splash_adblock_textLooksLikeRating(t)) { if (matchedText) *matchedText = t; return YES; }
    }
    for (UIView *sub in view.subviews) {
        if (splash_adblock_viewLooksLikeRating(sub, matchedText)) return YES;
    }
    return NO;
}

#pragma mark - 直播吧：开屏 + 弹窗 探针与保守兜底（仅直播吧生效）

static NSTimeInterval splash_adblock_zhiboLaunchTime = 0;
static NSInteger splash_adblock_zhiboPresentCount = 0;
static NSInteger splash_adblock_zhiboVCCount = 0;
static NSInteger splash_adblock_zhiboWindowCount = 0;
static id splash_adblock_zhiboWindowObserver = nil;

// 探针/兜底只在启动后 120s 内有效：开屏在早期，弹窗可能延后，但不长期驻留。
static BOOL splash_adblock_zhiboProbeActive(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return NO;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - splash_adblock_zhiboLaunchTime;
    return elapsed >= 0 && elapsed <= 120;
}

// 广告类名关键词：国内常见广告 SDK + 中文语义 + 弹窗语义。
// 不含裸 "ad"，避免误伤 Navigation/TabBar 等正常类。
static BOOL splash_adblock_zhiboNameLooksLikeAd(NSString *name) {
    if (!name || name.length == 0) return NO;
    NSString *lower = [name lowercaseString];
    NSArray *keys = @[@"splash", @"launchad", @"openscreen", @"openads", @"flashad",
                      @"startupad", @"splashad", @"全屏广告", @"开屏", @"广告", @"弹窗",
                      @"abu", @"csj", @"pangle", @"jgads", @"busplash", @"gdt",
                      @"ksad", @"sigmob", @"interstitial", @"adview", @"adbanner", @"popup"];
    for (NSString *k in keys) {
        if ([lower rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

// 有限深度、有限行数的视图树 dump，避免日志爆炸。
static void splash_adblock_zhiboDumpTree(UIView *v, NSInteger depth, NSMutableString *out, NSInteger *lines) {
    if (!v || depth > 6 || *lines > 140) return;
    CGRect f = v.frame;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ (%.0f,%.0f %.0fx%.0f) a=%.2f h=%d\n", pad,
        NSStringFromClass([v class]), f.origin.x, f.origin.y, f.size.width, f.size.height,
        v.alpha, v.hidden];
    (*lines)++;
    for (UIView *sub in v.subviews) splash_adblock_zhiboDumpTree(sub, depth + 1, out, lines);
}

// 只对「命中广告类名 + 接近全屏」的 view 做 alpha=0，跳过 root view，不碰主界面。
static void splash_adblock_zhiboFadeRecursive(UIView *v, UIWindow *win, BOOL isRoot) {
    if (!v || isRoot) return;
    NSString *cls = NSStringFromClass([v class]);
    CGRect f = v.frame;
    CGSize s = win.bounds.size;
    BOOL fullscreen = s.width > 0 && f.size.width >= s.width * 0.8
                      && f.size.height >= s.height * 0.5;
    if (fullscreen && splash_adblock_zhiboNameLooksLikeAd(cls)) {
        splash_adblock_log([NSString stringWithFormat:@"[zhibo][MATCH] ad view %@ frame=%@ -> fade",
                            cls, NSStringFromCGRect(f)]);
        splash_adblock_fadeTree(v);
    }
    BOOL childIsRoot = [v isEqual:win.rootViewController.view];
    for (UIView *sub in v.subviews) splash_adblock_zhiboFadeRecursive(sub, win, childIsRoot);
}

static void splash_adblock_zhiboFadeFullscreenAds(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        // 高 level 独立 window：开屏/弹窗常见形态，整棵透明化（不动 window 本身）。
        CGFloat level = w.windowLevel;
        if (level > 100 && level < 3000) {
            splash_adblock_log([NSString stringWithFormat:@"[zhibo][MATCH] high-level window level=%.0f root=%@ -> fade",
                                level, NSStringFromClass([w.rootViewController class])]);
            splash_adblock_fadeTree(w);
            continue;
        }
        for (UIView *v in w.subviews) {
            splash_adblock_zhiboFadeRecursive(v, w, [v isEqual:w.rootViewController.view]);
        }
    }
}

// 新 window 出现事件：抓弹窗最常见形态；限 12 次，120s 后自动移除观察者。
static void splash_adblock_zhiboStartWindowObserver(void) {
    splash_adblock_zhiboWindowObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        if (!splash_adblock_zhiboProbeActive()) return;
        if (splash_adblock_zhiboWindowCount >= 12) return;
        splash_adblock_zhiboWindowCount++;
        UIWindow *w = note.object;
        if (![w isKindOfClass:[UIWindow class]]) return;
        splash_adblock_log([NSString stringWithFormat:@"[zhibo][window#%ld] level=%.0f root=%@",
                            (long)splash_adblock_zhiboWindowCount, w.windowLevel,
                            NSStringFromClass([w.rootViewController class])]);
        NSInteger lines = 0;
        NSMutableString *out = [NSMutableString string];
        for (UIView *v in w.subviews) splash_adblock_zhiboDumpTree(v, 0, out, &lines);
        splash_adblock_log(out);
        if (w.windowLevel > 100 && w.windowLevel < 3000) {
            splash_adblock_log(@"[zhibo][MATCH] high-level window -> fade");
            splash_adblock_fadeTree(w);
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (splash_adblock_zhiboWindowObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:splash_adblock_zhiboWindowObserver];
            splash_adblock_zhiboWindowObserver = nil;
            splash_adblock_log(@"[zhibo] window observer removed");
        }
    });
}

// v0.1.5：开屏已精准 hook（ZBSplashView）、黑屏已解决（displayRootViewController），
// 开屏诊断探针（类名/方法/签名 dump、窗口树 tick、root 记录）全部移除。
// 只保留「弹窗」的事件驱动探针：present VC + 新 window 观察（各限次、120s 自动失效），
// 加 3 次轻量兜底 tick（只在命中时写日志），等弹窗真弹出时抓类名。
static void splash_adblock_zhiboStartProbe(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return;
    splash_adblock_zhiboLaunchTime = [[NSDate date] timeIntervalSince1970];
    splash_adblock_log(@"[zhibo] popup probe active (splash already precise-hooked)");
    NSArray *ticks = @[@1.5, @6.0, @20.0];
    for (NSNumber *t in ticks) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!splash_adblock_zhiboProbeActive()) return;
            splash_adblock_zhiboFadeFullscreenAds(); // 命中才写日志，无命中静默
        });
    }
    splash_adblock_zhiboStartWindowObserver();
}

#pragma mark - 微博：启动页 VC 提前进主界面（修复启动图长等待，仅微博生效）

// v0.1.9 教训：在「广告 VC」WBAdSdkNewRootViewController 上找切主界面入口无效——
// 真机日志确认该 VC 仅 12 个生命周期方法，只命中 dismissViewControllerAnimated:，
// 关掉广告 VC 并不会让主界面提前挂载，启动图仍等满 ~12s。
// v0.1.9 的 [SIG] 真机日志给出正解：入口在「启动页 VC」WBLaunchNewViewController（66 方法）：
//   · adld_advanceShowAppContent       微博官方"广告完成→进主界面"推进方法（首选）
//   · adld_preloadHomeViewController   预加载主界面
//   · _showAppContent                  显示主内容
//   · splashWaitSemaphore             正是 12s 等待的信号量根源
// 竞品 WeiboNoAds.dylib 只过滤信息流广告，开屏不归它管，故不能照抄；
// 正解是走微博自己的完成路径（与直播吧 displayRootViewController 同构）。

// 启动页 VC 活实例（__weak，不延长生命周期，随系统释放自动置 nil）。
static __weak WBLaunchNewViewController *splash_adblock_weiboLaunchVC = nil;

// 兜底：从各 window 的 rootVC / presentedVC 链里找启动页 VC 活实例。
// 只在提前推进时调用一次（dispatch_once 内），无常驻、无轮询。
static WBLaunchNewViewController *splash_adblock_weiboFindLaunchVC(void) {
    WBLaunchNewViewController *saved = splash_adblock_weiboLaunchVC;
    if (saved) return saved;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *vc = w.rootViewController;
        NSInteger depth = 0;
        while (vc && depth < 16) { // 深度上限，防异常 presented 链死循环
            if ([vc isKindOfClass:[WBLaunchNewViewController class]]) {
                return (WBLaunchNewViewController *)vc;
            }
            vc = vc.presentedViewController;
            depth++;
        }
    }
    return nil;
}

// 在「活的启动页 VC」上调用微博官方"提前显示主界面"方法，走它自己的完成路径，
// 不掐广告加载/计时/回调链。dispatch_once 保证整个进程只跑一次，命中一个即停，
// 避免重复推进干扰微博内部状态。全部 respondsToSelector + @try 保护。
static void splash_adblock_weiboAdvanceToContent(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WBLaunchNewViewController *launchVC = splash_adblock_weiboFindLaunchVC();
        if (!launchVC) {
            splash_adblock_log(@"[weibo][advance] no live launch VC, skip");
            return;
        }
        // 按"最像提前进主界面"排序；均为无参 void 方法。
        NSArray *sels = @[@"adld_advanceShowAppContent",
                          @"_showAppContent",
                          @"adld_preloadHomeViewController"];
        for (NSString *sn in sels) {
            SEL sel = sel_registerName([sn UTF8String]);
            if (![launchVC respondsToSelector:sel]) continue;
            @try {
                [launchVC performSelector:sel];
                splash_adblock_log([NSString stringWithFormat:
                    @"[weibo][advance] %@ -> called", sn]);
                break; // 命中一个即停
            } @catch (NSException *e) {
                splash_adblock_log([NSString stringWithFormat:
                    @"[weibo][advance] %@ EXCEPTION %@", sn, [e reason] ?: @"?"]);
            }
        }
    });
}

#pragma mark - 微博开屏容器（精准 hook，仅微博生效）

// v0.1.6 日志确认 WBAdSdkFlashAdView(393x852) 是真全屏广告容器，
// 素材子视图 WBAdSdkImageContentView / WBAdXSplashComponentView / WBMPSinglePageView。
// 三时机整棵树 alpha=0（不 hidden、不移除、不碰广告 SDK 计时/回调链）。
%hook WBAdSdkFlashAdView
- (void)didMoveToWindow {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[weibo][hook] WBAdSdkFlashAdView -> fade");
    });
    splash_adblock_fadeTree(self);
}
- (void)layoutSubviews {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    splash_adblock_fadeTree(self);
}
- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    if (!hidden) splash_adblock_fadeTree(self);
}
%end

// 启动页 VC：保存活实例，供提前进主界面时在正确对象上调用官方推进方法。
// 这是 v0.1.9 [SIG] 日志确认的正解对象（广告 VC 上没有切主界面方法）。
%hook WBLaunchNewViewController
- (void)viewDidLoad {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    splash_adblock_weiboLaunchVC = self;
    splash_adblock_log(@"[weibo][hook] WBLaunchNewViewController viewDidLoad -> saved");
}
%end

// 微博广告 window 的 root VC。在它 viewDidAppear 时（广告 view 已出现），
// 触发「提前进主界面」：在活的启动页 VC 上调用微博官方 adld_advanceShowAppContent，
// 让主界面立即挂载，不等满广告计时。保留 %orig，不掐广告加载/计时/回调链。
%hook WBAdSdkNewRootViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    splash_adblock_log(@"[weibo][hook] WBAdSdkNewRootViewController viewDidAppear");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        splash_adblock_weiboAdvanceToContent();
    });
}
%end

#pragma mark - 掌盟开屏（仅掌盟生效）

%hook TGGDTSplashViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isLolbible()) return;
    splash_adblock_log(@"[hook] TGGDTSplashViewController viewDidAppear");
    splash_adblock_scheduleFade(self);
}
%end

%hook TGGDTSplashViewManager
- (void)showAllSubView {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isLolbible()) return;
    splash_adblock_log(@"[hook] TGGDTSplashViewManager showAllSubView");
    [self hiddenAllSubView];
}
%end

#pragma mark - 什么值得买开屏容器（精准 hook，仅 smzdm 生效）

// SMFullWindowAdView 是真机上确认的全屏广告容器。
// 在它出现的各时机把整棵树 alpha=0（不 hidden、不移除、不碰广告 SDK 的计时/回调），
// 保留完整展示流程 -> 不卡启动、不被判"展示失败"重弹。
%hook SMFullWindowAdView
- (void)didMoveToWindow {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isSmzdm()) return;
    splash_adblock_log(@"[hook] SMFullWindowAdView didMoveToWindow -> fade");
    splash_adblock_fadeTree(self);
}
- (void)layoutSubviews {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isSmzdm()) return;
    splash_adblock_fadeTree(self);
}
- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isSmzdm()) return;
    if (!hidden) splash_adblock_fadeTree(self);
}
%end

#pragma mark - 直播吧开屏容器（精准 hook，仅直播吧生效）

// v0.1.0 日志确认：ZBSplashView(393x852) 是开屏全屏容器，
// 素材视图 ZBSplashAdMaterialView / ZBSplashAdNewSlideInteractionView 都是它的子视图。
// 三个时机都 fade：覆盖 view 从 window 出现、后续布局、以及复用时再次显示。
// 只做 alpha=0，不 hidden、不移除、不跳过、不碰广告 SDK 的计时/回调链。
%hook ZBSplashView
- (void)didMoveToWindow {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return;
    splash_adblock_log(@"[zhibo][hook] ZBSplashView didMoveToWindow -> fade");
    splash_adblock_fadeTree(self);
}
- (void)layoutSubviews {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return;
    splash_adblock_fadeTree(self);
}
- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return;
    if (!hidden) splash_adblock_fadeTree(self);
}
%end

#pragma mark - 直播吧开屏 VC（v0.1.5：移除生命周期探针，保留提前显示主界面修复）

// 黑屏诊断已完成，v0.1.2 的 viewDidLoad/viewDidAppear/viewWillDisappear
// 生命周期日志与 displayRootViewController 调用日志全部移除。只保留修复动作本身。
static inline double splash_adblock_zhiboElapsed(void) {
    return [[NSDate date] timeIntervalSince1970] - splash_adblock_zhiboLaunchTime;
}

%hook ZBSplashAdViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (splash_adblock_enabled() && splash_adblock_isZhibo8()) {
        // v0.1.4：开屏已 fade，立即触发 App 自带的 displayRootViewController，
        // 让主界面在下一 runloop 就挂上（延迟 0.02s，视觉 0 黑屏）。
        // 进程内只主动调用一次；%orig 全保留，不掐断广告加载/计时/回调链。
        static dispatch_once_t earlyDisplayToken;
        dispatch_once(&earlyDisplayToken, ^{
            __weak ZBSplashAdViewController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ZBSplashAdViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                SEL sel = @selector(displayRootViewController);
                if (![strongSelf respondsToSelector:sel]) {
                    splash_adblock_log(@"[zhibo][early] displayRootViewController NOT FOUND -> skip");
                    return;
                }
                @try {
                    splash_adblock_log([NSString stringWithFormat:@"[zhibo][early] call displayRootViewController t=%.2f",
                                        splash_adblock_zhiboElapsed()]);
                    [strongSelf performSelector:sel];
                    splash_adblock_log(@"[zhibo][early] displayRootViewController done");
                } @catch (NSException *e) {
                    splash_adblock_log([NSString stringWithFormat:@"[zhibo][early] EXCEPTION: %@",
                                        [e reason] ?: @"unknown"]);
                }
            });
        });
    }
}
%end

#pragma mark - 系统原生评分弹窗（仅闪联生效）

%hook SKStoreReviewController
+ (void)requestReview {
    if (splash_adblock_enabled() && splash_adblock_isShanlian()) {
        splash_adblock_log(@"[blocked] SKStoreReviewController requestReview");
        return;
    }
    %orig;
}
+ (void)requestReviewInScene:(id)scene {
    if (splash_adblock_enabled() && splash_adblock_isShanlian()) {
        splash_adblock_log(@"[blocked] SKStoreReviewController requestReviewInScene:");
        return;
    }
    %orig;
}
%end

#pragma mark - 全局 VC hook（闪联评分弹窗 + 直播吧/微博弹窗探针）

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    %orig;

    if (!splash_adblock_enabled()) return;

    // ---- 闪联评分弹窗 ----
    if (splash_adblock_isShanlian()) {
        if (!vc) return;
        NSString *vcName = NSStringFromClass([vc class]);
        NSString *title = vc.title;
        NSString *msg = [vc isKindOfClass:[UIAlertController class]] ? ((UIAlertController *)vc).message : nil;
        NSString *matched = nil;
        BOOL hit = splash_adblock_textLooksLikeRating(title)
                || splash_adblock_textLooksLikeRating(msg)
                || splash_adblock_viewLooksLikeRating(vc.view, &matched);
        if (hit) {
            splash_adblock_log([NSString stringWithFormat:@"[MATCH] rating popup VC=%@ matched='%@'",
                                vcName, matched ?: (title ?: (msg ?: @""))]);
            __weak UIViewController *weakVC = vc;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *strongVC = weakVC;
                if (!strongVC) return;
                splash_adblock_fadeTree(strongVC.view);
                [strongVC dismissViewControllerAnimated:NO completion:nil];
                splash_adblock_log(@"[closed] rating popup dismissed");
            });
        }
    }

    // ---- 直播吧：弹窗探针（事件驱动、限 15 次、120s 内） ----
    if (splash_adblock_isZhibo8() && vc && splash_adblock_zhiboProbeActive()
        && splash_adblock_zhiboPresentCount < 15) {
        splash_adblock_zhiboPresentCount++;
        NSString *vcName = NSStringFromClass([vc class]);
        NSString *title = vc.title;
        NSString *msg = [vc isKindOfClass:[UIAlertController class]] ? ((UIAlertController *)vc).message : nil;
        splash_adblock_log([NSString stringWithFormat:@"[zhibo][present] VC=%@ title=%@ msg=%@",
                            vcName, title ?: @"", msg ?: @""]);
        NSInteger lines = 0;
        NSMutableString *out = [NSMutableString string];
        splash_adblock_zhiboDumpTree(vc.view, 0, out, &lines);
        splash_adblock_log(out);
        if (splash_adblock_zhiboNameLooksLikeAd(vcName)) {
            splash_adblock_log([NSString stringWithFormat:@"[zhibo][MATCH] ad-like popup VC=%@ -> fade", vcName]);
            __weak UIViewController *weakVC = vc;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *strongVC = weakVC;
                if (!strongVC || !splash_adblock_zhiboProbeActive()) return;
                splash_adblock_fadeTree(strongVC.view);
            });
        }
    }

    // v0.1.9：微博开屏靠「精准 fade + 广告 VC viewDidAppear 提前切主界面」，无探针。
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *cls = NSStringFromClass([self class]);

    // ---- 直播吧：命中广告特征 VC -> 事件驱动兜底（一次性延迟补刀） ----
    if (splash_adblock_zhiboProbeActive()) {
        if (splash_adblock_zhiboVCCount < 60) {
            splash_adblock_zhiboVCCount++;
            if (splash_adblock_zhiboNameLooksLikeAd(cls)) {
                splash_adblock_log([NSString stringWithFormat:@"[zhibo][MATCH] ad-like VC=%@ -> fade", cls]);
                __weak UIViewController *weakSelf = self;
                for (NSNumber *d in @[@0.02, @0.2, @0.7]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        UIViewController *strongSelf = weakSelf;
                        if (!strongSelf || !splash_adblock_zhiboProbeActive()) return;
                        splash_adblock_fadeTree(strongSelf.view);
                    });
                }
            }
        }
    }
    // v0.1.7：微博不再做逐 VC 泛化 fade（误伤启动页根因），开屏靠 WBAdSdkFlashAdView 精准 hook。
}
%end

%ctor {
    @autoreleasepool {
        (void)splash_adblock_enabled();
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";

        // 固定名加载标记（覆盖写，不累积）+ 启动时一行日志（带标志位）
        splash_adblock_writeLoadedMarker();
        splash_adblock_log([NSString stringWithFormat:@"=== SplashAdBlock active v%@ bundle=%@ stamp=%@ ===",
                            SPLASH_ADBLOCK_VERSION, bundle, splash_adblock_runStamp()]);

        // 清理本 App 历史日志，只保留最近 2 份（当前这份是最新的，不会被删）
        splash_adblock_pruneOldLogs();

        // 直播吧：启动弹窗探针；微博：提前进主界面由广告 VC viewDidAppear 事件驱动，
        // 在启动页 VC 上调用官方 adld_advanceShowAppContent（不再 ctor 里枚举）。
        // 其余 App 内部门控直接返回。
        splash_adblock_zhiboStartProbe();
    }
}
