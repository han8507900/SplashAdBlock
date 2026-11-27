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

// 开屏 VC（v0.1.2 生命周期探针用，前向声明，不改行为）
@interface ZBSplashAdViewController : UIViewController
- (void)viewDidLoad;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
@end

// -------- 评分弹窗 --------
// 系统原生评分控制器（iOS 10.3+）。前向声明避免依赖 StoreKit 框架。
@interface SKStoreReviewController : NSObject
+ (void)requestReview;
+ (void)requestReviewInScene:(id)scene;
@end
