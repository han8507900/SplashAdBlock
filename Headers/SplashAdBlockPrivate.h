#pragma once

#import <UIKit/UIKit.h>

// 私有类声明：仅声明从真机探针日志确认存在的类与方法。
// 参数统一用 id 通配，避免依赖未知的内部类型。

// -------- 掌盟开屏（GDT）--------
@interface GDTSplashAd : NSObject
- (double)fetchDelay;
- (void)setFetchDelay:(double)arg1;
@end

@interface TGGDTSplashViewController : UIViewController
- (void)viewDidAppear:(BOOL)animated;
@end

@interface TGGDTSplashViewManager : NSObject
- (void)showAllSubView;
- (void)hiddenAllSubView;
@end

@interface TGGDTSplashWindowView : UIView
@end

// -------- 什么值得买开屏容器（真机视图树确认）--------
// SMFullWindowAdView 全屏盖在主 window 上(393x852)，是广告的最终容器。
@interface SMFullWindowAdView : UIView
@end

// -------- 直播吧开屏容器（真机 v0.1.0 日志确认）--------
// ZBSplashView 全屏 393x852，素材子视图 ZBSplashAdMaterialView / ZBSplashAdNewSlideInteractionView。
@interface ZBSplashView : UIView
- (void)didMoveToWindow;
- (void)layoutSubviews;
- (void)setHidden:(BOOL)hidden;
@end

// 开屏 VC（生命周期探针 + v0.1.3 提前显示主界面）
// displayRootViewController：v0.1.2 [SIG] 确认存在，无参 void，App 自带"切到主界面"方法。
@interface ZBSplashAdViewController : UIViewController
- (void)viewDidLoad;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)displayRootViewController;
@end

// -------- 微博开屏容器（真机 v0.1.6 日志确认）--------
// WBAdSdkFlashAdView 全屏 393x852，位于 level=2100 的 WBAdSdkNewRootViewController window 内，
// 素材子视图 WBAdSdkImageContentView / WBAdXSplashComponentView / WBMPSinglePageView。
@interface WBAdSdkFlashAdView : UIView
- (void)didMoveToWindow;
- (void)layoutSubviews;
- (void)setHidden:(BOOL)hidden;
@end

// 广告 window(level=2100) 的 root VC，广告出现时在此提前切主界面。
@interface WBAdSdkNewRootViewController : UIViewController
- (void)viewDidAppear:(BOOL)animated;
- (void)displayRootViewController;
@end

// -------- 评分弹窗 --------
// 系统原生评分控制器（iOS 10.3+）。前向声明避免依赖 StoreKit 框架。
@interface SKStoreReviewController : NSObject
+ (void)requestReview;
+ (void)requestReviewInScene:(id)scene;
@end
