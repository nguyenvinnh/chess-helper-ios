#import "ChessAssistantView.h"
#import "ChessAPIClient.h"
#import "ChessOfflineEngineClient.h"
#import "ChessEngine/SuggestionPlanner.h"
#import "ChessEngine/FENValidator.h"
#import "ArrowOverlay.h"
#import "BoardPositionDetector.h"
#import <string.h>
#import <mach-o/getsect.h>
#import <mach-o/dyld.h>

static const CGFloat kWidth  = 300;
static const CGFloat kHeight = 520;

// Prefs
static NSString *const kPrefProvider  = @"ChessAssistant.ai.provider";
static NSString *const kPrefAuto      = @"ChessAssistant.ai.autoSuggest";
static NSString *const kPrefSide      = @"ChessAssistant.ai.side";
static NSString *const kPrefParallel  = @"ChessAssistant.ai.parallel";
static NSString *const kPrefTurnCheck = @"ChessAssistant.ai.turnCheck";

static const NSTimeInterval kAutoSuggestDebounce = 0.6;

#pragma mark - Icon loading (embedded section only)

// Đọc icon từ section __DATA,__icon (do -sectcreate nhúng vào dylib lúc build).
static UIImage *LoadBubbleIcon(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *hdr = _dyld_get_image_header(i);
        if (!hdr) continue;
        unsigned long size = 0;
        const uint8_t *data = getsectiondata((const struct mach_header_64 *)hdr,
                                             "__DATA", "__icon", &size);
        if (!data || size < 4) continue;
        if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) {
            UIImage *img = [UIImage imageWithData:[NSData dataWithBytes:data length:size]];
            if (img) return img;
        }
    }
    return nil;
}

#pragma mark - Check detection

static BOOL IsKingInCheck(NSString *fen, unichar color) {
    if (fen.length == 0) return NO;
    NSArray *parts = [fen componentsSeparatedByString:@" "];
    if (parts.count < 1) return NO;
    NSArray *ranks = [parts[0] componentsSeparatedByString:@"/"];
    if (ranks.count != 8) return NO;

    unichar board[8][8];
    memset(board, 0, sizeof(board));

    for (int r = 0; r < 8; r++) {
        NSString *rankStr = ranks[r];
        int c = 0;
        for (NSUInteger i = 0; i < rankStr.length && c < 8; i++) {
            unichar ch = [rankStr characterAtIndex:i];
            if (ch >= '1' && ch <= '8') c += (ch - '0');
            else { if (c < 8) board[r][c] = ch; c++; }
        }
    }

    unichar kingChar = (color == 'w') ? 'K' : 'k';
    int kr = -1, kc = -1;
    for (int r = 0; r < 8 && kr < 0; r++) {
        for (int c = 0; c < 8; c++) {
            if (board[r][c] == kingChar) { kr = r; kc = c; break; }
        }
    }
    if (kr < 0) return NO;

    BOOL isWhite = (color == 'w');
    int pawnRow = isWhite ? kr - 1 : kr + 1;
    unichar enemyPawn = isWhite ? 'p' : 'P';
    if (pawnRow >= 0 && pawnRow < 8) {
        if (kc - 1 >= 0 && board[pawnRow][kc - 1] == enemyPawn) return YES;
        if (kc + 1 < 8  && board[pawnRow][kc + 1] == enemyPawn) return YES;
    }

    unichar enemyKnight = isWhite ? 'n' : 'N';
    static const int km[8][2] = {{-2,-1},{-2,1},{-1,-2},{-1,2},{1,-2},{1,2},{2,-1},{2,1}};
    for (int k = 0; k < 8; k++) {
        int nr = kr + km[k][0], nc = kc + km[k][1];
        if (nr >= 0 && nr < 8 && nc >= 0 && nc < 8 && board[nr][nc] == enemyKnight)
            return YES;
    }

    unichar enemyBishop = isWhite ? 'b' : 'B';
    unichar enemyQueen  = isWhite ? 'q' : 'Q';
    static const int dm[4][2] = {{-1,-1},{-1,1},{1,-1},{1,1}};
    for (int k = 0; k < 4; k++) {
        int r = kr + dm[k][0], c = kc + dm[k][1];
        while (r >= 0 && r < 8 && c >= 0 && c < 8) {
            unichar p = board[r][c];
            if (p) {
                if (p == enemyBishop || p == enemyQueen) return YES;
                break;
            }
            r += dm[k][0]; c += dm[k][1];
        }
    }

    unichar enemyRook = isWhite ? 'r' : 'R';
    static const int om[4][2] = {{-1,0},{1,0},{0,-1},{0,1}};
    for (int k = 0; k < 4; k++) {
        int r = kr + om[k][0], c = kc + om[k][1];
        while (r >= 0 && r < 8 && c >= 0 && c < 8) {
            unichar p = board[r][c];
            if (p) {
                if (p == enemyRook || p == enemyQueen) return YES;
                break;
            }
            r += om[k][0]; c += om[k][1];
        }
    }

    unichar enemyKing = isWhite ? 'k' : 'K';
    for (int dr = -1; dr <= 1; dr++) {
        for (int dc = -1; dc <= 1; dc++) {
            if (dr == 0 && dc == 0) continue;
            int nr = kr + dr, nc = kc + dc;
            if (nr >= 0 && nr < 8 && nc >= 0 && nc < 8 && board[nr][nc] == enemyKing)
                return YES;
        }
    }
    return NO;
}

