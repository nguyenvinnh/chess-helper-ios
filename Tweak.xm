#import "ChessAssistantView.h"
#import "ChessFENExtractor.h"
#import "ChessLogStore.h"
#import "BoardPositionDetector.h"
#import "ArrowOverlay.h"
#import "ChessOfflineEngineClient.h"
#import "Core/CrashHandler.h"
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>

static ChessAssistantView *monitorWindow = nil;
static ChessFENExtractor *gFenExtractor = nil;
static BOOL gHasSeeded = NO;
static BOOL gUserHidden = NO;
static BOOL gShowingPanel = NO;
static NSInteger gHookedCount = 0;
static dispatch_source_t gWatchdogTimer = nil;

// Auto-start sau 2s khi vào foreground. Không còn opt-out.
static const NSTimeInterval kAutoStartDelay = 2.0;

static NSString *Timestamp(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm:ss";
    });
    return [fmt stringFromDate:[NSDate date]];
}

static void updateStatusLine(void) {
    if (!monitorWindow) return;
    NSString *state = monitorWindow.isMonitoringActive ? @"Monitoring" : @"Idle";
    [monitorWindow setStatusText:[NSString stringWithFormat:@"%@ | Hooks: %ld", state, (long)gHookedCount]];
}

static BOOL IsAppForeground(void) {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (s.activationState == UISceneActivationStateForegroundActive) return YES;
    }
    return NO;
}

static void StartMonitoring(void) {
    if (gFenExtractor.isHooking) return;
    if (monitorWindow) [monitorWindow setStatusText:@"Hooking..."];
    [gFenExtractor startSequentialHooking];
}

static void ScheduleBoardLocate(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { [[BoardPositionDetector shared] detectBoardView]; }
        @catch (NSException *e) { NSLog(@"[ChessAssistant] board locate ex: %@", e.reason); }
    });
}

// Auto-start: LUÔN chạy (không còn opt-out).
static void ScheduleAutoStart(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kAutoStartDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            if (!IsAppForeground()) return;
            if (!monitorWindow) return;
            if (gFenExtractor.isHooking) return;
            if (monitorWindow.isMonitoringActive) return;

            [monitorWindow setMonitoringActive:YES];
            StartMonitoring();
            ScheduleBoardLocate();
            NSLog(@"[ChessAssistant] auto-start triggered");
        } @catch (NSException *e) {
            NSLog(@"[ChessAssistant] autostart ex: %@", e.reason);
        }
    });
}

static void TryShowMonitor(void) {
    @try {
        if (gUserHidden || gShowingPanel) return;

        if (monitorWindow && !monitorWindow.hidden) {
            if (!monitorWindow.isMonitoringActive && !gFenExtractor.isHooking) {
                ScheduleAutoStart();
            }
            return;
        }

        UIWindowScene *activeScene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)s;
                break;
            }
        }
        if (!activeScene) return;

        gShowingPanel = YES;

        if (!monitorWindow) {
            monitorWindow = [[ChessAssistantView alloc] initWithWindowScene:activeScene];
        }
        if (!monitorWindow) { gShowingPanel = NO; return; }

        if (!gHasSeeded) {
            gHasSeeded = YES;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @try {
                    NSArray *existingLog = [[ChessLogStore shared] loadLogTail:20];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            if (monitorWindow) {
                                for (NSString *line in existingLog) [monitorWindow appendLog:line];
                            }
                        } @catch (NSException *e) { }
                    });
                } @catch (NSException *e) { }
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (!monitorWindow) { gShowingPanel = NO; return; }
                [monitorWindow show];
                gShowingPanel = NO;
                ScheduleAutoStart();
            } @catch (NSException *e) {
                gShowingPanel = NO;
            }
        });
    } @catch (NSException *e) {
        NSLog(@"[ChessAssistant] TryShowMonitor ex: %@", e.reason);
        gShowingPanel = NO;
    }
}

