#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用屏蔽插件（v0.3.2）
//
// 已精准适配（屏蔽逻辑一行未改）：
//  · 掌盟 com.tencent.ied.app.lolbible —— 广点通 GDT 开屏（透明化）
//  · 闪联 com.shanlian.pro             —— 评分弹窗
//  · 什么值得买 com.smzdm.client.ios   —— SMFullWindowAdView 开屏（精准透明化）
//  · 直播吧 com.zhibo8.tenyears        —— ZBSplashView 开屏（精准透明化）
//                                        + 提前 displayRootViewController 消黑屏
//  · 微博   com.sina.weibo             —— 启动页 VC 提前 adld_advanceShowAppContent
//                                        + WBAdSdkFlashAdView 精准 fade（已定版）
//  · 百度地图 com.baidu.map            —— BMSplashMaterialManager isSplashShowClosed=YES
//                                        （竞品逆向，已真机验证定版）
//  · 铁路12306 cn.12306.rails12306     —— 吞两个数据注入 setter（竞品逆向）
//                                        （已真机验证定版，v0.3.2 起关日志）
//
// v0.3.2 新增下厨房（诊断版）：
//  · 下厨房 com.xiachufang.recipe：竞品库无专属 dylib、公开资料仅网络层抓包方案，
//    暂无可照抄的 Objective-C 类名。按"不猜选择器"原则，本版先用诊断探针 +
//    保守兜底：抓启动期 window / VC / 广告 view 类名写日志；对"命中广告特征
//    且近全屏"的 view 做 alpha=0（不 hidden、不移除、不碰计时/回调链）。
//    真机日志定位真实类名后，下一版换成精准 hook 并移除探针。
//
// 日志策略（用户要求"取消每次打开生成日志，后续每个 App 同样处理"）：
//  · splash_adblock_logEnabled 开关——已定版 App 一律不写日志文件，启动时清理历史残留；
//    仅"诊断中"新接入 App（当前=下厨房）写日志供真机验证，定版后移出白名单。
//  · /tmp 加载标记固定名覆盖写（非 .log、不累积），保留用于确认注入成功。
//  无常驻轮询；block 用 __weak；包名不变。其他 App hook 一行未改。
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

static BOOL splash_adblock_isBaiduMap(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.baidu.map"];
}

static BOOL splash_adblock_isRail12306(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"cn.12306.rails12306"];
}

static BOOL splash_adblock_isXiachufang(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.xiachufang.recipe"];
}

// ---------- 轻量日志（按需开关，无常驻监听、无轮询） ----------
#define SPLASH_ADBLOCK_VERSION @"0.3.2"

// v0.3.2：日志默认关闭——已定版 App 每次启动不再生成任何日志文件。
// 只有"诊断中"的新接入 App 才写日志（真机验证 hook 命中用），定版后从白名单移除。
// 变更记录：v0.3.1 铁路12306 已验证定版，移出白名单；
// 当前诊断白名单：下厨房（新接入，待验证）。其余 App 一律不写日志。
static BOOL splash_adblock_logEnabled(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bundle isEqualToString:@"com.xiachufang.recipe"];
}

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
    if ([bundle isEqualToString:@"cn.12306.rails12306"]) tag = @"12306";
    if ([bundle isEqualToString:@"com.xiachufang.recipe"]) tag = @"xiachufang";
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
    // v0.3.0：已定版 App 不写任何日志（用户要求取消每次打开生成日志）。
    if (!splash_adblock_logEnabled()) return;
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

