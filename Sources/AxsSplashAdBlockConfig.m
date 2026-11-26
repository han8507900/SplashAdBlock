#import "AxsSplashAdBlockConfig.h"
#import "AxsSplashAdBlockPreferences.h"

@interface AxsSplashAdBlockConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_splashadblock_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsSplashAdBlockConfig *config = (__bridge AxsSplashAdBlockConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_splashadblock_reload];
    });
}

@implementation AxsSplashAdBlockConfig

+ (instancetype)axs_splashadblock_shared {
    static AxsSplashAdBlockConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.hzy.splashadblock.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_splashadblock_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_splashadblock_preferencesDidChange,
            (__bridge CFStringRef)AxsSplashAdBlockPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_splashadblock_reload]; });
    }
    return self;
}

- (void)axs_splashadblock_reload {
    self.snapshot = axs_splashadblock_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsSplashAdBlockPreferencesChanged object:self];
    });
}

- (id)axs_splashadblock_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_splashadblock_isEnabled {
    id value = [self axs_splashadblock_valueForKey:@"enabled" defaultValue:@(YES)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
