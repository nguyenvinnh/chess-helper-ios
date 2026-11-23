#import "ChessFENExtractor.h"
#import "ChessEngine/FENValidator.h"
#import "BoardPositionDetector.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <time.h>
#import <string.h>

static NSMutableSet<NSString *> *gHooked = nil;
static NSMutableArray *gRetainedBlocks = nil;
static void (^gFENFoundBlock)(NSString *, NSString *) = nil;

static NSString *gLastFiredFEN = nil;
static NSString *gLastFiredNormalized = nil;
static NSString *gPendingFEN = nil;
static NSString *gPendingNormalized = nil;
static NSString *gPendingContext = nil;
static BOOL gPendingScheduled = NO;

static NSHashTable *gTrackedInstances = nil;
static dispatch_source_t gPollTimer = nil;
static const uint64_t kPollIntervalNs = 1500ULL * 1000000ULL;
static const NSTimeInterval kFENCoalesceDelay = 0.08;
static const NSTimeInterval kHookClassDelay = 0.4;

@interface ChessFENExtractor ()
@property (nonatomic, copy, readwrite) NSString *lastFEN;
@property (atomic, assign, readwrite) BOOL isHooking;
@property (atomic, assign) BOOL monitoringEnabled;
@property (nonatomic, strong) dispatch_queue_t hookQueue;
@end

static void CaptureFENIfValid(id value, SEL sel) {
    if (!value || !gFENFoundBlock) return;
    NSString *fen = [FENValidator extractFENFromString:value];
    if (!fen) return;
    NSString *ctx = NSStringFromSelector(sel);
    NSString *copy = [fen copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { if (gFENFoundBlock) gFENFoundBlock(copy, ctx); } @catch (NSException *e) { }
    });
}

@implementation ChessFENExtractor

+ (instancetype)shared {
    static ChessFENExtractor *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ChessFENExtractor new]; });
    return shared;
}

- (void)emit:(NSString *)category message:(NSString *)message {
    if (self.logEmitter) self.logEmitter(category, message);
}

- (void)trackInstance:(id)inst {
    if (!inst) return;
    @synchronized ([ChessFENExtractor class]) {
        if (!gTrackedInstances) gTrackedInstances = [NSHashTable weakObjectsHashTable];
        [gTrackedInstances addObject:inst];
    }
}

- (void)startPolling {
    if (gPollTimer) return;
    gPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gPollTimer) return;
    dispatch_source_set_timer(gPollTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)kPollIntervalNs), kPollIntervalNs, (uint64_t)(50 * NSEC_PER_MSEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(gPollTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.monitoringEnabled) return;
        @try { [strongSelf pollTrackedInstances]; } @catch (NSException *e) { NSLog(@"[ChessAssistant] poll ex: %@", e.reason); }
    });
    dispatch_resume(gPollTimer);
}

- (void)stopPolling {
    if (gPollTimer) { dispatch_source_cancel(gPollTimer); gPollTimer = nil; }
}

- (void)pollTrackedInstances {
    // Chỉ lấy FEN từ bàn cờ đang hiển thị trên màn hình qua BoardPositionDetector.
    // KHÔNG probe toàn bộ gTrackedInstances hay duyệt toàn bộ view hierarchy
    // vì bot engine tạo rất nhiều instance CHGame tạm/ảo để search khiến FEN bị nhảy loạn!
    UIView *board = [[BoardPositionDetector shared] boardView];
    if (!board || !board.window) {
        board = [[BoardPositionDetector shared] detectBoardView];
    }
    if (board && [board respondsToSelector:@selector(chessGame)]) {
        @try {
            id game = [board performSelector:@selector(chessGame)];
            if (game && [game respondsToSelector:@selector(fenForCurrentPosition:flipped:)]) {
                id r = ((id(*)(id, SEL, BOOL, BOOL))objc_msgSend)(game, @selector(fenForCurrentPosition:flipped:), NO, NO);
                NSString *fen = [FENValidator extractFENFromString:r];
                if (fen) [self handleFENFound:fen context:@"activeBoardView.game"];
            }
        } @catch (NSException *e) { }
    }
}

