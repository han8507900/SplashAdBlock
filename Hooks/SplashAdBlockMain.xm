#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用屏蔽插件（v0.0.4）
//
// 已适配：
//  · 掌盟 com.tencent.ied.app.lolbible —— 广点通 GDT 开屏广告（透明化方案）
//  · 闪联 com.shanlian.pro             —— 评分弹窗（本次新增）
//
// 评分弹窗策略（三管齐下，全局 hook 严格按 bundle 分流，不影响掌盟）：
//  1) 拦系统原生评分 API SKStoreReviewController（零副作用）
//  2) hook presentViewController：命中评分特征 -> present 后瞬间 dismiss
//     （沿用开屏"走完流程但看不见"思路，不掐断、不卡流程）
//  3) 兜底探针：把每次 present 的 VC 类名/文案写日志，万一漏拦可精准定位
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

// ---------- 轻量日志（按 bundle 末段分文件；无常驻轮询） ----------
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

// ---------- 掌盟开屏透明化 ----------
static void splash_adblock_fadeTree(UIView *view) {
    if (!view) return;
    view.alpha = 0.0;
    for (UIView *sub in view.subviews) splash_adblock_fadeTree(sub);
}

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

// ---------- 评分弹窗检测 ----------
static BOOL splash_adblock_textLooksLikeRating(NSString *s) {
    if (!s || s.length == 0) return NO;
    NSArray *keys = @[@"评分", @"评价", @"好评", @"打分", @"星级", @"五星", @"评论一下",
                      @"rate", @"rating", @"review", @"star"];
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// 递归收集视图里所有UILabel/UIButton文案，判断是否有评分特征
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

#pragma mark - 自定义评分弹窗 + 兜底探针（仅闪联生效）

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    // 先正常 present，保证 App 流程不卡
    %orig;

    if (!splash_adblock_enabled() || !splash_adblock_isShanlian()) return;
    if (!vc) return;

    NSString *vcName = NSStringFromClass([vc class]);
    NSString *title = vc.title;
    NSString *msg = [vc isKindOfClass:[UIAlertController class]] ? ((UIAlertController *)vc).message : nil;

    // 兜底探针：记录每次 present 的类名，便于漏拦时精准定位
    splash_adblock_log([NSString stringWithFormat:@"[probe] present VC=%@ title='%@' msg='%@'",
                        vcName, title ?: @"", msg ?: @""]);

    // 判断是否评分弹窗：标题/文案/视图内文字命中关键词
    NSString *matched = nil;
    BOOL hit = splash_adblock_textLooksLikeRating(title)
            || splash_adblock_textLooksLikeRating(msg)
            || splash_adblock_viewLooksLikeRating(vc.view, &matched);

    if (hit) {
        splash_adblock_log([NSString stringWithFormat:@"[MATCH] rating popup VC=%@ matched='%@'",
                            vcName, matched ?: (title ?: (msg ?: @""))]);
        // present 后瞬间透明化并关闭，弹窗看不见但流程完整
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
%end

%ctor {
    @autoreleasepool {
        (void)splash_adblock_enabled();
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        splash_adblock_log([NSString stringWithFormat:@"=== SplashAdBlock active v0.0.4 bundle=%@ ===", bundle]);
    }
}