#pragma mark - View

@interface ChessAssistantView ()
@property (nonatomic, strong) UIViewController *rootVC;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) UIButton *bubbleButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UILabel *statusBadge;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *fenTextView;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *logTitleLabel;
@property (nonatomic, copy, readwrite) NSString *currentFEN;
@property (nonatomic, assign) BOOL menuVisible;
@property (nonatomic, assign) CGPoint bubbleOrigin;
@property (nonatomic, assign) CGPoint panelOrigin;
@property (nonatomic, assign) CGPoint dragStart;

@property (nonatomic, strong) UISegmentedControl *providerSegment;
@property (nonatomic, strong) UILabel *depthLabel;
@property (nonatomic, strong) UISlider *depthSlider;
@property (nonatomic, strong) UISwitch *autoSuggestSwitch;

@property (nonatomic, strong) UILabel *sideLabel;
@property (nonatomic, strong) UISwitch *sideSwitch;
@property (nonatomic, strong) UIButton *parallelButton;
@property (nonatomic, assign) BOOL parallelMode;

@property (nonatomic, strong) UILabel *turnCheckLabel;
@property (nonatomic, strong) UISwitch *turnCheckSwitch;

@property (nonatomic, strong) UIButton *suggestButton;
@property (nonatomic, strong) UIButton *clearArrowsButton;
@property (nonatomic, strong) UIButton *resetBlacklistButton;
@property (nonatomic, assign) BOOL suggestInFlight;

@property (nonatomic, assign) NSUInteger requestSeq;
@property (nonatomic, strong) NSMutableArray<NSURLSessionDataTask *> *inflightTasks;

@property (nonatomic, strong) NSMutableArray<NSString *> *logEntries;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingLogLines;
@property (nonatomic, assign) BOOL logUpdateScheduled;
@property (nonatomic, assign) NSInteger errorCount;
@end

@implementation ChessAssistantView

- (instancetype)initWithWindowScene:(UIWindowScene *)scene {
    if (!scene) return nil;
    self = [super initWithWindowScene:scene];
    if (self) {
        self.frame = [UIScreen mainScreen].bounds;
        _logEntries = [NSMutableArray array];
        _pendingLogLines = [NSMutableArray array];
        _inflightTasks = [NSMutableArray array];
        _isMonitoringActive = NO;
        _menuVisible = NO;
        _suggestInFlight = NO;
        _requestSeq = 0;
        _errorCount = 0;
        _parallelMode = NO;
        _bubbleOrigin = CGPointMake(20, 60);
        _panelOrigin = CGPointMake(20, 60);
        [self setup];
    }
    return self;
}

- (void)setup {
    self.windowLevel = UIWindowLevelAlert + 1000.0;
    self.backgroundColor = [UIColor clearColor];
    self.hidden = YES;

    _rootVC = [[UIViewController alloc] init];
    _rootVC.view.backgroundColor = [UIColor clearColor];
    _rootVC.view.frame = self.bounds;
    _rootVC.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.rootViewController = _rootVC;

    _container = [[UIView alloc] initWithFrame:CGRectMake(_panelOrigin.x, _panelOrigin.y, kWidth, kHeight)];
    _container.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.14 alpha:0.97];
    _container.layer.cornerRadius = 12;
    _container.layer.masksToBounds = YES;
    _container.hidden = YES;
    [_rootVC.view addSubview:_container];

    UIPanGestureRecognizer *panelPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    [_container addGestureRecognizer:panelPan];

    _bubbleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _bubbleButton.frame = CGRectMake(_bubbleOrigin.x, _bubbleOrigin.y, 50, 50);
    _bubbleButton.clipsToBounds = YES;
    _bubbleButton.layer.cornerRadius = 25;
    _bubbleButton.layer.masksToBounds = YES;
    _bubbleButton.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.20 alpha:0.92];
    _bubbleButton.layer.borderWidth = 2;
    _bubbleButton.layer.borderColor = [UIColor colorWithRed:0.20 green:0.75 blue:0.55 alpha:1.0].CGColor;

    UIImage *icon = LoadBubbleIcon();
    if (icon) {
        [_bubbleButton setBackgroundImage:icon forState:UIControlStateNormal];
    } else {
        [_bubbleButton setTitle:@"♞" forState:UIControlStateNormal];
        [_bubbleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _bubbleButton.titleLabel.font = [UIFont systemFontOfSize:28];
    }

    [_bubbleButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [_rootVC.view addSubview:_bubbleButton];

    UIPanGestureRecognizer *bubblePan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBubblePan:)];
    [_bubbleButton addGestureRecognizer:bubblePan];

    [self buildPanelUI];
    [self loadSettings];

    // Khởi tạo Offline Engine scan sớm
    [[ChessOfflineEngineClient shared] setLogEmitter:^(NSString *msg) {
        if (msg.length > 0) NSLog(@"[ChessAssistant][OFF] %@", msg);
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = [[ChessOfflineEngineClient shared] detectEngine];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [self appendLog:[NSString stringWithFormat:
                    @"[OFF] ✅ %@", [ChessOfflineEngineClient shared].detectedClassName ?: @"?"]];
            } else {
                [self appendLog:@"[OFF] ❌ Không tìm thấy engine offline"];
            }
        });
    });
}

