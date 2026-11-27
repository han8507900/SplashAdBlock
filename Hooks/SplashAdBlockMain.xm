#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用屏蔽插件（v0.1.6）
//
// 已精准适配（屏蔽逻辑一行未改）：
//  · 掌盟 com.tencent.ied.app.lolbible —— 广点通 GDT 开屏（透明化）
//  · 闪联 com.shanlian.pro             —— 评分弹窗
//  · 什么值得买 com.smzdm.client.ios   —— SMFullWindowAdView 开屏（精准透明化）
//  · 直播吧 com.zhibo8.tenyears        —— ZBSplashView 开屏（精准透明化）
//                                        + 提前 displayRootViewController 消黑屏
//
// v0.1.7 微博修复（相对 v0.1.6）：
//  背景：v0.1.6 探针日志确认开屏真容器为 WBAdSdkFlashAdView(level=2100 window)，
//        但泛化 fade 误伤了启动页 WBLaunchNewViewController（"wblaunch" 关键词命中）
//        和 level=1010 popover 背景 -> 广告没了却持续黑屏。
//  · 开屏改为精准 hook WBAdSdkFlashAdView（didMoveToWindow/layoutSubviews/setHidden
//    三时机整棵树 alpha=0），不 hidden、不移除、不掐回调。
//  · 彻底移除微博泛化 fade（关键词命中 + 高 level window 整棵淡掉）、逐 VC fade；
//    启动页不再被淡掉，等待期显示正常启动图而非黑底。
//  · 弹窗探针保留（present VC / 新 window，只 dump 不 fade，限次限时 120s）。
//  · 新增关键类签名 dump（[weibo][SIG]），找类似直播吧 displayRootViewController
//    的提前进主界面安全入口——拿到后下一版可消掉串行等待。
//  全部微博逻辑 bundle 门控，其他四个 App 的 hook 一行未改。无常驻轮询；
//  日志单路径 + 自动清理（每目录留最近 2 份）；包名不变。
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

// ---------- 轻量日志（单路径 + 自动清理，无常驻监听、无轮询） ----------
#define SPLASH_ADBLOCK_VERSION @"0.1.7"

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

// 文件名带标志位：SplashAdBlock_<tag>_v<版本>_<时间戳>.log
static NSString *splash_adblock_logName(void) {
    return [NSString stringWithFormat:@"SplashAdBlock_%@_%@.log",
            splash_adblock_logTag(), splash_adblock_runStamp()];
}

// 只写 App 沙盒 Documents（已验证目标 App 均可写），不再四路径全写。
static NSString *splash_adblock_logPath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = docs.firstObject ?: @"/tmp";
    return [dir stringByAppendingPathComponent:splash_adblock_logName()];
}

static void splash_adblock_log(NSString *line) {
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = splash_adblock_logPath();
    @try {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:data];
            [h closeFile];
        } else {
            [data writeToFile:path atomically:YES];
        }
    } @catch (NSException *e) {
        // 写日志失败不影响屏蔽功能
    }
}

// 启动时清理本 App 历史日志，每个目录最多保留最近 2 份（当前 + 上 1 份）。
// 只删本插件前缀的文件，不碰 App 自己的任何数据。
static void splash_adblock_pruneOldLogs(void) {
    NSString *prefix = [NSString stringWithFormat:@"SplashAdBlock_%@_v", splash_adblock_logTag()];
    NSMutableArray *dirs = [NSMutableArray array];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.firstObject) [dirs addObject:docs.firstObject];
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (caches.firstObject) [dirs addObject:caches.firstObject];
    [dirs addObject:@"/tmp"];
    [dirs addObject:@"/var/mobile/Documents"];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        NSMutableArray *oldLogs = [NSMutableArray array];
        for (NSString *f in files) {
            if (![f hasPrefix:prefix] || ![f hasSuffix:@".log"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:f];
            NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
            NSDate *date = attr[NSFileModificationDate] ?: [NSDate distantPast];
            [oldLogs addObject:@{@"path": full, @"date": date}];
        }
        if (oldLogs.count <= 2) continue;
        [oldLogs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"date"] compare:a[@"date"]]; // 新在前
        }];
        for (NSUInteger i = 2; i < oldLogs.count; i++) {
            [fm removeItemAtPath:oldLogs[i][@"path"] error:nil];
        }
    }
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