// 清理本插件日志。只删 SplashAdBlock_<tag> 前缀的 .log，不碰 App 自己的数据。
// v0.3.0：
//  · 日志关闭的 App（已定版）——删掉全部本插件日志（含历史带时间戳文件与固定文件），
//    一次性清干净手机上的残留，此后不再生成任何日志文件。
//  · 日志开启的 App（诊断中）——删历史文件，固定文件交由首次 log 覆盖重建。
static void splash_adblock_pruneOldLogs(void) {
    NSString *tag = splash_adblock_logTag();
    NSString *prefix = [NSString stringWithFormat:@"SplashAdBlock_%@", tag];
    NSString *current = splash_adblock_logName();
    BOOL enabled = splash_adblock_logEnabled();
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
            if (![f hasPrefix:prefix] || ![f hasSuffix:@".log"]) continue;
            // 日志关闭：全部删除；日志开启：删历史，保留当前固定文件（下面会截断）。
            if (enabled && [f isEqualToString:current]) continue;
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
    }
    // 日志开启时，当前固定文件启动时截断为 0，保证「单文件、只含本次启动」。
    if (enabled) {
        NSString *docDir = docs.firstObject ?: @"/tmp";
        NSString *curPath = [docDir stringByAppendingPathComponent:current];
        if ([fm fileExistsAtPath:curPath]) {
            [@"" writeToFile:curPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
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

#pragma mark - 下厨房：开屏诊断探针 + 保守兜底（仅下厨房生效，v0.3.2 诊断版）

// 竞品库无下厨房 dylib、公开资料仅网络层抓包方案，暂无可照抄的 Objective-C 类名。
// 按"不猜选择器"原则：本版先抓启动期 window / VC / 广告 view 类名写日志，同时对
// "命中广告特征 + 近全屏"的 view 做 alpha=0 保守兜底（不 hidden、不移除、不碰
// 广告 SDK 的计时/回调链）。真机日志定位真实类名后，下一版换成精准 hook 并移除探针。

static NSTimeInterval splash_adblock_xcfLaunchTime = 0;
static NSInteger splash_adblock_xcfPresentCount = 0;
static NSInteger splash_adblock_xcfVCCount = 0;
static NSInteger splash_adblock_xcfWindowCount = 0;
static id splash_adblock_xcfWindowObserver = nil;

// 探针只在启动后 120s 内有效：开屏出现在早期，不长期驻留。
static BOOL splash_adblock_xcfProbeActive(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isXiachufang()) return NO;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - splash_adblock_xcfLaunchTime;
    return elapsed >= 0 && elapsed <= 120;
}

// 广告类名关键词（复用直播吧同款泛化判断，命中才 fade，避免误伤主界面）。
static BOOL splash_adblock_xcfNameLooksLikeAd(NSString *name) {
    return splash_adblock_zhiboNameLooksLikeAd(name);
}

static void splash_adblock_xcfFadeRecursive(UIView *v, UIWindow *win, BOOL isRoot) {
    if (!v || isRoot) return;
    NSString *cls = NSStringFromClass([v class]);
    CGRect f = v.frame;
    CGSize s = win.bounds.size;
    BOOL fullscreen = s.width > 0 && f.size.width >= s.width * 0.8
                      && f.size.height >= s.height * 0.5;
    if (fullscreen && splash_adblock_xcfNameLooksLikeAd(cls)) {
        splash_adblock_log([NSString stringWithFormat:@"[xcf][MATCH] ad view %@ frame=%@ -> fade",
                            cls, NSStringFromCGRect(f)]);
        splash_adblock_fadeTree(v);
    }
    BOOL childIsRoot = [v isEqual:win.rootViewController.view];
    for (UIView *sub in v.subviews) splash_adblock_xcfFadeRecursive(sub, win, childIsRoot);
}

static void splash_adblock_xcfFadeFullscreenAds(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        CGFloat level = w.windowLevel;
        if (level > 100 && level < 3000) {
            splash_adblock_log([NSString stringWithFormat:@"[xcf][MATCH] high-level window level=%.0f root=%@ -> fade",
                                level, NSStringFromClass([w.rootViewController class])]);
            splash_adblock_fadeTree(w);
            continue;
        }
        for (UIView *v in w.subviews) {
            splash_adblock_xcfFadeRecursive(v, w, [v isEqual:w.rootViewController.view]);
        }
    }
}

// 新 window 出现事件：抓 window 视图树；限 12 次，120s 后自动移除观察者。
static void splash_adblock_xcfStartWindowObserver(void) {
    splash_adblock_xcfWindowObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        if (!splash_adblock_xcfProbeActive()) return;
        if (splash_adblock_xcfWindowCount >= 12) return;
        splash_adblock_xcfWindowCount++;
        UIWindow *w = note.object;
        if (![w isKindOfClass:[UIWindow class]]) return;
        splash_adblock_log([NSString stringWithFormat:@"[xcf][window#%ld] level=%.0f root=%@",
                            (long)splash_adblock_xcfWindowCount, w.windowLevel,
                            NSStringFromClass([w.rootViewController class])]);
        NSInteger lines = 0;
        NSMutableString *out = [NSMutableString string];
        for (UIView *v in w.subviews) splash_adblock_zhiboDumpTree(v, 0, out, &lines);
        splash_adblock_log(out);
        if (w.windowLevel > 100 && w.windowLevel < 3000) {
            splash_adblock_log(@"[xcf][MATCH] high-level window -> fade");
            splash_adblock_fadeTree(w);
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (splash_adblock_xcfWindowObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:splash_adblock_xcfWindowObserver];
            splash_adblock_xcfWindowObserver = nil;
            splash_adblock_log(@"[xcf] window observer removed");
        }
    });
}