- (void)buildPanelUI {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kWidth, 36)];
    header.backgroundColor = [UIColor colorWithRed:0.14 green:0.16 blue:0.20 alpha:1.0];
    [self.container addSubview:header];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 240, 36)];
    title.text = @"Chess Move Suggest";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:14];
    [header addSubview:title];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.frame = CGRectMake(kWidth - 36, 0, 36, 36);
    [self.closeButton setTitle:@"X" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.closeButton];

    self.statusBadge = [[UILabel alloc] initWithFrame:CGRectMake(8, 40, kWidth - 16, 32)];
    self.statusBadge.layer.cornerRadius = 8;
    self.statusBadge.layer.masksToBounds = YES;
    self.statusBadge.textAlignment = NSTextAlignmentCenter;
    self.statusBadge.font = [UIFont boldSystemFontOfSize:13];
    self.statusBadge.textColor = [UIColor whiteColor];
    self.statusBadge.userInteractionEnabled = NO;
    [self.container addSubview:self.statusBadge];
    [self refreshStatusBadge];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 76, kWidth - 24, 14)];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.text = @"Idle";
    [self.container addSubview:self.statusLabel];

    UILabel *fenTitle = [[UILabel alloc] initWithFrame:CGRectMake(12, 94, kWidth - 24, 12)];
    fenTitle.text = @"FEN hiện tại";
    fenTitle.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    fenTitle.font = [UIFont boldSystemFontOfSize:10];
    [self.container addSubview:fenTitle];

    self.fenTextView = [[UITextView alloc] initWithFrame:CGRectMake(8, 108, kWidth - 16, 36)];
    self.fenTextView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    self.fenTextView.textColor = [UIColor colorWithRed:0.6 green:1.0 blue:0.7 alpha:1.0];
    self.fenTextView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    self.fenTextView.editable = NO;
    self.fenTextView.selectable = YES;
    self.fenTextView.layer.cornerRadius = 6;
    self.fenTextView.text = @"(chưa có — chờ hook xong)";
    [self.container addSubview:self.fenTextView];

    self.providerSegment = [[UISegmentedControl alloc] initWithItems:@[@"Stockfish", @"Chess-API", @"Offline"]];
    self.providerSegment.frame = CGRectMake(8, 148, kWidth - 16, 32);
    self.providerSegment.selectedSegmentIndex = 0;
    self.providerSegment.tintColor = [UIColor colorWithRed:0.3 green:0.6 blue:0.9 alpha:1.0];
    [self.providerSegment addTarget:self action:@selector(providerChanged:)
                   forControlEvents:UIControlEventValueChanged];
    [self.container addSubview:self.providerSegment];

    self.depthLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 184, kWidth - 24, 14)];
    self.depthLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    self.depthLabel.font = [UIFont boldSystemFontOfSize:10];
    self.depthLabel.text = @"Depth: 10 (Stockfish 5–12)";
    [self.container addSubview:self.depthLabel];

    self.depthSlider = [[UISlider alloc] initWithFrame:CGRectMake(8, 200, kWidth - 16, 26)];
    self.depthSlider.minimumValue = 5;
    self.depthSlider.maximumValue = 12;
    self.depthSlider.value = 10;
    self.depthSlider.tintColor = [UIColor colorWithRed:0.3 green:0.7 blue:0.5 alpha:1.0];
    [self.depthSlider addTarget:self action:@selector(depthChanged:)
               forControlEvents:UIControlEventValueChanged];
    [self.container addSubview:self.depthSlider];

    self.sideLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 232, 48, 28)];
    self.sideLabel.text = @"Trắng";
    self.sideLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    self.sideLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.container addSubview:self.sideLabel];

    self.sideSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(62, 228, 51, 31)];
    self.sideSwitch.onTintColor = [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0];
    [self.sideSwitch addTarget:self action:@selector(sideToggleChanged:)
              forControlEvents:UIControlEventValueChanged];
    [self.container addSubview:self.sideSwitch];

    self.parallelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.parallelButton.frame = CGRectMake(120, 228, 172, 31);
    self.parallelButton.layer.cornerRadius = 6;
    self.parallelButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.parallelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.parallelButton addTarget:self action:@selector(parallelTapped)
                  forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.parallelButton];

    self.turnCheckLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 262, 95, 31)];
    self.turnCheckLabel.text = @"Kiểm tra lượt";
    self.turnCheckLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    self.turnCheckLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.container addSubview:self.turnCheckLabel];

    self.turnCheckSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(112, 262, 51, 31)];
    self.turnCheckSwitch.onTintColor = [UIColor colorWithRed:0.35 green:0.55 blue:0.85 alpha:1.0];
    self.turnCheckSwitch.on = YES;
    [self.turnCheckSwitch addTarget:self action:@selector(turnCheckChanged:)
                   forControlEvents:UIControlEventValueChanged];
    [self.container addSubview:self.turnCheckSwitch];

    UILabel *autoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 300, 40, 20)];
    autoLabel.text = @"Auto";
    autoLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    autoLabel.font = [UIFont systemFontOfSize:11];
    [self.container addSubview:autoLabel];

    self.autoSuggestSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(50, 296, 51, 31)];
    self.autoSuggestSwitch.onTintColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.4 alpha:1.0];
    [self.autoSuggestSwitch addTarget:self action:@selector(autoToggleChanged:)
                     forControlEvents:UIControlEventValueChanged];
    [self.container addSubview:self.autoSuggestSwitch];

    self.suggestButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.suggestButton.frame = CGRectMake(112, 298, 116, 32);
    self.suggestButton.backgroundColor = [UIColor colorWithRed:0.25 green:0.65 blue:0.40 alpha:1.0];
    self.suggestButton.layer.cornerRadius = 6;
    self.suggestButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [self.suggestButton setTitle:@"Suggest" forState:UIControlStateNormal];
    [self.suggestButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.suggestButton addTarget:self action:@selector(suggestTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.suggestButton];

    self.clearArrowsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.clearArrowsButton.frame = CGRectMake(232, 298, 60, 32);
    self.clearArrowsButton.backgroundColor = [UIColor colorWithWhite:0.30 alpha:1.0];
    self.clearArrowsButton.layer.cornerRadius = 6;
    self.clearArrowsButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [self.clearArrowsButton setTitle:@"Clear" forState:UIControlStateNormal];
    [self.clearArrowsButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.clearArrowsButton addTarget:self action:@selector(clearArrowsTapped)
                     forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.clearArrowsButton];

    self.resetBlacklistButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.resetBlacklistButton.frame = CGRectMake(8, 374, kWidth - 16, 26);
    self.resetBlacklistButton.backgroundColor = [UIColor colorWithRed:0.6 green:0.35 blue:0.2 alpha:1.0];
    self.resetBlacklistButton.layer.cornerRadius = 6;
    self.resetBlacklistButton.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    [self.resetBlacklistButton setTitle:@"Reset blacklist (provider/depth)"
                              forState:UIControlStateNormal];
    [self.resetBlacklistButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.resetBlacklistButton addTarget:self action:@selector(resetBlacklist)
                        forControlEvents:UIControlEventTouchUpInside];
    [self.container addSubview:self.resetBlacklistButton];

    self.logTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 404, kWidth - 24, 12)];
    self.logTitleLabel.text = @"LOG — errors & events";
    self.logTitleLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.logTitleLabel.font = [UIFont boldSystemFontOfSize:10];
    [self.container addSubview:self.logTitleLabel];

    self.logTextView = [[UITextView alloc] initWithFrame:CGRectMake(8, 418, kWidth - 16, 94)];
    self.logTextView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    self.logTextView.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    self.logTextView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    self.logTextView.editable = NO;
    self.logTextView.layer.cornerRadius = 6;
    self.logTextView.text = @"(chưa có sự kiện)";
    [self.container addSubview:self.logTextView];
}

