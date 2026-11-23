#import <Foundation/Foundation.h>
#import "ChessAPIClient.h"

typedef NS_ENUM(NSInteger, OfflineEngineState) {
    OfflineEngineStateNotDetected = 0,
    OfflineEngineStateReady,
    OfflineEngineStateUnavailable,
};

@interface ChessOfflineEngineClient : NSObject

+ (instancetype)shared;

@property (atomic, assign, readonly) OfflineEngineState state;
@property (nonatomic, copy, readonly) NSString *detectedClassName;
@property (nonatomic, copy, readonly) NSString *detectedMethodName;
@property (nonatomic, copy) void (^logEmitter)(NSString *message);

- (BOOL)detectEngine;
- (BOOL)isAvailable;
- (void)reset;

- (NSURLSessionDataTask *)requestBestMoveForFEN:(NSString *)fen
                                          depth:(NSInteger)depth
                                     completion:(void (^)(ChessAPIResult *result, NSError *error))completion;

// FIX OFFLINE: hủy toàn bộ request đang chờ/đang chạy (dùng khi đổi FEN / Clear).
// Offline trả về nil NSURLSessionDataTask nên cancelInflightTasks cũ không hủy được nó.
- (void)cancelAllRequests;

// FIX OFFLINE: YES nếu vừa fail spawn/handshake trong 30s qua — planner/view nên bỏ qua Offline.
- (BOOL)isInFailureCooldown;
- (BOOL)isEngineAlive;

@end