- (void)discoverInstancesFromViewHierarchy {
    // Thay thế bằng tìm board view trực tiếp
    [[BoardPositionDetector shared] detectBoardView];
}

static BOOL MethodReturnsObject(id inst, SEL sel) {
    if (!inst || !sel) return NO;
    Method m = class_getInstanceMethod([inst class], sel);
    if (!m) return NO;
    char retType[16] = {0};
    method_getReturnType(m, retType, sizeof(retType));
    return (retType[0] == '@');
}

- (void)probeInstance:(id)inst depth:(int)depth {
    if (!inst || depth > 3) return;
    static NSArray<NSString *> *directGetters = nil;
    static NSArray<NSString *> *subProps = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        directGetters = @[@"fen", @"currentFen", @"currentFEN", @"boardFen", @"boardFEN", @"fenString", @"positionString", @"currentPositionString", @"chessFen", @"chessFEN", @"gameFen", @"gameFEN", @"fenNotation", @"positionFen", @"positionFEN", @"getFen", @"getFEN", @"FEN", @"snapshot", @"snapshotFen", @"gameStateFen", @"chessState", @"currentGameFen", @"fenAfterMove"];
        subProps = @[@"chessGame", @"game", @"gameState", @"position", @"currentPosition", @"board", @"liveGame", @"gameModel", @"model", @"gameData", @"liveGameState", @"gameStatus", @"boardState", @"currentGame", @"activeGame", @"matchState", @"session", @"snapshot", @"chessState"];
    });

    // Ưu tiên gọi hàm chuẩn của CHBoardView & CHGame: fenForCurrentPosition:flipped:
    if ([inst respondsToSelector:@selector(fenForCurrentPosition:flipped:)] &&
        MethodReturnsObject(inst, @selector(fenForCurrentPosition:flipped:))) {
        @try {
            id r = ((id(*)(id, SEL, BOOL, BOOL))objc_msgSend)(inst, @selector(fenForCurrentPosition:flipped:), NO, NO);
            NSString *fen = [FENValidator extractFENFromString:r];
            if (fen) [self handleFENFound:fen context:[NSString stringWithFormat:@"poll.direct.%@", NSStringFromClass([inst class])]];
        } @catch (NSException *e) { }
    }

    for (NSString *selName in directGetters) {
        SEL sel = NSSelectorFromString(selName);
        if (![inst respondsToSelector:sel] || !MethodReturnsObject(inst, sel)) continue;
        @try {
            id r = ((id(*)(id, SEL))objc_msgSend)(inst, sel);
            NSString *fen = [FENValidator extractFENFromString:r];
            if (fen) [self handleFENFound:fen context:[NSString stringWithFormat:@"poll.%@", NSStringFromClass([inst class])]];
        } @catch (NSException *e) { }
    }
    for (NSString *propName in subProps) {
        SEL sel = NSSelectorFromString(propName);
        if (![inst respondsToSelector:sel] || !MethodReturnsObject(inst, sel)) continue;
        @try {
            id sub = ((id(*)(id, SEL))objc_msgSend)(inst, sel);
            if (sub && sub != inst) [self probeSubInstance:sub depth:depth + 1];
        } @catch (NSException *e) { }
    }
}

