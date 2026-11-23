#import <Foundation/Foundation.h>

@interface CrashHandler : NSObject

+ (void)installCrashHandlers;
+ (void)safeWriteCrashLog:(NSString *)msg;

@end