// Watchdog: nếu sau khi vào foreground 10s mà vẫn chưa hooking (bị reset,
// dylib inject chậm, ...), tự khởi động lại.
static void StartWatchdog(void) {
    if (gWatchdogTimer) return;
    gWatchdogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
    if (!gWatchdogTimer) return;
    dispatch_source_set_timer(gWatchdogTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                              (uint64_t)(10.0 * NSEC_PER_SEC),
                              (uint64_t)(1.0 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gWatchdogTimer, ^{
        @try {
            if (!IsAppForeground()) return;
            if (!monitorWindow) return;
            if (gFenExtractor.isHooking) return;
            if (!monitorWindow.isMonitoringActive) {
                NSLog(@"[ChessAssistant] watchdog: restarting monitoring");
                [monitorWindow setMonitoringActive:YES];
                StartMonitoring();
                ScheduleBoardLocate();
            }
        } @catch (NSException *e) { }
    });
    dispatch_resume(gWatchdogTimer);
}

// Scene observer
static void SetupSceneObserver(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UISceneDidActivateNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        @try { TryShowMonitor(); } @catch (NSException *e) { }
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ TryShowMonitor(); });
}

// Hook CHBoardView trực tiếp từ phân tích otool
// CHÚ Ý: KHÔNG hook CHGame fenForCurrentPosition vì bot engine gọi hàm này
// liên tục hàng trăm lần khi đang search/tính toán nước đi trong đầu nó,
// dẫn đến sinh ra các "FEN ảo" đè lên FEN thật của bàn cờ và gây giật lag cực nặng!
%hook CHBoardView

- (void)animateLastMove {
    %orig;
    @try {
        id selfObj = (id)self;
        id game = nil;
        if ([selfObj respondsToSelector:@selector(chessGame)]) {
            game = [selfObj performSelector:@selector(chessGame)];
        }
        if (game && [game respondsToSelector:@selector(fenForCurrentPosition:flipped:)]) {
            NSString *fen = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(game, @selector(fenForCurrentPosition:flipped:), NO, NO);
            if (fen) {
                [[ChessFENExtractor shared] handleFENFound:fen context:@"CHBoardView.animateLastMove"];
            }
        }
    } @catch (NSException *e) { }
}

- (void)updateMoveListDirectly {
    %orig;
    @try {
        id selfObj = (id)self;
        id game = nil;
        if ([selfObj respondsToSelector:@selector(chessGame)]) {
            game = [selfObj performSelector:@selector(chessGame)];
        }
        if (game && [game respondsToSelector:@selector(fenForCurrentPosition:flipped:)]) {
            NSString *fen = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(game, @selector(fenForCurrentPosition:flipped:), NO, NO);
            if (fen) {
                [[ChessFENExtractor shared] handleFENFound:fen context:@"CHBoardView.updateMoveList"];
            }
        }
    } @catch (NSException *e) { }
}

- (void)setupBoardForGame:(id)game updateHighlightsForLastMove:(BOOL)update {
    %orig;
    @try {
        if (game && [game respondsToSelector:@selector(fenForCurrentPosition:flipped:)]) {
            NSString *fen = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(game, @selector(fenForCurrentPosition:flipped:), NO, NO);
            if (fen) {
                [[ChessFENExtractor shared] handleFENFound:fen context:@"CHBoardView.setupBoard"];
            }
        }
    } @catch (NSException *e) { }
}

- (void)setupWithFEN:(id)fen is960:(BOOL)is960 {
    %orig;
    if (fen && [fen isKindOfClass:[NSString class]]) {
        [[ChessFENExtractor shared] handleFENFound:fen context:@"CHBoardView.setupWithFEN"];
    }
}

- (void)setupWithFEN:(id)fen {
    %orig;
    if (fen && [fen isKindOfClass:[NSString class]]) {
        [[ChessFENExtractor shared] handleFENFound:fen context:@"CHBoardView.setupWithFEN"];
    }
}

%end

