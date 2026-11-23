#import <Foundation/Foundation.h>
#import "ChessAPIClient.h"

@interface SuggestionPlanner : NSObject

+ (instancetype)shared;

- (NSArray<NSDictionary *> *)buildAttemptPlanWithRequestedDepth:(NSInteger)reqDepth
                                               selectedProvider:(ChessAPIProvider)selected;

- (BOOL)isBlacklisted:(ChessAPIProvider)p atDepth:(NSInteger)d;
- (void)recordFailure:(ChessAPIProvider)p atDepth:(NSInteger)d;
- (void)recordSuccess:(ChessAPIProvider)p atDepth:(NSInteger)d;
- (void)resetBlacklist;

@end