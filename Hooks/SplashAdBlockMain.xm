#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用开屏广告屏蔽插件 —— 秒跳过版（v0.0.2）
//
// 重要教训（v0.0.1 卡启动页）：
//   上一版直接 hook show/load 让广告"根本不加载"，但 App 是靠广告结束后的
//   dismiss / completion 回调才进入主界面的。把 show 截断 = 回调永不触发
//   = 卡在启动页。
//
// 本版策略：不阻断任何展示与加载方法，保留完整回调链，只把广告停留时长
//   fetchDelay 压到极短（0.05 秒）。广告几乎不可见，但 App 启动流程照常。
//
// 已适配 App（依据真机探针日志）：
//   · 掌盟 com.tencent.ied.app.lolbible —— 广点通 GDT 开屏
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

// ===========================================================================
// 掌盟 / 广点通 GDT 开屏 —— 秒跳过
//
// 日志确认 GDTSplashAd 有 fetchDelay / setFetchDelay:，这是广点通开屏的
// 停留时长。getter 和 setter 都压到 0.05 秒后，SDK 仍会正常走完
// "展示→结束→回调"全过程，App 收到结束回调后正常进主界面，不会卡启动页。
//
// 关键：绝不再拦截 showSplashWithOrder / loadAdAndShowSplash 等方法。
// ===========================================================================

static double const splash_adblock_short_delay = 0.05;

%hook GDTSplashAd

- (double)fetchDelay {
    if (!splash_adblock_enabled()) return %orig;
    splash_adblock_log(@"[fast-skip] GDTSplashAd fetchDelay -> 0.05");
    return splash_adblock_short_delay;
}

- (void)setFetchDelay:(double)arg1 {
    if (!splash_adblock_enabled()) { %orig; return; }
    %orig(splash_adblock_short_delay);
}

%end

%ctor {
    @autoreleasepool {
        (void)splash_adblock_enabled();
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        splash_adblock_log([NSString stringWithFormat:@"=== SplashAdBlock active (fast-skip v0.0.2) bundle=%@ ===", bundle]);
    }
}