#pragma mark - Settings

- (void)loadSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];

    NSInteger provider = [d integerForKey:kPrefProvider];
    if (provider < 0 || provider > 2) provider = 0;
    self.providerSegment.selectedSegmentIndex = provider;
    [self configureSliderForProvider:provider loadDepth:YES];

    self.autoSuggestSwitch.on = [d boolForKey:kPrefAuto];
    self.sideSwitch.on        = [d boolForKey:kPrefSide];
    self.parallelMode         = [d boolForKey:kPrefParallel];

    NSNumber *turnCheckSaved = [d objectForKey:kPrefTurnCheck];
    self.turnCheckSwitch.on = turnCheckSaved ? [turnCheckSaved boolValue] : YES;

    self.sideLabel.text = self.sideSwitch.isOn ? @"Đen" : @"Trắng";
    [self refreshParallelButton];
}

- (void)saveSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:self.providerSegment.selectedSegmentIndex forKey:kPrefProvider];
    [d setBool:self.autoSuggestSwitch.isOn forKey:kPrefAuto];
    [d setBool:self.sideSwitch.isOn        forKey:kPrefSide];
    [d setBool:self.parallelMode           forKey:kPrefParallel];
    [d setBool:self.turnCheckSwitch.isOn   forKey:kPrefTurnCheck];

    NSInteger provider = self.providerSegment.selectedSegmentIndex;
    NSInteger depthVal = (NSInteger)round(self.depthSlider.value);
    [d setInteger:depthVal forKey:[NSString stringWithFormat:@"ChessAssistant.ai.depth.%ld", (long)provider]];
}

