#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsSplashAdBlockConfig.h"
#import "AxsSplashAdBlockPrivate.h"

// ============================================================================
// 通用开屏广告屏蔽插件 —— 阶段一：通用探针
//
// 一个 dylib 通过 plist 的 Bundles 注入多个目标 App。每份日志按
// Bundle ID 分开命名，互不覆盖；并在日志头部自动识别广告 SDK 家族。
//
// 每个 App 采集三类信息：
//   1) SDK 指纹：GDT / 穿山甲 / 腾讯广告 / 百度 / 快手 / 字节 等（是否加载）
//   2) 广告类 + 方法：名字含 splash/advert/gdt/pangle 等的类名及其方法列表
//   3) 启动后 1s/3s/6s 的视图树 + 依次出现的 ViewController
//
// 拿到日志即可确定每个 App 该 hook 哪个类/方法，再写进同一插件的屏蔽逻辑。
// 采集限时（仅启动后数次采样），无常驻轮询、不改任何视图、不额外耗电。
// ============================================================================

static BOOL axs_splashadblock_didSchedule = NO;

// 日志文件名里的短标识：Bundle ID 最后一段，如 com.tencent.ied.app.lolbible -> lolbible
static NSString *axs_splashadblock_bundleTag(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSArray *parts = [bundle componentsSeparatedByString:@"."];
    NSString *tag = parts.lastObject ?: bundle;
    return tag.length > 0 ? tag : @"unknown";
}

static NSArray<NSString *> *axs_splashadblock_logPaths(void) {
    NSString *name = [NSString stringWithFormat:@"SplashAdBlock_%@.log",
                      axs_splashadblock_bundleTag()];
    NSMutableArray *paths = [NSMutableArray array];
    [paths addObject:[@"/var/mobile/Documents/" stringByAppendingPathComponent:name]];
    NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    if (docs.length > 0) {
        [paths addObject:[docs stringByAppendingPathComponent:name]];
    }
    [paths addObject:[@"/tmp/" stringByAppendingPathComponent:name]];
    return paths;
}

static void axs_splashadblock_write(NSData *data) {
    for (NSString *path in axs_splashadblock_logPaths()) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } else {
            [data writeToFile:path atomically:YES];
        }
    }
}

static void axs_splashadblock_log(NSString *line) {
    NSString *text = [line stringByAppendingString:@"\n"];
    axs_splashadblock_write([text dataUsingEncoding:NSUTF8StringEncoding]);
}

