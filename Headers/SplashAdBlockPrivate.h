#pragma once

#import <UIKit/UIKit.h>

// 私有类声明：仅声明从真机探针日志确认存在的类与方法。
// 参数统一用 id 通配，避免依赖未知的内部类型。

@interface GDTSplashAd : NSObject
- (void)showSplashWithOrder:(id)arg1 withCustomUI:(id)arg2;
- (void)showSplashWithOrder:(id)arg1 withCustomUI:(id)arg2 inContainerView:(id)arg3;
- (void)preLoadSplashOrder:(id)arg1;
- (void)loadAdAndShowSplashWithCustomUIModel:(id)arg1;
@end

@interface TGGDTSplashViewController : UIViewController
- (void)splashViewShowWithModel:(id)arg1 animBegin:(id)arg2 animEnd:(id)arg3 cacheWebView:(id)arg4;
- (void)viewDidAppear:(BOOL)animated;
@end

@interface TGGDTSplashViewManager : NSObject
- (void)showAllSubView;
- (void)hiddenAllSubView;
@end

@interface TGGDTSplashWindowView : UIView
- (void)splashViewShowWithModel:(id)arg1 animBegin:(id)arg2 animEnd:(id)arg3 cacheWebView:(id)arg4;
@end