- (void)configureSliderForProvider:(NSInteger)provider loadDepth:(BOOL)loadDepth {
    ChessAPIProvider p = (ChessAPIProvider)provider;
    NSInteger minV = [ChessAPIClient minDepthForProvider:p];
    NSInteger maxV = [ChessAPIClient maxDepthForProvider:p];
    NSInteger fallbackV = (provider == 2) ? 12 : (provider == 0 ? 10 : 12);
    NSString *provName = [ChessAPIClient longNameForProvider:p];

    self.depthSlider.minimumValue = minV;
    self.depthSlider.maximumValue = maxV;
    self.depthSlider.tintColor = (provider == 0) ? [UIColor colorWithRed:0.3 green:0.7 blue:0.5 alpha:1.0]
                             : (provider == 1) ? [UIColor colorWithRed:0.7 green:0.5 blue:0.9 alpha:1.0]
                                               : [UIColor colorWithRed:0.9 green:0.7 blue:0.3 alpha:1.0];

    NSInteger newValue;
    if (loadDepth) {
        NSString *key = [NSString stringWithFormat:@"ChessAssistant.ai.depth.%ld", (long)provider];
        NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:key];
        newValue = (stored < minV || stored > maxV) ? fallbackV : stored;
    } else {
        newValue = (NSInteger)round(self.depthSlider.value);
        if (newValue < minV) newValue = minV;
        if (newValue > maxV) newValue = maxV;
    }
    self.depthSlider.value = newValue;
    self.depthLabel.text = [NSString stringWithFormat:@"Depth: %ld (%@ %ld–%ld)",
                            (long)newValue, provName, (long)minV, (long)maxV];
}

#pragma mark - Menu

- (void)toggleMenu {
    self.menuVisible = !self.menuVisible;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.container.hidden = !self.menuVisible;
        self.bubbleButton.hidden = self.menuVisible;
    });
    if (self.menuVisible) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kChessAssistantUserShown" object:nil];
    }
}

- (void)closeTapped {
    [self toggleMenu];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"kChessAssistantUserHidden" object:nil];
}

#pragma mark - Status badge

- (void)refreshStatusBadge {
    if (self.isMonitoringActive) {
        self.statusBadge.text = @"● Đang theo dõi";
        self.statusBadge.backgroundColor = [UIColor colorWithRed:0.20 green:0.55 blue:0.30 alpha:1.0];
    } else {
        self.statusBadge.text = @"○ Chưa kích hoạt";
        self.statusBadge.backgroundColor = [UIColor colorWithWhite:0.30 alpha:1.0];
    }
}

- (void)setMonitoringActive:(BOOL)active {
    self.isMonitoringActive = active;
    [self refreshStatusBadge];
}

#pragma mark - Controls callbacks

- (void)providerChanged:(UISegmentedControl *)sender {
    [self configureSliderForProvider:sender.selectedSegmentIndex loadDepth:YES];
    [self saveSettings];
}

- (void)depthChanged:(UISlider *)sender {
    NSInteger val = (NSInteger)round(sender.value);
    sender.value = val;
    ChessAPIProvider p = (ChessAPIProvider)self.providerSegment.selectedSegmentIndex;
    self.depthLabel.text = [NSString stringWithFormat:@"Depth: %ld (%@ %ld–%ld)",
                            (long)val, [ChessAPIClient longNameForProvider:p],
                            (long)[ChessAPIClient minDepthForProvider:p],
                            (long)[ChessAPIClient maxDepthForProvider:p]];
    [self saveSettings];
}

- (void)sideToggleChanged:(UISwitch *)sender {
    self.sideLabel.text = sender.isOn ? @"Đen (Tay)" : @"Trắng (Tay)";
    [self saveSettings];
    [self appendLog:[NSString stringWithFormat:@"[Side] Chuyển thủ công: Cầm quân %@", sender.isOn ? @"ĐEN" : @"TRẮNG"]];
}

- (void)updateUserSideIsBlack:(BOOL)isBlack autoDetected:(BOOL)autoDetected {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.sideSwitch.isOn != isBlack) {
            [self.sideSwitch setOn:isBlack animated:YES];
            [self saveSettings];
            [self appendLog:[NSString stringWithFormat:@"[Side] Tự động nhận diện: Cầm quân %@", isBlack ? @"ĐEN" : @"TRẮNG"]];
        }
        self.sideLabel.text = isBlack ? @"Đen" : @"Trắng";
    });
}

