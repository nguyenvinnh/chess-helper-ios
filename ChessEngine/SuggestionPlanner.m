#import "SuggestionPlanner.h"
#import "ChessOfflineEngineClient.h"

@interface SuggestionPlanner ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *failureCounts;
@end

@implementation SuggestionPlanner

+ (instancetype)shared {
    static SuggestionPlanner *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SuggestionPlanner new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) _failureCounts = [NSMutableDictionary new];
    return self;
}

- (BOOL)isBlacklisted:(ChessAPIProvider)p atDepth:(NSInteger)d {
    if (p == ChessAPIProviderOffline) return NO;
    NSString *key = [NSString stringWithFormat:@"%ld:%ld", (long)p, (long)d];
    @synchronized (self) {
        return [(self.failureCounts[key] ?: @0) integerValue] >= 3;
    }
}

- (void)recordFailure:(ChessAPIProvider)p atDepth:(NSInteger)d {
    if (p == ChessAPIProviderOffline) return;
    NSString *key = [NSString stringWithFormat:@"%ld:%ld", (long)p, (long)d];
    @synchronized (self) {
        NSInteger cur = [self.failureCounts[key] ?: @0 integerValue];
        self.failureCounts[key] = @(cur + 1);
    }
}

- (void)recordSuccess:(ChessAPIProvider)p atDepth:(NSInteger)d {
    NSString *key = [NSString stringWithFormat:@"%ld:%ld", (long)p, (long)d];
    @synchronized (self) { [self.failureCounts removeObjectForKey:key]; }
}

- (void)resetBlacklist {
    @synchronized (self) { [self.failureCounts removeAllObjects]; }
}

- (NSArray<NSDictionary *> *)buildAttemptPlanWithRequestedDepth:(NSInteger)reqDepth
                                               selectedProvider:(ChessAPIProvider)selected {
    NSMutableArray<NSDictionary *> *plan = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    static const NSInteger kOffsets[] = {0, -1, 1, -2, 2};
    BOOL offlineAdded = NO;
    BOOL offlineInCooldown = [[ChessOfflineEngineClient shared] isInFailureCooldown];
    for (int oi = 0; oi < 5; oi++) {
        NSInteger targetD = reqDepth + kOffsets[oi];
        if (targetD < 1) continue;
        ChessAPIProvider order[4];
        int n = 0;
        order[n++] = selected;
        if (selected != ChessAPIProviderOffline) order[n++] = ChessAPIProviderOffline;
        if (selected != ChessAPIProviderStockfishOnline) order[n++] = ChessAPIProviderStockfishOnline;
        if (selected != ChessAPIProviderChessAPI) order[n++] = ChessAPIProviderChessAPI;
        for (int pi = 0; pi < n; pi++) {
            ChessAPIProvider p = order[pi];
            if (p == ChessAPIProviderOffline) {
                if (offlineAdded || offlineInCooldown || kOffsets[oi] != 0) continue;
            }
            NSInteger lo = [ChessAPIClient minDepthForProvider:p];
            NSInteger hi = [ChessAPIClient maxDepthForProvider:p];
            NSInteger d = MAX(lo, MIN(hi, targetD));
            NSString *key = [NSString stringWithFormat:@"%ld:%ld", (long)p, (long)d];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            if ([self isBlacklisted:p atDepth:d]) continue;
            [plan addObject:@{@"provider": @(p), @"depth": @(d)}];
            if (p == ChessAPIProviderOffline) offlineAdded = YES;
        }
    }
    return plan;
}

@end
