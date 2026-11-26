#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用屏蔽插件（v0.0.5）
//
// 已适配：
//  · 掌盟 com.tencent.ied.app.lolbible —— 广点通 GDT 开屏广告（透明化方案）
//  · 闪联 com.shanlian.pro             —— 评分弹窗
//  · 什么值得买 com.smzdm.client.ios   —— 开屏广告（本次新增，通用兜底 + 探针）
//
// 什么值得买策略（SDK 未知，故通用兜底 + 探针二合一）：
//  1) 高 level 独立 UIWindow 出现（启动 15s 内、level 100~3000）-> 整棵树透明化
//  2) 出现类名含 splash/launch/openScreen 等的 VC -> 透明化并延迟补刀
//  3) 探针：dump 命中的广告 SDK 类名、窗口、VC 写到 SplashAdBlock_smzdm.log
//     万一没命中，下一版按真实类名精准 hook。
//  全程只做 alpha=0，不改 hidden、不掐断加载、不碰回调链 -> 不卡启动、不重弹。
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

// 启动时间戳（用于把兜底限制在启动初期，避免误伤后续正常弹窗）
static NSTimeInterval splash_adblock_launchTime = 0;

// ---------- 轻量日志（按 bundle 末段分文件；无常驻轮询） ----------
static NSString *splash_adblock_logPath(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSArray *parts = [bundle componentsSeparatedByString:@"."];
    NSString *tag = parts.lastObject ?: bundle;
    // 什么值得买末段是 "ios"，太通用，改用 smzdm 便于查找
    if ([bundle isEqualToString:@"com.smzdm.client.ios"]) tag = @"smzdm";
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

// ---------- 透明化工具 ----------
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
            splash_adblock_log(@"[fade] ad window tree alpha -> 0");
        });
    }
}

static void splash_adblock_fadeWindowWithDelays(UIWindow *win) {
    __weak UIWindow *weakWin = win;
    NSArray *delays = @[@0.02, @0.1, @0.3, @0.7, @1.5];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIWindow *w = weakWin;
            if (!w) return;
            splash_adblock_fadeTree(w);
            splash_adblock_log(@"[fade] high-level window tree alpha -> 0");
        });
    }
}

// ---------- 什么值得买：开屏特征判断 + SDK 探针 ----------
static BOOL splash_adblock_nameLooksLikeSplash(NSString *name) {
    if (!name || name.length == 0) return NO;
    NSString *lower = [name lowercaseString];
    NSArray *keys = @[@"splash", @"openscreen", @"openads", @"launchad", @"startupad",
                      @"flashad", @"splashad", @"开屏", @"广告页"];
    for (NSString *k in keys) {
        if ([lower rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

static void splash_adblock_dumpSDKClasses(void) {
    NSMutableArray *hits = [NSMutableArray array];
    NSArray *keys = @[@"GDTSplash", @"GDTAd", @"GDTSDK", @"BUSplash", @"BUAdSDK",
                      @"BUNativeExpressSplash", @"KSAd", @"ABU", @"Sigmob",
                      @"SplashAd", @"SplashView", @"SplashController"];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (classes) {
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            for (NSString *k in keys) {
                if ([name rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [hits addObject:name];
                    break;
                }
            }
        }
        free(classes);
    }
    splash_adblock_log([NSString stringWithFormat:@"[sdk] matched %lu classes:", (unsigned long)hits.count]);
    NSUInteger limit = MIN(hits.count, 150);
    for (NSUInteger i = 0; i < limit; i++) {
        splash_adblock_log([NSString stringWithFormat:@"   %@", hits[i]]);
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

#pragma mark - 全局 VC hook：闪联评分弹窗 + 什么值得买开屏探针

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
        splash_adblock_log([NSString stringWithFormat:@"[probe] present VC=%@ title='%@' msg='%@'",
                            vcName, title ?: @"", msg ?: @""]);
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
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (!splash_adblock_enabled() || !splash_adblock_isSmzdm()) return;

    NSString *cls = NSStringFromClass([self class]);
    UIWindow *win = self.view.window;
    splash_adblock_log([NSString stringWithFormat:@"[probe] smzdm VC=%@ winLevel=%.0f",
                        cls, win ? win.windowLevel : -1]);

    if (splash_adblock_nameLooksLikeSplash(cls)) {
        splash_adblock_log([NSString stringWithFormat:@"[MATCH] smzdm splash VC=%@", cls]);
        splash_adblock_scheduleFade(self);
    }
}
%end

%ctor {
    @autoreleasepool {
        (void)splash_adblock_enabled();
        splash_adblock_launchTime = [[NSDate date] timeIntervalSince1970];
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        splash_adblock_log([NSString stringWithFormat:@"=== SplashAdBlock active v0.0.5 bundle=%@ ===", bundle]);

        if (splash_adblock_isSmzdm()) {
            // 延迟 2s dump 广告 SDK 类名（等类注册完成）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                splash_adblock_dumpSDKClasses();
            });

            // 兜底：监听高 level 独立 window 出现（启动 15s 内）
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                if (!splash_adblock_enabled() || !splash_adblock_isSmzdm()) return;
                UIWindow *win = note.object;
                if (![win isKindOfClass:[UIWindow class]]) return;
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (now - splash_adblock_launchTime > 15) return;
                CGFloat level = win.windowLevel;
                splash_adblock_log([NSString stringWithFormat:@"[probe] smzdm win visible level=%.0f root=%@",
                                    level, NSStringFromClass([win.rootViewController class])]);
                if (level > 100 && level < 3000) {
                    splash_adblock_log(@"[MATCH] smzdm high-level window -> fade");
                    splash_adblock_fadeWindowWithDelays(win);
                }
            }];
        }
    }
}