- (void)turnCheckChanged:(UISwitch *)sender {
    [self saveSettings];
}

- (void)autoToggleChanged:(UISwitch *)sender {
    [self saveSettings];
    if (sender.isOn && self.currentFEN.length > 0 &&
        [self isOurTurnForFEN:self.currentFEN]) {
        [self scheduleAutoSuggest];
    }
}

- (void)parallelTapped {
    self.parallelMode = !self.parallelMode;
    [self refreshParallelButton];
    [self saveSettings];

    if (self.autoSuggestSwitch.isOn && self.currentFEN.length > 0 &&
        [self isOurTurnForFEN:self.currentFEN]) {
        [self scheduleAutoSuggest];
    }
}

- (void)refreshParallelButton {
    if (self.parallelMode) {
        [self.parallelButton setTitle:@"Song song: BẬT" forState:UIControlStateNormal];
        self.parallelButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.65 blue:0.40 alpha:1.0];
        self.sideSwitch.enabled = NO;
        self.sideSwitch.alpha = 0.35;
        self.sideLabel.alpha = 0.35;
    } else {
        [self.parallelButton setTitle:@"Song song: TẮT" forState:UIControlStateNormal];
        self.parallelButton.backgroundColor = [UIColor colorWithWhite:0.30 alpha:1.0];
        self.sideSwitch.enabled = YES;
        self.sideSwitch.alpha = 1.0;
        self.sideLabel.alpha = 1.0;
    }
}

- (void)clearArrowsTapped {
    self.requestSeq++;
    [self cancelInflightTasks];
    [[ChessOfflineEngineClient shared] cancelAllRequests];
    [[ArrowOverlay shared] clear];

    self.suggestInFlight = NO;
    self.suggestButton.enabled = YES;
    self.suggestButton.alpha = 1.0;
    [self.suggestButton setTitle:@"Suggest" forState:UIControlStateNormal];

    [self appendLog:@"[AI] Đã xoá mũi tên"];
}

- (void)resetBlacklist {
    [[SuggestionPlanner shared] resetBlacklist];
    [self appendLog:@"[AI] Reset blacklist — tất cả provider/depth được phép thử lại"];
}

#pragma mark - Request cancellation

- (void)cancelInflightTasks {
    if (self.inflightTasks.count == 0) return;
    for (NSURLSessionDataTask *t in self.inflightTasks) [t cancel];
    [self.inflightTasks removeAllObjects];
}

#pragma mark - Auto-suggest scheduling

- (void)scheduleAutoSuggest {
    NSUInteger seq = self.requestSeq;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kAutoSuggestDebounce * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.requestSeq != seq) return;
        if (!strongSelf.autoSuggestSwitch.isOn) return;
        if (strongSelf.currentFEN.length == 0) return;
        if (![strongSelf isOurTurnForFEN:strongSelf.currentFEN]) return;
        [strongSelf startSuggestionFlow];
    });
}

#pragma mark - Turn check

- (BOOL)isOurTurnForFEN:(NSString *)fen {
    if (!self.turnCheckSwitch.isOn) return YES;
    NSArray *parts = [fen componentsSeparatedByString:@" "];
    if (parts.count < 2) return NO;
    NSString *side = parts[1];
    return self.sideSwitch.isOn ? [side isEqualToString:@"b"] : [side isEqualToString:@"w"];
}

#pragma mark - Suggestion execution (delegated to SuggestionPlanner)

- (ChessAPIProvider)selectedProvider {
    return (ChessAPIProvider)self.providerSegment.selectedSegmentIndex;
}

- (void)suggestTapped {
    if (self.suggestInFlight) {
        [self appendLog:@"[AI] Đang chờ kết quả, vui lòng đợi..."];
        return;
    }
    [self startSuggestionFlow];
}

