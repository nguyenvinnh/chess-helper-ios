#import <UIKit/UIKit.h>

@interface ArrowOverlay : NSObject

+ (instancetype)shared;

// Vẽ mũi tên từ ô `fromSquare` (VD "e2") đến ô `toSquare` (VD "e4").
// flipped = YES khi bàn đang lật (chơi cầm quân đen).
// Màu mặc định: trắng (gợi ý cho bên trắng), đỏ (gợi ý cho bên đen).
- (void)drawArrowFrom:(NSString *)fromSquare
                   to:(NSString *)toSquare
              flipped:(BOOL)flipped
                color:(UIColor *)color;

// Vẽ từ 1 UCI move (VD "e2e4", "e7e8q").
// forWhite: YES nếu là nước của bên trắng — quyết định màu icon phong cấp
- (void)drawArrowForUCIMove:(NSString *)uciMove
                    flipped:(BOOL)flipped
                      color:(UIColor *)color
                   forWhite:(BOOL)forWhite;

// Xoá toàn bộ mũi tên đang vẽ.
- (void)clear;

@end