#pragma mark - 微博：开屏精准 hook 支撑 + 弹窗探针（仅微博生效）

// v0.1.7：开屏真凶已由 v0.1.6 日志确认为 WBAdSdkFlashAdView（level=2100 window 内的全屏容器）。
// v0.1.6 的泛化 fade（关键词命中 + 高 level window 整棵淡掉）误伤了启动页
// WBLaunchNewViewController（被 "wblaunch" 命中）和 level=1010 popover 背景，
// 导致「广告没了但黑屏」。本版彻底移除微博泛化 fade，只靠精准 hook 真广告容器；
// 启动页不再被淡掉 -> 广告等待期显示正常启动图（而非黑底）。
static NSTimeInterval splash_adblock_weiboLaunchTime = 0;
static NSInteger splash_adblock_weiboPresentCount = 0;
static NSInteger splash_adblock_weiboWindowCount = 0;
static id splash_adblock_weiboWindowObserver = nil;

static BOOL splash_adblock_weiboProbeActive(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return NO;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - splash_adblock_weiboLaunchTime;
    return elapsed >= 0 && elapsed <= 120;
}

// 有限深度、有限行数的视图树 dump。
static void splash_adblock_weiboDumpTree(UIView *v, NSInteger depth, NSMutableString *out, NSInteger *lines) {
    if (!v || depth > 6 || *lines > 140) return;
    CGRect f = v.frame;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ (%.0f,%.0f %.0fx%.0f) a=%.2f h=%d\n", pad,
        NSStringFromClass([v class]), f.origin.x, f.origin.y, f.size.width, f.size.height,
        v.alpha, v.hidden];
    (*lines)++;
    for (UIView *sub in v.subviews) splash_adblock_weiboDumpTree(sub, depth + 1, out, lines);
}

// v0.1.7：dump 开屏等待相关的关键类方法签名（找类似直播吧 displayRootViewController 的安全入口）。
static void splash_adblock_weiboDumpTargetSignatures(void) {
    NSArray *targets = @[
        @"WBLaunchNewViewController",      // 启动页 VC（当前独占 window）
        @"WBLaunchScreenView",             // 启动图
        @"WBAdSdkNewRootViewController",   // 广告 window root
        @"WBAdSdkFlashAdView",             // 广告容器
        @"WBLaunchProtectionManager",      // 启动保护管理
        @"WBHomePopupsMutexManager",       // 首页弹窗互斥（含 homeVC 生命周期回调）
        @"TabBarRotateController"          // 主界面 root
    ];
    for (NSString *n in targets) {
        Class c = NSClassFromString(n);
        if (!c) {
            splash_adblock_log([NSString stringWithFormat:@"[weibo][SIG] %@ :: NOT FOUND", n]);
            continue;
        }
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        NSMutableArray *lines = [NSMutableArray array];
        for (unsigned int j = 0; j < mc; j++) {
            const char *enc = method_getTypeEncoding(ms[j]);
            [lines addObject:[NSString stringWithFormat:@"%@|%@",
                              NSStringFromSelector(method_getName(ms[j])),
                              enc ? [NSString stringWithUTF8String:enc] : @"?"]];
        }
        if (ms) free(ms);
        splash_adblock_log([NSString stringWithFormat:@"[weibo][SIG] %@ (%u) :: %@", n, mc,
                            [lines componentsJoinedByString:@", "]]);
    }
}

static void splash_adblock_weiboDumpWindows(NSString *when) {
    NSInteger lines = 0;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSMutableString *out = [NSMutableString stringWithFormat:
            @"[weibo][tree@%@] WINDOW level=%.0f root=%@ bounds=%@\n",
            when, w.windowLevel, NSStringFromClass([w.rootViewController class]), NSStringFromCGRect(w.bounds)];
        lines++;
        for (UIView *v in w.subviews) splash_adblock_weiboDumpTree(v, 0, out, &lines);
        splash_adblock_log(out);
    }
}