- (void)startSuggestionFlow {
    NSString *fen = self.currentFEN;
    if (fen.length == 0) { [self appendLog:@"[ERR] Chưa có FEN"]; return; }

    NSArray *parts = [fen componentsSeparatedByString:@" "];
    if (parts.count < 2) { [self appendLog:@"[ERR] FEN không hợp lệ"]; return; }

    // Xác định bên cần gợi ý
    BOOL needW, needB;
    NSString *reason;
    if (!self.parallelMode) {
        if (self.sideSwitch.isOn) { needW = NO; needB = YES; reason = @"B"; }
        else                       { needW = YES; needB = NO; reason = @"W"; }
    } else {
        BOOL wC = IsKingInCheck(fen, 'w');
        BOOL bC = IsKingInCheck(fen, 'b');
        if (wC && !bC) { needW = YES; needB = NO; reason = @"W check"; }
        else if (bC && !wC) { needW = NO; needB = YES; reason = @"B check"; }
        else { needW = YES; needB = YES; reason = @"both"; }
    }

    NSInteger reqD = (NSInteger)round(self.depthSlider.value);
    NSArray *plan = [[SuggestionPlanner shared] buildAttemptPlanWithRequestedDepth:reqD
                                                                   selectedProvider:[self selectedProvider]];

    if (plan.count == 0) {
        [self appendLog:@"[ERR] Không còn provider/depth khả dụng"];
        return;
    }

    [self appendLog:[NSString stringWithFormat:
        @"[AI] ▶ Plan %ld bước — requestedD=%ld side=%@",
        (long)plan.count, (long)reqD, reason]];

    // Clear + cancel TRƯỚC khi suggest mới, không để mũi tên cũ chồng lên.
    [[ArrowOverlay shared] clear];
    self.requestSeq++;
    [self cancelInflightTasks];
    [[ChessOfflineEngineClient shared] cancelAllRequests];

    self.suggestInFlight = YES;
    self.suggestButton.enabled = NO;
    self.suggestButton.alpha = 0.5;
    [self.suggestButton setTitle:@"Loading..." forState:UIControlStateNormal];

    [self executeAttemptAtIndex:0 plan:plan fen:fen needW:needW needB:needB];
}

- (void)executeAttemptAtIndex:(NSInteger)idx
                         plan:(NSArray *)plan
                          fen:(NSString *)fen
                        needW:(BOOL)needW
                        needB:(BOOL)needB {
    if (idx >= (NSInteger)plan.count) {
        [self finalizeSuggestionSuccess:NO];
        return;
    }

    NSDictionary *att = plan[idx];
    ChessAPIProvider provider = (ChessAPIProvider)[att[@"provider"] integerValue];
    NSInteger depth = [att[@"depth"] integerValue];

    NSUInteger mySeq = self.requestSeq;
    NSString *provShort = [ChessAPIClient shortNameForProvider:provider];

    [self appendLog:[NSString stringWithFormat:
        @"[AI] ▶ Thử %ld/%ld: %@ d=%ld", (long)(idx + 1), (long)plan.count,
        provShort, (long)depth]];

    __block BOOL wOK = !needW;
    __block BOOL bOK = !needB;
    __block NSInteger pending = (needW ? 1 : 0) + (needB ? 1 : 0);
    __block BOOL anyOK = NO;

    void (^onSideDone)(BOOL, ChessAPIResult *, NSError *) =
    ^(BOOL isW, ChessAPIResult *r, NSError *e) {
        if (mySeq != self.requestSeq) return;

        BOOL ok = (r.bestMoveUCI.length > 0);
        if (ok) anyOK = YES;
        if (isW) wOK = ok; else bOK = ok;

        if (ok) {
            BOOL flip = self.sideSwitch.isOn;
            UIColor *color = isW
                ? [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:0.9]
                : [UIColor colorWithRed:1.0 green:0.25 blue:0.25 alpha:0.9];
            [[ArrowOverlay shared] drawArrowForUCIMove:r.bestMoveUCI
                                                flipped:flip
                                                  color:color
                                               forWhite:isW];
            [self appendLog:[NSString stringWithFormat:
                @"[AI][%@][OK] %@ — %@ d=%ld",
                isW ? @"W" : @"B", r.bestMoveUCI, provShort, (long)depth]];
        } else {
            [self appendLog:[NSString stringWithFormat:
                @"[AI][%@][FAIL] %@", isW ? @"W" : @"B",
                e.userInfo[NSLocalizedDescriptionKey] ?: @"unknown"]];
        }

        pending--;
        if (pending > 0) return;

        if (wOK && bOK) {
            [[SuggestionPlanner shared] recordSuccess:provider atDepth:depth];
            [self finalizeSuggestionSuccess:YES];
            return;
        }

        if (anyOK) {
            [[SuggestionPlanner shared] recordSuccess:provider atDepth:depth];
        } else {
            [[SuggestionPlanner shared] recordFailure:provider atDepth:depth];
        }

        [self executeAttemptAtIndex:idx + 1
                               plan:plan
                                fen:fen
                              needW:(needW && !wOK)
                              needB:(needB && !bOK)];
    };

    NSMutableArray *fenParts = [[fen componentsSeparatedByString:@" "] mutableCopy];
    NSString *fenW = nil, *fenB = nil;
    if (needW && fenParts.count >= 2) {
        fenParts[1] = @"w";
        fenW = [fenParts componentsJoinedByString:@" "];
    }
    if (needB && fenParts.count >= 2) {
        fenParts[1] = @"b";
        fenB = [fenParts componentsJoinedByString:@" "];
    }

    if (needW) {
        NSURLSessionDataTask *t = [[ChessAPIClient shared]
            requestBestMoveForFEN:fenW depth:depth provider:provider
                       completion:^(ChessAPIResult *r, NSError *e) { onSideDone(YES, r, e); }];
        if (t) [self.inflightTasks addObject:t];
    }
    if (needB) {
        NSURLSessionDataTask *t = [[ChessAPIClient shared]
            requestBestMoveForFEN:fenB depth:depth provider:provider
                       completion:^(ChessAPIResult *r, NSError *e) { onSideDone(NO, r, e); }];
        if (t) [self.inflightTasks addObject:t];
    }
}

