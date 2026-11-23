#import "ChessLogStore.h"

static const NSUInteger kMaxLogBytes = 2 * 1024 * 1024;

@interface ChessLogStore ()
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, copy) NSString *logFilePath;
@property (nonatomic, copy) NSString *fenFilePath;
@property (nonatomic, strong) NSFileHandle *logHandle;
@property (nonatomic, strong) NSFileHandle *fenHandle;
@property (atomic, assign) BOOL didSetup;
@property (nonatomic, assign) NSUInteger appendCount;
@end

@implementation ChessLogStore

+ (instancetype)shared {
    static ChessLogStore *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [ChessLogStore new]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) _ioQueue = dispatch_queue_create("com.nguyenvinnh.appactivitymonitor.io", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)setupIfNeeded {
    if (self.didSetup) return;
    @synchronized (self) {
        if (self.didSetup) return;
        NSString *baseDir = nil;
        @try {
            NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            if (docs.length > 0) baseDir = docs;
        } @catch (NSException *e) { baseDir = nil; }
        if (baseDir.length == 0) baseDir = NSTemporaryDirectory();
        if (baseDir.length == 0) baseDir = @"/tmp";
        NSString *dir = [baseDir stringByAppendingPathComponent:@"ChessAssistant"];
        @try {
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        } @catch (NSException *e) {
            self.didSetup = YES;
            return;
        }
        NSString *logPath = [dir stringByAppendingPathComponent:@"activity.log"];
        NSString *fenPath = [dir stringByAppendingPathComponent:@"fen_history.log"];
        @try { [self rotateIfNeeded:logPath maxBytes:kMaxLogBytes]; } @catch (NSException *e) { }
        self.logHandle = [self openOrCreateHandle:logPath];
        self.fenHandle = [self openOrCreateHandle:fenPath];
        _logFilePath = [logPath copy];
        _fenFilePath = [fenPath copy];
        self.didSetup = YES;
    }
}

- (void)rotateIfNeeded:(NSString *)path maxBytes:(NSUInteger)maxBytes {
    if (path.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (!attrs || [attrs fileSize] <= maxBytes) return;
    NSString *old = [path stringByAppendingString:@".old"];
    [fm removeItemAtPath:old error:nil];
    [fm moveItemAtPath:path toPath:old error:nil];
}

- (NSFileHandle *)openOrCreateHandle:(NSString *)path {
    if (path.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    @try {
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        [h seekToEndOfFile];
        return h;
    } @catch (NSException *e) { return nil; }
}

- (NSString *)logFilePath { [self setupIfNeeded]; return _logFilePath; }
- (NSString *)fenFilePath { [self setupIfNeeded]; return _fenFilePath; }

- (void)appendLog:(NSString *)line {
    if (line.length == 0) return;
    [self setupIfNeeded];
    if (!self.logHandle) return;
    dispatch_async(self.ioQueue, ^{
        NSString *payload = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];
        NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;
        @try { [self.logHandle writeData:data]; }
        @catch (NSException *e) {
            self.logHandle = [self openOrCreateHandle:self.logFilePath];
            @try { if (self.logHandle) [self.logHandle writeData:data]; } @catch (...) { }
        }
        self.appendCount++;
        if ((self.appendCount % 100) == 0) [self rotateLogIfNeededOnIOQueue];
    });
}

- (void)appendFEN:(NSString *)fen context:(NSString *)context {
    if (fen.length == 0) return;
    [self setupIfNeeded];
    if (!self.fenHandle) return;
    dispatch_async(self.ioQueue, ^{
        NSString *line = [NSString stringWithFormat:@"%@\t%@\n", context ?: @"?", fen];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return;
        @try { [self.fenHandle writeData:data]; }
        @catch (NSException *e) {
            self.fenHandle = [self openOrCreateHandle:self.fenFilePath];
            @try { if (self.fenHandle) [self.fenHandle writeData:data]; } @catch (...) { }
        }
    });
}

- (void)rotateLogIfNeededOnIOQueue {
    NSString *path = _logFilePath;
    if (path.length == 0) return;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs || [attrs fileSize] <= kMaxLogBytes) return;
    @try { [self.logHandle closeFile]; } @catch (NSException *e) { }
    self.logHandle = nil;
    [self rotateIfNeeded:path maxBytes:kMaxLogBytes];
    self.logHandle = [self openOrCreateHandle:path];
}

- (NSArray<NSString *> *)loadLogTail:(NSInteger)maxLines {
    [self setupIfNeeded];
    return [self loadTail:self.logFilePath maxLines:maxLines];
}

- (NSArray<NSString *> *)loadTail:(NSString *)path maxLines:(NSInteger)maxLines {
    if (path.length == 0 || maxLines <= 0) return @[];
    NSFileHandle *h = nil;
    @try { h = [NSFileHandle fileHandleForReadingAtPath:path]; } @catch (NSException *e) { return @[]; }
    if (!h) return @[];
    unsigned long long fileSize = 0;
    @try { fileSize = [h seekToEndOfFile]; } @catch (NSException *e) { @try { [h closeFile]; } @catch (...) { } return @[]; }
    if (fileSize == 0) { @try { [h closeFile]; } @catch (...) { } return @[]; }
    NSMutableArray<NSData *> *chunks = [NSMutableArray array];
    unsigned long long offset = fileSize;
    NSInteger newlineCount = 0;
    while (offset > 0 && newlineCount <= maxLines) {
        NSUInteger chunkSize = (NSUInteger)MIN(8192ULL, offset);
        offset -= chunkSize;
        NSData *d = nil;
        @try { [h seekToFileOffset:offset]; d = [h readDataOfLength:chunkSize]; } @catch (NSException *e) { break; }
        if (d.length == 0) break;
        [chunks insertObject:d atIndex:0];
        const char *bytes = (const char *)d.bytes;
        for (NSUInteger i = 0; i < d.length; i++) if (bytes[i] == '\n') newlineCount++;
    }
    @try { [h closeFile]; } @catch (...) { }
    NSMutableData *all = [NSMutableData data];
    for (NSData *d in chunks) [all appendData:d];
    NSString *content = [[NSString alloc] initWithData:all encoding:NSUTF8StringEncoding];
    if (content.length == 0) return @[];
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    NSMutableArray *result = [NSMutableArray array];
    NSInteger start = MAX(0, (NSInteger)lines.count - maxLines);
    for (NSInteger i = start; i < (NSInteger)lines.count; i++) {
        NSString *ln = lines[i];
        if (ln.length > 0) [result addObject:ln];
    }
    return result;
}

- (void)flush {
    @try { [self setupIfNeeded]; } @catch (NSException *e) { return; }
    if (!self.logHandle && !self.fenHandle) return;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(self.ioQueue, ^{
        @try {
            if (self.logHandle) [self.logHandle synchronizeFile];
            if (self.fenHandle) [self.fenHandle synchronizeFile];
        } @catch (NSException *e) { }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)));
}

@end
