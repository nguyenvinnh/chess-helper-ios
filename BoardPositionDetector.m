#import "BoardPositionDetector.h"
#import <objc/runtime.h>
#import <os/lock.h>

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static __weak UIView *gBoardView = nil;

@interface BoardPositionDetector ()
@property (nonatomic, copy, readwrite) NSString *boardClassName;
@property (nonatomic, assign) CGRect cachedFrame;
@property (nonatomic, assign) NSTimeInterval cachedAt;
@property (nonatomic, weak) UIView *cachedView;
@end

@implementation BoardPositionDetector

+ (instancetype)shared {
    static BoardPositionDetector *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [BoardPositionDetector new]; });
    return shared;
}

- (UIView *)boardView {
    os_unfair_lock_lock(&gLock);
    UIView *v = gBoardView;
    os_unfair_lock_unlock(&gLock);
    return v;
}

- (void)reset {
    os_unfair_lock_lock(&gLock);
    gBoardView = nil;
    os_unfair_lock_unlock(&gLock);
    self.boardClassName = nil;
    self.cachedView = nil;
    self.cachedAt = 0;
}

- (UIView *)detectBoardView {
    UIWindow *target = [self findAppWindow];
    if (!target) return nil;
    int bestScore = 0;
    UIView *best = [self findBestInView:target depth:0 minScore:50 bestScore:&bestScore];
    if (best) {
        os_unfair_lock_lock(&gLock);
        gBoardView = best;
        os_unfair_lock_unlock(&gLock);
        self.boardClassName = NSStringFromClass([best class]);
        self.cachedView = best;
        self.cachedFrame = best.window ? [best convertRect:best.bounds toView:nil] : CGRectZero;
        self.cachedAt = CACurrentMediaTime();
    }
    return best;
}

- (UIWindow *)findAppWindow {
    Class monitorCls = NSClassFromString(@"ChessAssistantView");
    UIWindow *fallback = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (monitorCls && [w isKindOfClass:monitorCls]) continue;
        if (w.hidden || w.alpha < 0.01) continue;
        if (w.isKeyWindow) return w;
        if (!fallback) fallback = w;
    }
    return fallback;
}

- (UIView *)findBestInView:(UIView *)view depth:(int)depth minScore:(int)minScore bestScore:(int *)outScore {
    if (!view || depth > 40) { if (outScore) *outScore = -10000; return nil; }
    if (view.hidden || view.alpha < 0.01) { if (outScore) *outScore = -10000; return nil; }
    int myScore = [self scoreView:view];
    UIView *bestChild = nil;
    int bestChildScore = -10000;
    for (UIView *sub in view.subviews) {
        int childScore = -10000;
        UIView *cand = [self findBestInView:sub depth:depth + 1 minScore:minScore bestScore:&childScore];
        if (cand && childScore > bestChildScore) { bestChildScore = childScore; bestChild = cand; }
    }
    if (bestChild && bestChildScore >= myScore) { if (outScore) *outScore = bestChildScore; return bestChild; }
    if (myScore >= minScore) { if (outScore) *outScore = myScore; return view; }
    if (outScore) *outScore = -10000;
    return nil;
}

- (int)scoreView:(UIView *)view {
    NSString *cls = NSStringFromClass([view class]);
    if ([cls rangeOfString:@"chessassistant" options:NSCaseInsensitiveSearch].location != NSNotFound) return -10000;
    if ([cls rangeOfString:@"chessassistant" options:NSCaseInsensitiveSearch].location != NSNotFound) return -10000;
    int score = 0;
    if ([cls rangeOfString:@"chessboard" options:NSCaseInsensitiveSearch].location != NSNotFound) score += 120;
    else if ([cls rangeOfString:@"board" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        if ([cls rangeOfString:@"keyboard" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [cls rangeOfString:@"scoreboard" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [cls rangeOfString:@"leaderboard" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [cls rangeOfString:@"dashboard" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [cls rangeOfString:@"clipboard" options:NSCaseInsensitiveSearch].location == NSNotFound) score += 60;
    }
    if ([cls rangeOfString:@"chess" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        [cls rangeOfString:@"chessboard" options:NSCaseInsensitiveSearch].location == NSNotFound) score += 15;
    CGSize sz = view.bounds.size;
    if (sz.width >= 240 && sz.height >= 240) {
        CGFloat ratio = sz.width / sz.height;
        if (ratio >= 0.9 && ratio <= 1.1) score += 40;
        else if (ratio >= 0.75 && ratio <= 1.35) score += 10;
    } else if (sz.width >= 200 && sz.height >= 200) {
        CGFloat ratio = sz.width / sz.height;
        if (ratio >= 0.9 && ratio <= 1.1) score += 20;
    }
    if ([self viewHas8x8Grid:view]) score += 80;
    if ([view isKindOfClass:[UILabel class]]) score -= 100;
    if ([view isKindOfClass:[UIImageView class]]) score -= 100;
    if ([view isKindOfClass:[UITextView class]]) score -= 100;
    if ([view isKindOfClass:[UIButton class]]) score -= 100;
    if ([view isKindOfClass:[UIScrollView class]] && ![view isKindOfClass:NSClassFromString(@"UICollectionView")]) score -= 30;
    return score;
}

- (BOOL)viewHas8x8Grid:(UIView *)view {
    NSArray *subs = view.subviews;
    if (subs.count < 64) return NO;
    CGSize parentSize = view.bounds.size;
    if (parentSize.width < 200) return NO;
    CGFloat cellW = parentSize.width / 8.0;
    CGFloat cellH = parentSize.height / 8.0;
    int inGrid = 0;
    for (UIView *sub in subs) {
        CGFloat w = sub.frame.size.width;
        CGFloat h = sub.frame.size.height;
        if (w > 0 && h > 0 && fabs(w - cellW) <= 2.0 && fabs(h - cellH) <= 2.0) {
            inGrid++;
            if (inGrid >= 64) return YES;
        }
    }
    return NO;
}

- (CGRect)boardFrameInScreen {
    UIView *v = self.boardView;
    if (v && v.window && v == self.cachedView && (CACurrentMediaTime() - self.cachedAt) < 0.35 && !CGRectIsEmpty(self.cachedFrame)) {
        return self.cachedFrame;
    }
    if (!v || !v.window) v = [self detectBoardView];
    if (!v || !v.window) return CGRectZero;
    CGRect f = [v convertRect:v.bounds toView:nil];
    self.cachedView = v;
    self.cachedFrame = f;
    self.cachedAt = CACurrentMediaTime();
    return f;
}

- (CGPoint)centerOfSquare:(NSString *)algebraicSquare flipped:(BOOL)flipped {
    if (algebraicSquare.length != 2) return CGPointZero;
    unichar f = [algebraicSquare characterAtIndex:0];
    unichar r = [algebraicSquare characterAtIndex:1];
    if (f < 'a' || f > 'h') return CGPointZero;
    if (r < '1' || r > '8') return CGPointZero;
    int file = f - 'a';
    int rank = r - '1';
    CGRect frame = [self boardFrameInScreen];
    if (CGRectIsEmpty(frame)) return CGPointZero;
    CGFloat cellW = frame.size.width / 8.0;
    CGFloat cellH = frame.size.height / 8.0;
    if (flipped) return CGPointMake(frame.origin.x + (7 - file + 0.5) * cellW, frame.origin.y + (rank + 0.5) * cellH);
    return CGPointMake(frame.origin.x + (file + 0.5) * cellW, frame.origin.y + (7 - rank + 0.5) * cellH);
}

@end
