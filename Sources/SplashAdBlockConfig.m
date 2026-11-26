#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPreferences.h"

@interface SplashAdBlockConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void splash_adblock_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    SplashAdBlockConfig *config = (__bridge SplashAdBlockConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config splash_adblock_reload];
    });
}

@implementation SplashAdBlockConfig

+ (instancetype)splash_adblock_shared {
    static SplashAdBlockConfig *instance;
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
        [self splash_adblock_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, splash_adblock_preferencesDidChange,
            (__bridge CFStringRef)SplashAdBlockPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self splash_adblock_reload]; });
    }
    return self;
}

- (void)splash_adblock_reload {
    self.snapshot = splash_adblock_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SplashAdBlockPreferencesChanged object:self];
    });
}

- (id)splash_adblock_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)splash_adblock_isEnabled {
    id value = [self splash_adblock_valueForKey:@"enabled" defaultValue:@(YES)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
