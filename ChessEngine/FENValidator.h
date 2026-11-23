#import <Foundation/Foundation.h>

@interface FENValidator : NSObject

+ (BOOL)isFENString:(NSString *)str;
+ (NSString *)extractFENFromBlob:(id)blob;
+ (BOOL)looksLikeValidBoardLayout:(NSString *)placement;
+ (NSString *)normalizedFEN:(NSString *)fen;
+ (NSString *)extractFENFromString:(NSString *)s;

@end