// 启动时记录时间 + 3 次轻量兜底 tick（命中才写日志）+ 新 window 观察。
static void splash_adblock_xcfStartProbe(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isXiachufang()) return;
    splash_adblock_xcfLaunchTime = [[NSDate date] timeIntervalSince1970];
    splash_adblock_log(@"[xcf] splash probe active (diagnostic + conservative fade)");
    NSArray *ticks = @[@1.5, @6.0, @20.0];
    for (NSNumber *t in ticks) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!splash_adblock_xcfProbeActive()) return;
            splash_adblock_xcfFadeFullscreenAds();
        });
    }
    splash_adblock_xcfStartWindowObserver();
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
    // 私有类运行时才存在；用 NSClassFromString 避免生成链接期类符号（否则 ld 报
    // _OBJC_CLASS_$_WBLaunchNewViewController undefined）。
    Class launchClass = NSClassFromString(@"WBLaunchNewViewController");
    if (!launchClass) return nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *vc = w.rootViewController;
        NSInteger depth = 0;
        while (vc && depth < 16) { // 深度上限，防异常 presented 链死循环
            if ([vc isKindOfClass:launchClass]) {
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

#pragma mark - 百度地图开屏（仅百度地图生效）

// 学习竞品「广告终结者」百度地图.dylib 的逆向结论：
// 百度地图开屏是否展示由 BMSplashMaterialManager 的 -isSplashShowClosed 判定。
// 竞品让该方法返回 YES（App 设计内"开屏已展示过"的合法状态），百度直接走无开屏
// 路径进主界面——不黑屏、不久留。这与"掐断 show/load"不同：不改广告加载/计时/
// 回调链，只是把一个状态查询返回真值，符合本项目"绝不掐断回调"的约定。
// 仅加开屏这一项；竞品其余信息流 hook（红点/滚动通知/NAD 原生广告等）暂不加入，
// 遵守"一次只加一个 App、先验证核心"的原则。
%hook BMSplashMaterialManager
- (BOOL)isSplashShowClosed {
    if (!splash_adblock_enabled() || !splash_adblock_isBaiduMap()) return %orig;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[baidu][hook] BMSplashMaterialManager isSplashShowClosed -> YES");
    });
    return YES;
}
%end

#pragma mark - 铁路12306 开屏（仅 12306 生效）

