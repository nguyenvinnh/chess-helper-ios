#import <Foundation/Foundation.h>

@interface ChessLogStore : NSObject

+ (instancetype)shared;

@property (nonatomic, copy, readonly) NSString *logFilePath;
@property (nonatomic, copy, readonly) NSString *fenHistoryPath;

- (void)appendLog:(NSString *)line;
- (void)appendFEN:(NSString *)fen context:(NSString *)ctx;

- (NSArray<NSString *> *)loadLogTail:(NSUInteger)maxLines;
- (NSArray<NSString *> *)loadFENTail:(NSUInteger)maxLines;

- (void)clearLog;
- (void)clearFENHistory;

- (void)flush;

@end
