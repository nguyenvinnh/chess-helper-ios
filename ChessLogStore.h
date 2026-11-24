#import <Foundation/Foundation.h>

@interface ChessLogStore : NSObject

+ (instancetype)shared;

@property (nonatomic, copy, readonly) NSString *logFilePath;
@property (nonatomic, copy, readonly) NSString *fenFilePath;

- (void)appendLog:(NSString *)line;
- (void)appendFEN:(NSString *)fen context:(NSString *)ctx;

- (NSArray<NSString *> *)loadLogTail:(NSInteger)maxLines;

- (void)flush;

@end