// 学习竞品「广告终结者」12306.dylib 的逆向结论（已反汇编 constructor 确认）：
//  · AdvertisService 的 -setBonSplashAd:  —— 注入开屏广告对象
//  · MTBookTicketHomeTopADView 的 -setMaterialsList: —— 注入开屏素材列表
// 竞品做法：两个 setter 都"不调 orig、直接返回"（替换函数只有一条 ret 指令），
// 等价于告诉 App "本次没有广告可注入"，App 走自带的无开屏路径直接进主界面。
//
// 为什么安全（符合"绝不掐断回调"约定）：
//  · 这两个是「数据注入 setter」，不是广告的 show/load/计时/结束回调；
//    不注入广告 == 用户本来就无广告的那种正常运行态，不开计时器、不卡启动页。
//  · 与百度地图 isSplashShowClosed=YES 完全同构（都是 App 设计内的无广告状态）。
//  · 竞品是线上成熟插件、实测有效，非猜测选择器（本次亦反汇编确认类名/方法名无误）。
// 门控：仅在启用开关 + bundle=cn.12306.rails12306 时吞注入；其余 App/关闭状态完全 %orig。
%hook AdvertisService
- (void)setBonSplashAd:(id)ad {
    if (!splash_adblock_enabled() || !splash_adblock_isRail12306()) {
        %orig;
        return;
    }
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[rail12306][hook] AdvertisService setBonSplashAd: -> swallow (no ad)");
    });
    // 不调 %orig：吞掉开屏广告注入，App 走无开屏路径。
}
%end

%hook MTBookTicketHomeTopADView
- (void)setMaterialsList:(id)list {
    if (!splash_adblock_enabled() || !splash_adblock_isRail12306()) {
        %orig;
        return;
    }
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[rail12306][hook] MTBookTicketHomeTopADView setMaterialsList: -> swallow (no ad)");
    });
    // 不调 %orig：吞掉开屏素材注入。
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

    // ---- 下厨房：present VC 探针（事件驱动、限 15 次、120s 内） ----
    if (splash_adblock_isXiachufang() && vc && splash_adblock_xcfProbeActive()
        && splash_adblock_xcfPresentCount < 15) {
        splash_adblock_xcfPresentCount++;
        NSString *vcName = NSStringFromClass([vc class]);
        NSString *msg = [vc isKindOfClass:[UIAlertController class]] ? ((UIAlertController *)vc).message : nil;
        splash_adblock_log([NSString stringWithFormat:@"[xcf][present] VC=%@ title=%@ msg=%@",
                            vcName, vc.title ?: @"", msg ?: @""]);
        NSInteger lines = 0;
        NSMutableString *out = [NSMutableString string];
        splash_adblock_zhiboDumpTree(vc.view, 0, out, &lines);
        splash_adblock_log(out);
        if (splash_adblock_xcfNameLooksLikeAd(vcName)) {
            splash_adblock_log([NSString stringWithFormat:@"[xcf][MATCH] ad-like popup VC=%@ -> fade", vcName]);
            __weak UIViewController *weakVC = vc;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *strongVC = weakVC;
                if (!strongVC || !splash_adblock_xcfProbeActive()) return;
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

    // ---- 下厨房：广告特征 VC -> 事件驱动兜底（限 60 次、120s 内、命中才 fade） ----
    if (splash_adblock_xcfProbeActive()) {
        if (splash_adblock_xcfVCCount < 60) {
            splash_adblock_xcfVCCount++;
            if (splash_adblock_xcfNameLooksLikeAd(cls)) {
                splash_adblock_log([NSString stringWithFormat:@"[xcf][MATCH] ad-like VC=%@ -> fade", cls]);
                __weak UIViewController *weakSelf = self;
                for (NSNumber *d in @[@0.02, @0.2, @0.7]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        UIViewController *strongSelf = weakSelf;
                        if (!strongSelf || !splash_adblock_xcfProbeActive()) return;
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

        // 直播吧：启动弹窗探针；下厨房：开屏诊断探针（诊断版）；微博：提前进主界面
        // 由广告 VC viewDidAppear 事件驱动，在启动页 VC 上调用官方
        // adld_advanceShowAppContent（不再 ctor 里枚举）。其余 App 内部门控直接返回。
        splash_adblock_zhiboStartProbe();
        splash_adblock_xcfStartProbe();
    }
}
