#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用开屏广告屏蔽插件 —— 透明化版（v0.0.3）
//
// 迭代教训：
//  v0.0.1 掐断 show/load       -> 卡启动页（App 等不到广告结束回调）
//  v0.0.2 压 fetchDelay        -> 不卡了，但掌盟不读 GDT 时长，广告仍在
//  v0.0.3 本版：完整保留广告的"加载->展示->计时->结束->回调"全链，
//         只把广告视图变透明（alpha=0），让人看不见。
//         不设 hidden（避免被 isShowInScreen 判定"展示失败"而重弹），
//         不碰任何生命周期/判定/回调方法，App 照常进主界面。
//
// 已适配 App（依据真机探针日志）：
//   · 掌盟 com.tencent.ied.app.lolbible —— 广点通 GDT 开屏
//     广告在独立 UIWindow(level=1001) 全屏展示，控制器 TGGDTSplashViewController
// ============================================================================

static BOOL splash_adblock_enabled(void) {
    return [[SplashAdBlockConfig splash_adblock_shared] splash_adblock_isEnabled];
}

// ---------- 轻量日志（记录动作，方便验证；无常驻轮询） ----------
static NSString *splash_adblock_logPath(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSArray *parts = [bundle componentsSeparatedByString:@"."];
    NSString *tag = parts.lastObject ?: bundle;
    return [@"/var/mobile/Documents/" stringByAppendingPathComponent:
            [NSString stringWithFormat:@"SplashAdBlock_%@.log", tag]];
}

static void splash_adblock_log(NSString *line) {
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = splash_adblock_logPath();
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:data];
        [h closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}

// 递归把视图树 alpha 归零（不设 hidden，避免触发"展示失败"重弹）
static void splash_adblock_fadeTree(UIView *view) {
    if (!view) return;
    view.alpha = 0.0;
    for (UIView *sub in view.subviews) {
        splash_adblock_fadeTree(sub);
    }
}

// 一次性延迟淡出（固定 4 次、约 0.8s 内全部跑完即止；不是持续轮询，不耗电）
static void splash_adblock_scheduleFade(UIViewController *vc) {
    __weak UIViewController *weakVC = vc;
    NSArray *delays = @[@0.02, @0.1, @0.3, @0.7];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongVC = weakVC;
            if (!strongVC) return;
            UIView *adWindow = strongVC.view.window;
            if (!adWindow) return;
            splash_adblock_fadeTree(adWindow);
            splash_adblock_log(@"[fade] ad window tree alpha -> 0");
        });
    }
}

%hook TGGDTSplashViewController

// 广告 VC 出现：调 orig 保证完整生命周期，然后延迟把广告 window 变透明
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!splash_adblock_enabled()) return;
    splash_adblock_log(@"[hook] TGGDTSplashViewController viewDidAppear");
    splash_adblock_scheduleFade(self);
}

%end

%hook TGGDTSplashViewManager

// showAllSubView 是掌盟把所有广告子视图加进来的地方；orig 后立刻透明化
- (void)showAllSubView {
    %orig;
    if (!splash_adblock_enabled()) return;
    splash_adblock_log(@"[hook] TGGDTSplashViewManager showAllSubView");
    // 掌盟自带的"隐藏所有子视图"方法（官方路径，不碰回调）
    [self hiddenAllSubView];
}

%end

%ctor {
    @autoreleasepool {
        (void)splash_adblock_enabled();
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        splash_adblock_log([NSString stringWithFormat:@"=== SplashAdBlock active (transparent v0.0.3) bundle=%@ ===", bundle]);
    }
}
