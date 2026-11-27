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

// 广告 window(level=2100) 的 root VC，广告出现时在此触发"提前进主界面"。
@interface WBAdSdkNewRootViewController : UIViewController
- (void)viewDidAppear:(BOOL)animated;
@end

// 启动页 VC（v0.1.9 [SIG] 确认 66 方法）。真正持有"切主界面"入口的对象：
// adld_advanceShowAppContent 是微博官方"广告完成→进主界面"推进方法。
@interface WBLaunchNewViewController : UIViewController
- (void)viewDidLoad;
@end

// -------- 百度地图开屏（竞品「广告终结者」逆向确认）--------
// BMSplashMaterialManager 的 -isSplashShowClosed 决定开屏是否展示；
// 返回 YES 让百度走"开屏已展示过"的无开屏路径直接进主界面。
@interface BMSplashMaterialManager : NSObject
- (BOOL)isSplashShowClosed;
@end

// -------- 铁路12306 开屏（竞品「广告终结者」12306.dylib 逆向确认）--------
// AdvertisService 的 -setBonSplashAd: 注入开屏广告；返回 YES 路径由竞品阻断注入。
// MTBookTicketHomeTopADView 的 -setMaterialsList: 注入开屏素材列表。
// 竞品做法是不调 orig，直接吞掉注入（等价于"无广告可展示"，App 走无开屏路径）。
@interface AdvertisService : NSObject
- (void)setBonSplashAd:(id)ad;
@end

@interface MTBookTicketHomeTopADView : UIView
- (void)setMaterialsList:(id)list;
@end

// -------- 评分弹窗 --------
// 系统原生评分控制器（iOS 10.3+）。前向声明避免依赖 StoreKit 框架。
@interface SKStoreReviewController : NSObject
+ (void)requestReview;
+ (void)requestReviewInScene:(id)scene;
@end
