#import "ArrowOverlay.h"
#import "BoardPositionDetector.h"
#import <os/lock.h>

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

@interface ArrowOverlay ()
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) NSMutableArray<CAShapeLayer *> *arrowLayers;
@property (nonatomic, strong) NSMutableArray<UIView *> *promotionViews;
@property (nonatomic, assign) NSUInteger generation;
@end

@implementation ArrowOverlay

+ (instancetype)shared {
    static ArrowOverlay *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ArrowOverlay new]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _arrowLayers = [NSMutableArray array];
        _promotionViews = [NSMutableArray array];
        _generation = 0;
    }
    return self;
}

#pragma mark - Window

- (UIWindow *)ensureOverlayWindow {
    if (self.overlayWindow && self.overlayWindow.windowScene) return self.overlayWindow;
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) return nil;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
    w.frame = [UIScreen mainScreen].bounds;
    w.windowLevel = UIWindowLevelAlert + 1500;
    w.backgroundColor = [UIColor clearColor];
    w.userInteractionEnabled = NO;
    w.hidden = NO;
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.overlayWindow = w;
    return w;
}

#pragma mark - Draw

- (void)drawArrowForUCIMove:(NSString *)uciMove
                    flipped:(BOOL)flipped
                      color:(UIColor *)color
                   forWhite:(BOOL)forWhite {
    if (uciMove.length < 4) return;
    NSString *from = [uciMove substringToIndex:2];
    NSString *to = [uciMove substringWithRange:NSMakeRange(2, 2)];
    unichar promo = 0;
    if (uciMove.length >= 5) {
        unichar c = [uciMove characterAtIndex:4];
        if (c == 'q' || c == 'r' || c == 'b' || c == 'n') promo = c;
    }
    [self drawArrowFrom:from to:to flipped:flipped color:color forWhite:forWhite promotion:promo];
}

- (void)drawArrowFrom:(NSString *)fromSquare
                   to:(NSString *)toSquare
              flipped:(BOOL)flipped
                color:(UIColor *)color {
    [self drawArrowFrom:fromSquare to:toSquare flipped:flipped color:color forWhite:YES promotion:0];
}

- (void)drawArrowFrom:(NSString *)fromSquare
                   to:(NSString *)toSquare
              flipped:(BOOL)flipped
                color:(UIColor *)color
             forWhite:(BOOL)forWhite
            promotion:(unichar)promoChar {
    if (fromSquare.length != 2 || toSquare.length != 2) return;
    NSUInteger gen = 0;
    os_unfair_lock_lock(&gLock);
    gen = self.generation;
    os_unfair_lock_unlock(&gLock);
    NSString *fromCopy = [fromSquare copy];
    NSString *toCopy = [toSquare copy];
    UIColor *colorCopy = color ?: [UIColor whiteColor];
    BOOL flippedCopy = flipped;
    BOOL forWhiteCopy = forWhite;
    unichar promoCopy = promoChar;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger cur = 0;
        os_unfair_lock_lock(&gLock);
        cur = self.generation;
        os_unfair_lock_unlock(&gLock);
        if (cur != gen) return;
        BoardPositionDetector *det = [BoardPositionDetector shared];
        CGRect boardFrame = [det boardFrameInScreen];
        if (CGRectIsEmpty(boardFrame)) return;
        CGPoint p1 = [det centerOfSquare:fromCopy flipped:flippedCopy];
        CGPoint p2 = [det centerOfSquare:toCopy flipped:flippedCopy];
        if (CGPointEqualToPoint(p1, CGPointZero) || CGPointEqualToPoint(p2, CGPointZero)) return;
        UIWindow *win = [self ensureOverlayWindow];
        if (!win) return;
        CGFloat cellSize = MIN(boardFrame.size.width, boardFrame.size.height) / 8.0;
        [self drawArrowFromPoint:p1 toPoint:p2 color:colorCopy];
        if (promoCopy != 0 && cellSize >= 12.0) {
            [self addPromotionIconAtPoint:p2 cellSize:cellSize forWhite:forWhiteCopy pieceChar:promoCopy];
        }
    });
}

