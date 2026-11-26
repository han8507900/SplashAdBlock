#pragma once

#import <Foundation/Foundation.h>

@interface SplashAdBlockConfig : NSObject
+ (instancetype)splash_adblock_shared;
- (BOOL)splash_adblock_isEnabled;
- (id)splash_adblock_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)splash_adblock_reload;
@end