- (void)finalizeSuggestionSuccess:(BOOL)success {
    self.suggestInFlight = NO;
    self.suggestButton.enabled = YES;
    self.suggestButton.alpha = 1.0;
    [self.suggestButton setTitle:@"Suggest" forState:UIControlStateNormal];

    if (!success) {
        [self appendLog:@"[ERR] Đã thử hết plan — không có gợi ý"];
        [self appendLog:@"[ERR] Kiểm tra: kết nối mạng / Reset blacklist / giảm depth"];
    }
}

#pragma mark - Data setters

- (void)setStatusText:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = text ?: @"";
    });
}

- (void)setDetectedFEN:(NSString *)fen {
    if (fen.length == 0) return;

    // Tự động nhận diện bên người dùng (Trắng/Đen) từ CHBoardView dựa trên phân tích otool
    BOOL detectedBlack = [[BoardPositionDetector shared] detectUserIsPlayingBlack];
    [self updateUserSideIsBlack:detectedBlack autoDetected:YES];

    NSString *newNorm = [FENValidator normalizedFEN:fen];
    NSString *oldNorm = [FENValidator normalizedFEN:self.currentFEN];
    if (newNorm && oldNorm && [newNorm isEqualToString:oldNorm]) return;
    BOOL fenChanged = !(newNorm && oldNorm && [newNorm isEqualToString:oldNorm]);

    self.currentFEN = fen;
    self.fenTextView.text = fen;

    if (fenChanged) {
        [[ArrowOverlay shared] clear];
        self.requestSeq++;
        [self cancelInflightTasks];
        [[ChessOfflineEngineClient shared] cancelAllRequests];

        if (self.suggestInFlight) {
            self.suggestInFlight = NO;
            self.suggestButton.enabled = YES;
            self.suggestButton.alpha = 1.0;
            [self.suggestButton setTitle:@"Suggest" forState:UIControlStateNormal];
        }
    }

    if (self.autoSuggestSwitch.isOn && [self isOurTurnForFEN:fen]) {
        [self scheduleAutoSuggest];
    }
}

#pragma mark - Log

- (void)appendLog:(NSString *)line {
    if (!line) return;

    BOOL isError = [line containsString:@"[ERR]"] || [line containsString:@"FAIL"];
    if (isError) self.errorCount++;

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fmt = [NSDateFormatter new]; fmt.dateFormat = @"HH:mm:ss"; });
    NSString *stamped = [NSString stringWithFormat:@"[%@] %@", [fmt stringFromDate:[NSDate date]], line];

    @synchronized (self) {
        [self.pendingLogLines addObject:stamped];
        if (self.logUpdateScheduled) return;
        self.logUpdateScheduled = YES;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf flushPendingLogs]; });
}

- (void)flushPendingLogs {
    NSArray<NSString *> *batch = nil;
    @synchronized (self) {
        batch = [self.pendingLogLines copy];
        [self.pendingLogLines removeAllObjects];
        self.logUpdateScheduled = NO;
    }
    if (batch.count == 0) return;

    [self.logEntries addObjectsFromArray:batch];
    while (self.logEntries.count > 60) [self.logEntries removeObjectAtIndex:0];

    self.logTextView.text = [self.logEntries componentsJoinedByString:@"\n"];
    if (self.logTextView.text.length > 0) {
        [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length - 1, 1)];
    }

    if (self.errorCount > 0) {
        self.logTitleLabel.text = [NSString stringWithFormat:@"LOG — %ld lỗi", (long)self.errorCount];
        self.logTitleLabel.textColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
    } else {
        self.logTitleLabel.text = @"LOG — errors & events";
        self.logTitleLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    }
}

#pragma mark - Gestures

- (void)handleBubblePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:nil];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragStart = self.bubbleButton.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        self.bubbleButton.center = CGPointMake(self.dragStart.x + t.x, self.dragStart.y + t.y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        self.bubbleOrigin = self.bubbleButton.frame.origin;
    }
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:nil];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragStart = self.container.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        self.container.center = CGPointMake(self.dragStart.x + t.x, self.dragStart.y + t.y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        self.panelOrigin = self.container.frame.origin;
    }
}

#pragma mark - Hit test

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) return nil;
    return hitView;
}

#pragma mark - Visibility

- (void)show { dispatch_async(dispatch_get_main_queue(), ^{ self.hidden = NO; }); }
- (void)hide { dispatch_async(dispatch_get_main_queue(), ^{ self.hidden = YES; }); }

@end