- (void)addPromotionIconAtPoint:(CGPoint)center
                       cellSize:(CGFloat)cellSize
                       forWhite:(BOOL)forWhite
                      pieceChar:(unichar)pieceChar {
    UIWindow *win = self.overlayWindow;
    if (!win) return;
    NSString *symbol = nil;
    switch (pieceChar) {
        case 'q': symbol = forWhite ? @"\u2655" : @"\u265B"; break;
        case 'r': symbol = forWhite ? @"\u2656" : @"\u265C"; break;
        case 'b': symbol = forWhite ? @"\u2657" : @"\u265D"; break;
        case 'n': symbol = forWhite ? @"\u2658" : @"\u265E"; break;
        default: return;
    }
    if (symbol.length == 0) return;
    CGFloat iconSize = cellSize * 0.85;
    CGRect rect = CGRectMake(center.x - iconSize / 2, center.y - iconSize / 2, iconSize, iconSize);
    UIView *container = [[UIView alloc] initWithFrame:rect];
    container.backgroundColor = [UIColor whiteColor];
    container.layer.cornerRadius = iconSize / 2;
    container.layer.borderWidth = 2.0;
    container.layer.borderColor = [UIColor blackColor].CGColor;
    container.userInteractionEnabled = NO;
    UILabel *lbl = [[UILabel alloc] initWithFrame:container.bounds];
    lbl.text = symbol;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.font = [UIFont systemFontOfSize:iconSize * 0.70];
    lbl.textColor = [UIColor blackColor];
    lbl.adjustsFontSizeToFitWidth = YES;
    lbl.minimumScaleFactor = 0.5;
    lbl.userInteractionEnabled = NO;
    [container addSubview:lbl];
    [win.rootViewController.view addSubview:container];
    os_unfair_lock_lock(&gLock);
    [self.promotionViews addObject:container];
    os_unfair_lock_unlock(&gLock);
}

- (void)drawArrowFromPoint:(CGPoint)start
                   toPoint:(CGPoint)end
                     color:(UIColor *)color {
    UIWindow *win = self.overlayWindow;
    if (!win) return;
    CGFloat dx = end.x - start.x;
    CGFloat dy = end.y - start.y;
    CGFloat len = sqrt(dx*dx + dy*dy);
    if (len < 4) return;
    CGFloat ux = dx / len, uy = dy / len;
    CGFloat nx = -uy, ny = ux;
    CGFloat headLen = MIN(28.0, len * 0.32);
    CGFloat headHalf = headLen * 0.55;
    CGPoint headBase = CGPointMake(end.x - ux * headLen, end.y - uy * headLen);
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:start];
    [path addLineToPoint:headBase];
    CGPoint left = CGPointMake(headBase.x + nx * headHalf, headBase.y + ny * headHalf);
    CGPoint right = CGPointMake(headBase.x - nx * headHalf, headBase.y - ny * headHalf);
    [path moveToPoint:end];
    [path addLineToPoint:left];
    [path addLineToPoint:right];
    [path closePath];
    CAShapeLayer *layer = [CAShapeLayer layer];
    layer.path = path.CGPath;
    layer.strokeColor = color.CGColor;
    layer.fillColor = color.CGColor;
    layer.lineWidth = 6.0;
    layer.lineCap = kCALineCapRound;
    layer.lineJoin = kCALineJoinRound;
    layer.opacity = 0.85;
    layer.shadowColor = [UIColor blackColor].CGColor;
    layer.shadowOpacity = 0.25;
    layer.shadowRadius = 2;
    layer.shadowOffset = CGSizeMake(0, 1);
    [win.rootViewController.view.layer addSublayer:layer];
    os_unfair_lock_lock(&gLock);
    [self.arrowLayers addObject:layer];
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - Clear

- (void)clear {
    NSArray *layers = nil;
    NSArray *promos = nil;
    os_unfair_lock_lock(&gLock);
    self.generation++;
    layers = [self.arrowLayers copy];
    [self.arrowLayers removeAllObjects];
    promos = [self.promotionViews copy];
    [self.promotionViews removeAllObjects];
    os_unfair_lock_unlock(&gLock);
    void (^doClear)(void) = ^{
        for (CAShapeLayer *l in layers) [l removeFromSuperlayer];
        for (UIView *v in promos) [v removeFromSuperview];
    };
    if ([NSThread isMainThread]) doClear();
    else dispatch_async(dispatch_get_main_queue(), doClear);
}

@end
