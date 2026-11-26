#pragma once

#import <Foundation/Foundation.h>

@interface AxsSplashAdBlockConfig : NSObject
+ (instancetype)axs_splashadblock_shared;
- (BOOL)axs_splashadblock_isEnabled;
- (id)axs_splashadblock_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_splashadblock_reload;
@end
