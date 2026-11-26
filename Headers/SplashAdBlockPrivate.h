#pragma once

#import <UIKit/UIKit.h>

// 私有类声明：仅声明从真机探针日志确认存在的类与方法。
// 参数统一用 id 通配，避免依赖未知的内部类型。

@interface GDTSplashAd : NSObject
// 开屏广告停留时长（秒）。秒跳过的核心：不改回调链，只压缩时长。
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
