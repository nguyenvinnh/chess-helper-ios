#import <UIKit/UIKit.h>

@interface BoardPositionDetector : NSObject

+ (instancetype)shared;

// View bàn cờ đã detect được (weak — có thể nil nếu chưa scan)
@property (nonatomic, weak, readonly) UIView *boardView;

// Lớp của board (nil nếu chưa detect)
@property (nonatomic, copy, readonly) NSString *boardClassName;

// Quét hierarchy + trả về board view (nil nếu không tìm thấy). Entry point chính.
- (UIView *)detectBoardView;

// Frame của board trong toạ độ screen. CGRectZero nếu chưa detect.
// Tự động re-scan nếu board view đã bị release / rotate.
- (CGRect)boardFrameInScreen;

// Toạ độ pixel của tâm ô cờ (VD "e4") trong screen.
// flipped = YES nếu đang chơi cầm quân đen (bàn bị lật).
- (CGPoint)centerOfSquare:(NSString *)algebraicSquare flipped:(BOOL)flipped;

// Xoá board đã lưu (buộc rescan lần sau)
- (void)reset;

@end