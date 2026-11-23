#import <Foundation/Foundation.h>

@interface ChessFENExtractor : NSObject

+ (instancetype)shared;

@property (nonatomic, copy) void (^logEmitter)(NSString *category, NSString *message);
@property (nonatomic, copy) void (^fenFoundHandler)(NSString *fen);
@property (nonatomic, copy, readonly) NSString *lastFEN;
@property (atomic, assign, readonly) BOOL isHooking;

// Hook tuần tự: mỗi class cách nhau 400ms. Report progress qua
// kChessAssistantHookProgress. Report xong qua kChessAssistantHookedUpdated.
- (void)startSequentialHooking;

// Dừng theo dõi: ngừng fire FEN handler + dừng hooking đang chạy.
- (void)stopMonitoring;

// Internal — được gọi từ hook body.
- (void)handleFENFound:(NSString *)fen context:(NSString *)context;

@end