- (void)probeSubInstance:(id)sub depth:(int)depth {
    if (!sub || depth > 3) return;
    if ([sub respondsToSelector:@selector(fenForCurrentPosition:flipped:)] &&
        MethodReturnsObject(sub, @selector(fenForCurrentPosition:flipped:))) {
        @try {
            id r = ((id(*)(id, SEL, BOOL, BOOL))objc_msgSend)(sub, @selector(fenForCurrentPosition:flipped:), NO, NO);
            NSString *fen = [FENValidator extractFENFromString:r];
            if (fen) [self handleFENFound:fen context:[NSString stringWithFormat:@"poll.sub.direct.%@", NSStringFromClass([sub class])]];
        } @catch (NSException *e) { }
    }
    for (NSString *selName in @[@"fen", @"currentFen", @"currentFEN", @"boardFen", @"boardFEN", @"fenString", @"chessFen", @"gameFen", @"positionFen", @"snapshot", @"snapshotFen"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![sub respondsToSelector:sel] || !MethodReturnsObject(sub, sel)) continue;
        @try {
            id r = ((id(*)(id, SEL))objc_msgSend)(sub, sel);
            NSString *fen = [FENValidator extractFENFromString:r];
            if (fen) [self handleFENFound:fen context:[NSString stringWithFormat:@"poll.sub.%@", NSStringFromClass([sub class])]];
        } @catch (NSException *e) { }
    }
    if (depth >= 3) return;
    for (NSString *propName in @[@"chessGame", @"game", @"gameState", @"board", @"position", @"currentGame", @"gameModel", @"model", @"boardState", @"snapshot"]) {
        SEL sel = NSSelectorFromString(propName);
        if (![sub respondsToSelector:sel] || !MethodReturnsObject(sub, sel)) continue;
        @try {
            id next = ((id(*)(id, SEL))objc_msgSend)(sub, sel);
            if (next && next != sub) [self probeSubInstance:next depth:depth + 1];
        } @catch (NSException *e) { }
    }
}

- (void)startSequentialHooking {
    if (self.isHooking) return;
    self.isHooking = YES;
    self.monitoringEnabled = YES;
    if (!self.hookQueue) self.hookQueue = dispatch_queue_create("com.nguyenvinnh.appactivitymonitor.hook", DISPATCH_QUEUE_SERIAL);
    if (!gHooked) gHooked = [NSMutableSet set];
    if (!gRetainedBlocks) gRetainedBlocks = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    gFENFoundBlock = ^(NSString *fen, NSString *ctx) { @try { [weakSelf handleFENFound:fen context:ctx]; } @catch (NSException *e) { } };
    [self startPolling];
    NSArray<NSString *> *candidates = [self classCandidates];
    [self emit:@"AUTO" message:[NSString stringWithFormat:@"Bắt đầu hook %lu class (background)", (unsigned long)candidates.count]];
    dispatch_async(self.hookQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        int totalHooked = 0;
        for (NSInteger i = 0; i < (NSInteger)candidates.count; i++) {
            if (!strongSelf.isHooking) break;
            @autoreleasepool {
                NSString *clsName = candidates[i];
                Class cls = objc_getClass([clsName UTF8String]);
                int h = 0;
                if (!cls) { [strongSelf emit:@"AUTO" message:[NSString stringWithFormat:@"%@ — không tìm thấy", clsName]]; }
                else { @try { h += [strongSelf hookIntoClass:cls displayName:clsName isMeta:NO]; h += [strongSelf hookIntoClass:cls displayName:clsName isMeta:YES]; } @catch (NSException *e) { [strongSelf emit:@"AUTO" message:[NSString stringWithFormat:@"%@ — lỗi: %@", clsName, e.reason]]; } }
                totalHooked += h;
                NSDictionary *info = @{@"current": @(i + 1), @"total": @(candidates.count), @"class": clsName, @"hooked": @(totalHooked)};
                dispatch_async(dispatch_get_main_queue(), ^{ @try { [[NSNotificationCenter defaultCenter] postNotificationName:@"kChessAssistantHookProgress" object:nil userInfo:info]; } @catch (NSException *e) { } });
            }
            if (i < (NSInteger)candidates.count - 1) [NSThread sleepForTimeInterval:kHookClassDelay];
        }
        [strongSelf emit:@"AUTO" message:[NSString stringWithFormat:@"Hoàn tất: %d method", totalHooked]];
        dispatch_async(dispatch_get_main_queue(), ^{ @try { [[NSNotificationCenter defaultCenter] postNotificationName:@"kChessAssistantHookedUpdated" object:nil userInfo:@{@"count": @(totalHooked)}]; } @catch (NSException *e) { } });
        strongSelf.isHooking = NO;
    });
}

