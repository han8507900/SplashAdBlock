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

// -------- 评分弹窗 --------
// 系统原生评分控制器（iOS 10.3+）。前向声明避免依赖 StoreKit 框架。
@interface SKStoreReviewController : NSObject
+ (void)requestReview;
+ (void)requestReviewInScene:(id)scene;
@end