// 新 window 出现事件：限 12 次，120s 后自动移除观察者。
static void splash_adblock_weiboStartWindowObserver(void) {
    splash_adblock_weiboWindowObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        if (!splash_adblock_weiboProbeActive()) return;
        if (splash_adblock_weiboWindowCount >= 12) return;
        splash_adblock_weiboWindowCount++;
        UIWindow *w = note.object;
        if (![w isKindOfClass:[UIWindow class]]) return;
        splash_adblock_log([NSString stringWithFormat:@"[weibo][window#%ld] level=%.0f root=%@",
                            (long)splash_adblock_weiboWindowCount, w.windowLevel,
                            NSStringFromClass([w.rootViewController class])]);
        NSInteger lines = 0;
        NSMutableString *out = [NSMutableString string];
        for (UIView *v in w.subviews) splash_adblock_weiboDumpTree(v, 0, out, &lines);
        splash_adblock_log(out);
        // v0.1.7：不再泛化 fade 高 level window——避免误伤 popover/启动页。
        // 开屏广告已由 WBAdSdkFlashAdView 精准 hook，这里只做 dump 观察。
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (splash_adblock_weiboWindowObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:splash_adblock_weiboWindowObserver];
            splash_adblock_weiboWindowObserver = nil;
            splash_adblock_log(@"[weibo] window observer removed");
        }
    });
}

// 一次性探针入口：签名 dump 一次（找提前进主界面入口）；窗口树有限 tick 观察。
// v0.1.7：不再做任何泛化 fade——开屏靠精准 hook，探针只记录。
static void splash_adblock_weiboStartProbe(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    splash_adblock_weiboLaunchTime = [[NSDate date] timeIntervalSince1970];
    splash_adblock_log(@"[weibo] === one-shot probe start (precise hook active) ===");
    splash_adblock_weiboDumpTargetSignatures();
    NSArray *ticks = @[@0.5, @1.5, @3.0, @6.0, @12.0];
    for (NSNumber *t in ticks) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!splash_adblock_weiboProbeActive()) return;
            splash_adblock_weiboDumpWindows([NSString stringWithFormat:@"%.1fs", t.doubleValue]);
        });
    }
    splash_adblock_weiboStartWindowObserver();
}

#pragma mark - 微博开屏容器（精准 hook，仅微博生效）

// v0.1.6 日志确认 WBAdSdkFlashAdView(393x852) 是真全屏广告容器，
// 素材子视图 WBAdSdkImageContentView / WBAdXSplashComponentView / WBMPSinglePageView。
// 三时机整棵树 alpha=0（不 hidden、不移除、不碰广告 SDK 计时/回调链）。
%hook WBAdSdkFlashAdView
- (void)didMoveToWindow {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    splash_adblock_log(@"[weibo][hook] WBAdSdkFlashAdView didMoveToWindow -> fade");
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

    // ---- 微博：弹窗探针（事件驱动、限 15 次、120s 内，只记录不 fade） ----
    // v0.1.7：不再按关键词泛化 fade（会误伤启动页/popover）。弹窗真容器待抓到后再精准 hook。
    if (splash_adblock_isWeibo() && vc && splash_adblock_weiboProbeActive()
        && splash_adblock_weiboPresentCount < 15) {
        splash_adblock_weiboPresentCount++;
        NSString *vcName = NSStringFromClass([vc class]);
        NSString *title = vc.title;
        NSString *msg = [vc isKindOfClass:[UIAlertController class]] ? ((UIAlertController *)vc).message : nil;
        splash_adblock_log([NSString stringWithFormat:@"[weibo][present] VC=%@ title=%@ msg=%@",
                            vcName, title ?: @"", msg ?: @""]);
        NSInteger lines = 0;
        NSMutableString *out = [NSMutableString string];
        splash_adblock_weiboDumpTree(vc.view, 0, out, &lines);
        splash_adblock_log(out);
    }
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

        // 直播吧：启动弹窗探针；微博：启动开屏 + 弹窗一次性探针。其余 App 内部门控直接返回。
        splash_adblock_zhiboStartProbe();
        splash_adblock_weiboStartProbe();
    }
}