- (void)stopMonitoring {
    self.monitoringEnabled = NO;
    self.isHooking = NO;
    [self stopPolling];
    @synchronized ([ChessFENExtractor class]) { gPendingFEN = nil; gPendingNormalized = nil; gPendingContext = nil; gPendingScheduled = NO; }
    [self emit:@"AUTO" message:@"Đã dừng theo dõi"];
}

- (void)handleFENFound:(NSString *)fen context:(NSString *)context {
    if (!self.monitoringEnabled) return;
    NSString *norm = [FENValidator normalizedFEN:fen];
    if (!norm) return;
    @synchronized ([ChessFENExtractor class]) {
        if ([gLastFiredNormalized isEqualToString:norm]) return;
        if ([gPendingNormalized isEqualToString:norm]) return;
        // Không cho FEN cũ ghi đè FEN mới: chỉ nhận nếu pending rỗng hoặc fen này mới hơn (khác last).
        // Nếu đã có pending khác, giữ pending mới nhất theo thứ tự đến sau, nhưng không quay lại lastFired.
        if (gPendingFEN && [gPendingNormalized isEqualToString:norm]) return;
        // Nếu pending hiện tại là FEN cũ đã fired, cho phép thay bằng FEN mới này.
        // Nếu pending là FEN mới chưa fired, vẫn thay bằng FEN đến sau vì nó mới hơn.
        gPendingFEN = [fen copy];
        gPendingNormalized = norm;
        gPendingContext = [context copy];
        if (gPendingScheduled) return;
        gPendingScheduled = YES;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFENCoalesceDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!strongSelf.monitoringEnabled) return;
            NSString *toFire = nil; NSString *ctx = nil; NSString *toFireNorm = nil;
            @synchronized ([ChessFENExtractor class]) {
                toFire = gPendingFEN; ctx = gPendingContext; toFireNorm = gPendingNormalized;
                gPendingFEN = nil; gPendingContext = nil; gPendingNormalized = nil; gPendingScheduled = NO;
                if (toFire.length == 0) return;
                if ([gLastFiredNormalized isEqualToString:toFireNorm]) return;
                gLastFiredFEN = toFire; gLastFiredNormalized = toFireNorm;
            }
            strongSelf.lastFEN = toFire;
            [strongSelf emit:@"FEN" message:[NSString stringWithFormat:@"[%@] %@", ctx ?: @"?", toFire]];
            if (strongSelf.fenFoundHandler) strongSelf.fenFoundHandler(toFire);
        } @catch (NSException *e) { NSLog(@"[ChessAssistant] coalesce ex: %@", e.reason); }
    });
}

- (NSArray<NSString *> *)classCandidates {
    // KHÔNG hook class CHGame động trong runtime vì bot tạo rất nhiều CHGame instance tạm.
    return @[@"CHBoardView", @"CHLiveGameState", @"CHLiveGame", @"CHLiveChessClient"];
}

- (int)hookIntoClass:(Class)cls displayName:(NSString *)name isMeta:(BOOL)isMeta {
    if (!cls) return 0;
    Class hookTarget = isMeta ? object_getClass(cls) : cls;
    if (!hookTarget) return 0;
    Class nsObject = [NSObject class];
    Class nsObjectMeta = object_getClass(nsObject);
    int totalHooked = 0; Class current = hookTarget; int depth = 0;
    while (current && depth < 10) {
        if (current == nsObject || current == nsObjectMeta) break;
        totalHooked += [self hookMethodsOfClass:current isMeta:isMeta];
        Class next = class_getSuperclass(current);
        if (next == current) break;
        current = next; depth++;
    }
    return totalHooked;
}