static void axs_splashadblock_reset(void) {
    NSString *header = [NSString stringWithFormat:
        @"=== SplashAdBlock probe (stage 1) ===\nbundle=%@\n",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown"];
    NSData *data = [header dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *path in axs_splashadblock_logPaths()) {
        [data writeToFile:path atomically:YES];
    }
}

// 已知广告 SDK 的典型类名，用于指纹识别
static NSArray<NSString *> *axs_splashadblock_sdkTokens(void) {
    return @[
        @"GDTAd", @"GDTSplashAd", @"GDTUnifiedInterstitialAd", @"GDTSDKConfig",   // 广点通
        @"BUSplashAdView", @"BUNativeExpressSplashAd", @"BUAdSDKManager",          // 穿山甲/Pangle
        @"TADSplash", @"TADManager", @"QADImageSplash", @"QADSplash",              // 腾讯广告
        @"BaiduMobAdSplash", @"BaiduMobAdSDK",                                     // 百度
        @"KsAdSdk", @"KsSplashAd",                                                 // 快手
        @"ABUAdSDK", @"PAGSplashAd",                                               // 字节/Pangle 变体
        @"SplashAd", @"SplashAdView", @"LaunchAd", @"ADLaunchView"                 // 通用命名
    ];
}

static BOOL axs_splashadblock_nameLooksLikeAd(NSString *name) {
    NSString *lower = [name lowercaseString];
    NSArray *keys = @[
        @"splash", @"advert", @"adview", @"adsdk", @"admanager", @"gdt",
        @"pangle", @"busplash", @"tad", @"qad", @"openscreen", @"launchad",
        @"reward", @"interstitial", @"bannerad", @"nativead"
    ];
    for (NSString *key in keys) {
        if ([lower rangeOfString:key].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static void axs_splashadblock_dumpMethods(Class cls, NSMutableString *out) {
    if (!cls) {
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        SEL sel = method_getName(methods[index]);
        if (sel) {
            [names addObject:NSStringFromSelector(sel)];
        }
    }
    if (methods) {
        free(methods);
    }
    [names sortUsingSelector:@selector(compare:)];
    [out appendFormat:@"    methods: %@\n", [names componentsJoinedByString:@", "]];
}

static void axs_splashadblock_dumpAdClasses(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"=== SDK / ad classes ===\n"];

    // 1) SDK 指纹
    for (NSString *token in axs_splashadblock_sdkTokens()) {
        Class cls = objc_getClass(token.UTF8String);
        if (cls) {
            [out appendFormat:@"SDK-HIT %@\n", token];
            axs_splashadblock_dumpMethods(cls, out);
        }
    }

    // 2) 名字像广告的类（含方法列表）
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *hits = [NSMutableArray array];
    if (classes) {
        for (unsigned int index = 0; index < count; index++) {
            NSString *name = NSStringFromClass(classes[index]);
            if (axs_splashadblock_nameLooksLikeAd(name)) {
                [hits addObject:name];
            }
        }
        free(classes);
    }
    [hits sortUsingSelector:@selector(compare:)];
    [out appendFormat:@"ad-like classes (%lu):\n", (unsigned long)hits.count];
    for (NSString *name in hits) {
        [out appendFormat:@"  %@\n", name];
        axs_splashadblock_dumpMethods(objc_getClass(name.UTF8String), out);
    }
    axs_splashadblock_log(out);
}

static void axs_splashadblock_dumpViewTree(UIView *view, int depth, NSMutableString *out) {
    if (!view || depth > 14) {
        return;
    }
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ f=%@ hidden=%d alpha=%.2f\n",
        pad, NSStringFromClass([view class]), NSStringFromCGRect(view.frame),
        view.hidden, view.alpha];
    for (UIView *subview in view.subviews) {
        axs_splashadblock_dumpViewTree(subview, depth + 1, out);
    }
}

static void axs_splashadblock_dumpWindows(NSString *tag) {
    NSMutableString *out = [NSMutableString stringWithFormat:@"=== %@ windows ===\n", tag];
    NSArray *windows = [[UIApplication sharedApplication] windows] ?: @[];
    [out appendFormat:@"window count=%lu\n", (unsigned long)windows.count];
    for (UIWindow *window in windows) {
        [out appendFormat:@"WINDOW %@ level=%.0f hidden=%d\n",
            NSStringFromClass([window class]), window.windowLevel, window.hidden];
        axs_splashadblock_dumpViewTree(window, 1, out);
    }
    axs_splashadblock_log(out);
}

static void axs_splashadblock_startProbe(void) {
    if (axs_splashadblock_didSchedule) {
        return;
    }
    axs_splashadblock_didSchedule = YES;
    axs_splashadblock_reset();
    axs_splashadblock_log([NSString stringWithFormat:@"HOME=%@", NSHomeDirectory()]);
    axs_splashadblock_dumpAdClasses();

    NSArray *delays = @[@1, @3, @6];
    for (NSNumber *delayValue in delays) {
        int64_t delay = [delayValue intValue] * (int64_t)NSEC_PER_SEC;
        NSString *tag = [NSString stringWithFormat:@"T+%ds", [delayValue intValue]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay),
                       dispatch_get_main_queue(), ^{
            axs_splashadblock_dumpWindows(tag);
        });
    }
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    axs_splashadblock_log([NSString stringWithFormat:@"[VC] %@",
        NSStringFromClass([self class])]);
}

%end

%ctor {
    @autoreleasepool {
        // 读取一次配置快照（无面板时保持默认开启），不写偏好。
        (void)[[AxsSplashAdBlockConfig axs_splashadblock_shared] axs_splashadblock_isEnabled];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            axs_splashadblock_startProbe();
        }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            axs_splashadblock_startProbe();
        }];
    }
}