// ============== Deferred init ==============
static void setupMonitoringDeferred(void) {
    @try {
        gFenExtractor = [ChessFENExtractor shared];

        gFenExtractor.logEmitter = ^(NSString *category, NSString *message) {
            @try {
                NSString *line = [NSString stringWithFormat:@"[%@][%@] %@",
                                  Timestamp(), category, message];
                [[ChessLogStore shared] appendLog:line];
                NSLog(@"[ChessAssistant] %@", line);

                if (![category isEqualToString:@"FEN"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (monitorWindow) {
                            [monitorWindow appendLog:[NSString stringWithFormat:@"[%@] %@", category, message]];
                        }
                    });
                }
            } @catch (NSException *e) {
                NSLog(@"[ChessAssistant] logEmitter ex: %@", e.reason);
            }
        };

        // ═══════════════════════════════════════════════════════════════
        // FIX (ARROW CLEARING):
        // Khi FEN đổi → xoá mũi tên cũ NGAY LẬP TỨC + cancel offline
        // requests đang chạy (kết quả của chúng sẽ là stale).
        // Không có bước này thì mỗi suggest lại "vẽ thêm" arrow mới
        // chồng lên arrow cũ → hiện tượng "vẽ thêm chứ không xoá".
        // ═══════════════════════════════════════════════════════════════
        gFenExtractor.fenFoundHandler = ^(NSString *fen) {
            @try {
                [[ChessLogStore shared] appendFEN:fen context:Timestamp()];
                [[ChessLogStore shared] appendLog:[NSString stringWithFormat:@"[%@][FEN] %@", Timestamp(), fen]];
                // View là owner duy nhất của clear/cancel, gọi đồng bộ trên main để
                // không có cửa sổ race giữa clear và setDetectedFEN.
                if ([NSThread isMainThread]) {
                    if (monitorWindow) [monitorWindow setDetectedFEN:fen];
                } else {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        if (monitorWindow) [monitorWindow setDetectedFEN:fen];
                    });
                }
            } @catch (NSException *e) {
                NSLog(@"[ChessAssistant] fenFoundHandler ex: %@", e.reason);
            }
        };

        [[NSNotificationCenter defaultCenter] addObserverForName:@"kChessAssistantToggle"
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            @try {
                BOOL on = [note.userInfo[@"on"] boolValue];
                if (on) { StartMonitoring(); ScheduleBoardLocate(); }
                else { [gFenExtractor stopMonitoring]; updateStatusLine(); }
            } @catch (NSException *e) { }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:@"kChessAssistantAutoDetect"
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            @try {
                if (!gFenExtractor.isHooking) StartMonitoring();
                ScheduleBoardLocate();
            } @catch (NSException *e) { }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:@"kChessAssistantUserHidden"
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            gUserHidden = YES;
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:@"kChessAssistantUserShown"
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            gUserHidden = NO;
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:@"kChessAssistantHookProgress"
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            @try {
                NSInteger current = [note.userInfo[@"current"] integerValue];
                NSInteger total   = [note.userInfo[@"total"] integerValue];
                NSString *cls     = note.userInfo[@"class"];
                if (monitorWindow) {
                    [monitorWindow setStatusText:[NSString stringWithFormat:
                        @"Hook %ld/%ld — %@", (long)current, (long)total, cls]];
                }
            } @catch (NSException *e) { }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:@"kChessAssistantHookedUpdated"
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            @try {
                gHookedCount = [note.userInfo[@"count"] integerValue];
                updateStatusLine();
            } @catch (NSException *e) { }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            @try { [[ChessLogStore shared] flush]; } @catch (NSException *e) { }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            @try {
                if (monitorWindow.isMonitoringActive && !gFenExtractor.isHooking) StartMonitoring();
            } @catch (NSException *e) { }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            @try { [[ChessLogStore shared] flush]; } @catch (NSException *e) { }
        }];

        NSString *lp = nil;
        @try { lp = [[ChessLogStore shared] logFilePath]; }
        @catch (NSException *e) { }
        NSLog(@"[ChessAssistant] Loaded. Log: %@", lp ?: @"(unavailable)");

        SetupSceneObserver();
        StartWatchdog();
    } @catch (NSException *e) {
        NSLog(@"[ChessAssistant] setupMonitoringDeferred ex: %@ — %@", e.name, e.reason);
    }
}

// ============== Constructor ==============
%ctor {
    @autoreleasepool {
        [CrashHandler installCrashHandlers];
        NSLog(@"[ChessAssistant] ctor ok — deferring init to main queue");
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            setupMonitoringDeferred();
        }
    });
}