- (int)hookMethodsOfClass:(Class)hookTarget isMeta:(BOOL)isMeta {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(hookTarget, &count);
    int hooked = 0;
    NSString *definingClass = NSStringFromClass(hookTarget) ?: @"?";
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selStr = NSStringFromSelector(sel);
        NSString *low = [selStr lowercaseString];
        const char *typeEnc = method_getTypeEncoding(methods[i]);
        if (!typeEnc) continue;
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:typeEnc];
        if (!sig) continue;
        NSUInteger nArgs = sig.numberOfArguments;
        if (nArgs < 2) continue;
        int userArgs = (int)nArgs - 2;
        if (userArgs < 0 || userArgs > 6) continue;
        const char *retType = sig.methodReturnType;
        if (!retType || !retType[0]) continue;
        BOOL returnsId = (retType[0] == '@');
        BOOL isInitLike = returnsId && ([selStr isEqualToString:@"init"] || [selStr hasPrefix:@"initWith"]);
        if (isInitLike && userArgs <= 2) {
            NSString *key = [NSString stringWithFormat:@"TRACK|%@|%@|%d", definingClass, selStr, isMeta ? 1 : 0];
            if ([gHooked containsObject:key]) continue;
            [gHooked addObject:key];
            IMP orig = method_getImplementation(methods[i]);
            SEL capturedSel = sel;
            if (userArgs == 0) {
                id block = ^id(id self_) { id result = ((id(*)(id, SEL))orig)(self_, capturedSel); if (result) [[ChessFENExtractor shared] trackInstance:result]; return result; };
                method_setImplementation(methods[i], imp_implementationWithBlock(block)); [gRetainedBlocks addObject:block]; hooked++;
            } else if (userArgs == 1) {
                const char *a0 = [sig getArgumentTypeAtIndex:2];
                if (a0 && a0[0] == '@') {
                    id block = ^id(id self_, id arg) { id result = ((id(*)(id, SEL, id))orig)(self_, capturedSel, arg); if (result) [[ChessFENExtractor shared] trackInstance:result]; return result; };
                    method_setImplementation(methods[i], imp_implementationWithBlock(block)); [gRetainedBlocks addObject:block]; hooked++;
                }
            } else if (userArgs == 2) {
                const char *a0 = [sig getArgumentTypeAtIndex:2]; const char *a1 = [sig getArgumentTypeAtIndex:3];
                if (a0 && a0[0] == '@' && a1 && a1[0] == '@') {
                    id block = ^id(id self_, id arg1, id arg2) { id result = ((id(*)(id, SEL, id, id))orig)(self_, capturedSel, arg1, arg2); if (result) [[ChessFENExtractor shared] trackInstance:result]; return result; };
                    method_setImplementation(methods[i], imp_implementationWithBlock(block)); [gRetainedBlocks addObject:block]; hooked++;
                }
            }
            continue;
        }
        BOOL relevant = [low containsString:@"fen"] || [low containsString:@"board"] || [low containsString:@"position"] || [low containsString:@"snapshot"] || [low containsString:@"gamestate"] || [low containsString:@"chessstate"];
        if (!relevant) continue;
        NSString *key = [NSString stringWithFormat:@"%@|%@|%d", definingClass, selStr, isMeta ? 1 : 0];
        if ([gHooked containsObject:key]) continue;
        [gHooked addObject:key];
        if (userArgs == 0 && returnsId) {
            IMP orig = method_getImplementation(methods[i]);
            SEL capturedSel = sel;
            id retainedBlock = ^id(id self) {
                [[ChessFENExtractor shared] trackInstance:self];
                id result = ((id(*)(id, SEL))orig)(self, capturedSel);
                @try { CaptureFENIfValid(result, capturedSel); } @catch (NSException *e) { }
                return result;
            };
            IMP hookIMP = imp_implementationWithBlock(retainedBlock);
            [gRetainedBlocks addObject:retainedBlock];
            method_setImplementation(methods[i], hookIMP);
            hooked++;
        }
    }
    free(methods);
    return hooked;
}

@end
