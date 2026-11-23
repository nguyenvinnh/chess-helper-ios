#import <UIKit/UIKit.h>

@interface ChessAssistantView : UIWindow

@property (nonatomic, assign) BOOL isMonitoringActive;

- (void)show;
- (void)hide;
- (void)setDetectedFEN:(NSString *)fen;
- (void)setStatusText:(NSString *)text;
- (void)appendLog:(NSString *)line;
- (void)setMonitoringActive:(BOOL)active;

@end
