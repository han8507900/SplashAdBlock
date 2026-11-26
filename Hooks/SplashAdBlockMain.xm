#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用开屏广告屏蔽插件 —— 正式屏蔽版
//
// 一个 dylib 通过 plist 的 Bundles 注入多个目标 App，按 Bundle ID 分流策略。
// 核心原则：在广告"数据源层/展示入口"拦截，让广告根本不加载、不显示，
//           不做事后 hidden 视图（会闪）、不做高频轮询（耗电）。
//
// 已适配 App（依据真机探针日志）：
//   · 掌盟 com.tencent.ied.app.lolbible
//     广点通 GDT 开屏链：TGGDTSplashViewController -> TGGDTSplashWindowView
//                        -> GDTSplashAd(showSplashWithOrder:...)
//     广告在独立 UIWindow(level=1001) 上全屏展示。
//
// 后续新增 App：只需在 plist 追加 Bundle ID，并在下方 hook 区加对应类。
// ============================================================================

static BOOL splash_adblock_enabled(void) {
    return [[SplashAdBlockConfig splash_adblock_shared] splash_adblock_isEnabled];
}

// ---------- 轻量日志（记录拦截动作，方便验证；无轮询） ----------
static NSString *splash_adblock_logPath(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSArray *parts = [bundle componentsSeparatedByString:@"."];
    NSString *tag = parts.lastObject ?: bundle;
    return [@"/var/mobile/Documents/" stringByAppendingPathComponent:
            [NSString stringWithFormat:@"SplashAdBlock_%@.log", tag]];
}

static void splash_adblock_log(NSString *line) {
    NSString *text = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = splash_adblock_logPath();
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (h) {
        [h seekToEndOfFile];
        [h writeData:text];
        [h closeFile];
    } else {
        [text writeToFile:path atomically:YES];
    }
}

// ===========================================================================
// 掌盟 / 广点通 GDT 开屏
//
// 拦截点来自真机探针日志，不是猜测：
//  1) GDTSplashAd showSplashWithOrder:... —— 广点通把开屏显示出来的入口，
//     拦掉后广告不加载/不显示，最干净，无闪现、无轮询。
//  2) TGGDTSplashViewController / TGGDTSplashWindowView 的
//     splashViewShowWithModel:... —— 掌盟封装层展示入口，双保险。
//  3) TGGDTSplashViewManager showAllSubView —— 再兜一层，防止走别的 show 路径。
//
// 注意：不碰 viewDidAppear/生命周期，App 启动流程照常走，不会卡启动页。
// ===========================================================================

%hook GDTSplashAd

- (void)showSplashWithOrder:(id)arg1 withCustomUI:(id)arg2 {
    if (!splash_adblock_enabled()) { %orig; return; }
    splash_adblock_log(@"[blocked] GDTSplashAd showSplashWithOrder:withCustomUI:");
}

- (void)showSplashWithOrder:(id)arg1 withCustomUI:(id)arg2 inContainerView:(id)arg3 {
    if (!splash_adblock_enabled()) { %orig; return; }
    splash_adblock_log(@"[blocked] GDTSplashAd showSplashWithOrder:withCustomUI:inContainerView:");
}

// 预加载订单也拦掉，减少广告请求与流量
- (void)preLoadSplashOrder:(id)arg1 {
    if (!splash_adblock_enabled()) { %orig; return; }
}

- (void)loadAdAndShowSplashWithCustomUIModel:(id)arg1 {
    if (!splash_adblock_enabled()) { %orig; return; }
    splash_adblock_log(@"[blocked] GDTSplashAd loadAdAndShowSplashWithCustomUIModel:");
}

%end

%hook TGGDTSplashViewController

- (void)splashViewShowWithModel:(id)arg1 animBegin:(id)arg2 animEnd:(id)arg3 cacheWebView:(id)arg4 {
    if (!splash_adblock_enabled()) { %orig; return; }
    splash_adblock_log(@"[blocked] TGGDTSplashViewController splashViewShowWithModel");
}

%end

%hook TGGDTSplashWindowView

- (void)splashViewShowWithModel:(id)arg1 animBegin:(id)arg2 animEnd:(id)arg3 cacheWebView:(id)arg4 {
    if (!splash_adblock_enabled()) { %orig; return; }
    splash_adblock_log(@"[blocked] TGGDTSplashWindowView splashViewShowWithModel");
}

%end

%hook TGGDTSplashViewManager

- (void)showAllSubView {
    if (!splash_adblock_enabled()) { %orig; return; }
}

%end

%ctor {
    @autoreleasepool {
        (void)splash_adblock_enabled();
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        splash_adblock_log([NSString stringWithFormat:@"=== SplashAdBlock active (block mode) bundle=%@ ===", bundle]);
    }
}
