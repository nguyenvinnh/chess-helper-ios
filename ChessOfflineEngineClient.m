#import "ChessOfflineEngineClient.h"
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <os/lock.h>
#import <time.h>

extern char **environ;

static const char *kIOQueueSpecificKey = "com.nguyenvinnh.stockfish.io";
static const NSTimeInterval kFailureCooldown = 30.0;
static const NSTimeInterval kHandshakeTimeout = 5.0;
static os_unfair_lock gWriteLock = OS_UNFAIR_LOCK_INIT;

static inline NSTimeInterval TimeoutForDepth(NSInteger d) {
    return MIN(25.0, 8.0 + (double)d * 0.4);
}

@interface ChessOfflineEngineClient ()
@property (atomic, assign, readwrite) OfflineEngineState state;
@property (nonatomic, copy, readwrite) NSString *detectedClassName;
@property (nonatomic, copy, readwrite) NSString *detectedMethodName;
@property (nonatomic, assign) pid_t childPid;
@property (nonatomic, assign) int stdinFd;
@property (nonatomic, assign) int stdoutFd;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, strong) NSMutableData *readBufferData;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *requestQueue;
@property (nonatomic, strong) NSDictionary *currentRequest;
@property (nonatomic, strong) dispatch_source_t requestTimer;
@property (nonatomic, strong) NSMutableDictionary *idInfo;
@property (nonatomic, strong) dispatch_semaphore_t handshakeSem;
@property (nonatomic, assign) BOOL sawUciok;
@property (nonatomic, assign) BOOL sawReadyok;
@property (nonatomic, strong) NSDate *lastFailureDate;
@property (nonatomic, assign) BOOL isDetecting;
@property (nonatomic, strong) NSMutableArray<void (^)(BOOL)> *detectWaiters;
@property (nonatomic, copy) NSString *currentBinaryPath;
@end

@implementation ChessOfflineEngineClient

+ (instancetype)shared {
    static ChessOfflineEngineClient *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ChessOfflineEngineClient new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = OfflineEngineStateNotDetected;
        _childPid = -1;
        _stdinFd = -1;
        _stdoutFd = -1;
        _readBufferData = [NSMutableData new];
        _requestQueue = [NSMutableArray new];
        _idInfo = [NSMutableDictionary new];
        _ioQueue = dispatch_queue_create("com.nguyenvinnh.stockfish.io", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_ioQueue, kIOQueueSpecificKey, (void *)kIOQueueSpecificKey, NULL);
    }
    return self;
}

- (void)dealloc { [self reset]; }

- (BOOL)isOnIOQueue { return dispatch_get_specific(kIOQueueSpecificKey) != NULL; }

- (void)runOnIOQueueSync:(void (^)(void))block {
    if (!block) return;
    if ([self isOnIOQueue]) block();
    else dispatch_sync(self.ioQueue, block);
}

- (void)processQueueAsync { dispatch_async(self.ioQueue, ^{ [self processQueue]; }); }

- (BOOL)isEngineAlive {
    if (self.childPid <= 0) return NO;
    static uint64_t lastCheckNs = 0;
    static BOOL lastResult = NO;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - lastCheckNs < 200ULL * 1000000ULL) return lastResult;
    lastCheckNs = now;
    int status = 0;
    pid_t r = waitpid(self.childPid, &status, WNOHANG);
    if (r == self.childPid) { lastResult = NO; return NO; }
    if (r == -1 && errno == ECHILD) { lastResult = NO; return NO; }
    lastResult = (kill(self.childPid, 0) == 0);
    return lastResult;
}

- (BOOL)isInFailureCooldown {
    if (!self.lastFailureDate) return NO;
    return [[NSDate date] timeIntervalSinceDate:self.lastFailureDate] < kFailureCooldown;
}

- (BOOL)isAvailable { return (self.state == OfflineEngineStateReady && [self isEngineAlive]); }

static NSData *LoadStockfishFromEmbeddedSection(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *hdr = _dyld_get_image_header(i);
        if (!hdr) continue;
        unsigned long size = 0;
        const uint8_t *data = getsectiondata((const struct mach_header_64 *)hdr, "__DATA", "__stockfish", &size);
        if (!data || size < 16) continue;
        uint32_t magic = (data[3]<<24)|(data[2]<<16)|(data[1]<<8)|data[0];
        if (magic == 0xFEEDFACF) {
            return [NSData dataWithBytes:data length:size];
        }
    }
    return nil;
}

static char **FilteredEnviron(void) {
    size_t count = 0;
    for (char **e = environ; e && *e; e++) count++;
    char **out = calloc(count + 1, sizeof(char *));
    if (!out) return environ;
    size_t j = 0;
    for (size_t i = 0; i < count; i++) {
        char *kv = environ[i];
        if (!kv) continue;
        if (strncmp(kv, "DYLD_", 5) == 0) continue;
        if (strncmp(kv, "LD_", 3) == 0) continue;
        if (strncmp(kv, "_MSSafeMode=", 12) == 0) continue;
        out[j++] = kv;
    }
    out[j] = NULL;
    return out;
}

- (NSString *)extractBundledBinary {
    NSData *binData = LoadStockfishFromEmbeddedSection();
    if (!binData || binData.length == 0) {
        NSLog(@"[OfflineEngine] Khong tim thay binary trong section __DATA,__stockfish");
        return nil;
    }
    NSString *tmpDir = NSTemporaryDirectory();
    if (tmpDir.length == 0) tmpDir = @"/tmp";
    NSString *destPath = [tmpDir stringByAppendingPathComponent:[NSString stringWithFormat:@"stockfish_embedded_%d", (int)getpid()]];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:destPath error:nil];
    if (attrs && [attrs fileSize] == binData.length) {
        if (access(destPath.UTF8String, X_OK) == 0) return destPath;
        chmod(destPath.UTF8String, 0700);
        if (access(destPath.UTF8String, X_OK) == 0) return destPath;
    }
    NSString *tmpPath = [destPath stringByAppendingString:@".tmp"];
    [fm removeItemAtPath:tmpPath error:nil];
    if (![binData writeToFile:tmpPath atomically:YES]) return nil;
    chmod(tmpPath.UTF8String, 0700);
    [fm removeItemAtPath:destPath error:nil];
    if (![fm moveItemAtPath:tmpPath toPath:destPath error:nil]) return nil;
    if (access(destPath.UTF8String, X_OK) != 0) return nil;
    return destPath;
}

- (BOOL)spawnStockfishAtPath:(NSString *)binPath {
    int stdinPipe[2] = {-1, -1};
    int stdoutPipe[2] = {-1, -1};
    if (pipe(stdinPipe) < 0) return NO;
    if (pipe(stdoutPipe) < 0) { close(stdinPipe[0]); close(stdinPipe[1]); return NO; }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdinPipe[1]);
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0600);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t def;
    sigemptyset(&def);
    sigaddset(&def, SIGPIPE);
#if defined(__APPLE__)
    posix_spawnattr_setsigdefault(&attr, &def);
#else
    posix_spawnattr_setsigdef(&attr, &def);
#endif
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF);
    char *argv[] = { (char *)binPath.UTF8String, NULL };
    char **filteredEnv = FilteredEnviron();
    pid_t pid = 0;
    int ret = posix_spawn(&pid, binPath.UTF8String, &actions, &attr, argv, filteredEnv);
    if (filteredEnv != environ) free(filteredEnv);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(stdinPipe[0]);
    close(stdoutPipe[1]);
    if (ret != 0 || pid <= 0) {
        NSLog(@"[OfflineEngine] posix_spawn that bai: %d (%s)", ret, strerror(ret));
        close(stdinPipe[1]);
        close(stdoutPipe[0]);
        return NO;
    }
    self.childPid = pid;
    self.stdinFd = stdinPipe[1];
    self.stdoutFd = stdoutPipe[0];
    int flags = fcntl(self.stdoutFd, F_GETFL, 0);
    fcntl(self.stdoutFd, F_SETFL, flags | O_NONBLOCK);
    return YES;
}

- (void)killChildOnIOQueue {
    if (self.childPid > 0) {
        kill(self.childPid, SIGKILL);
        int status = 0;
        for (int i = 0; i < 20; i++) {
            pid_t r = waitpid(self.childPid, &status, WNOHANG);
            if (r == self.childPid || (r == -1 && errno == ECHILD)) break;
            usleep(5000);
        }
        self.childPid = -1;
    }
}

- (void)startReadingSync { [self runOnIOQueueSync:^{ [self startReadingOnIOQueue]; }]; }

- (void)startReadingOnIOQueue {
    if (self.readSource) return;
    if (self.stdoutFd < 0) return;
    __weak typeof(self) weakSelf = self;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)self.stdoutFd, 0, self.ioQueue);
    if (!src) return;
    self.readSource = src;
    dispatch_source_set_event_handler(src, ^{ [weakSelf handleReadAvailable]; });
    dispatch_source_set_cancel_handler(src, ^{ });
    dispatch_resume(src);
}

- (void)stopReadingOnIOQueue {
    if (self.readSource) { dispatch_source_cancel(self.readSource); self.readSource = nil; }
}

- (void)closeFdsOnIOQueue {
    if (self.stdinFd >= 0) { close(self.stdinFd); self.stdinFd = -1; }
    if (self.stdoutFd >= 0) { close(self.stdoutFd); self.stdoutFd = -1; }
}

- (void)handleReadAvailable {
    char buf[4096];
    while (YES) {
        ssize_t n = read(self.stdoutFd, buf, sizeof(buf));
        if (n > 0) {
            [self processRawData:[NSData dataWithBytes:buf length:(NSUInteger)n]];
            continue;
        }
        if (n == 0) { [self handleEngineExited]; return; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        [self handleEngineExited];
        return;
    }
}

- (void)processRawData:(NSData *)incoming {
    if (incoming.length == 0) return;
    [self.readBufferData appendData:incoming];
    while (YES) {
        const char *bytes = (const char *)self.readBufferData.bytes;
        NSUInteger len = self.readBufferData.length;
        if (len == 0) break;
        const char *nl = memchr(bytes, '\n', len);
        if (!nl) break;
        NSUInteger lineLen = (NSUInteger)(nl - bytes);
        NSString *line = [[NSString alloc] initWithBytes:bytes length:lineLen encoding:NSUTF8StringEncoding];
        [self.readBufferData replaceBytesInRange:NSMakeRange(0, lineLen + 1) withBytes:NULL length:0];
        if (line) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) [self handleUciLine:trimmed];
        }
    }
    if (self.readBufferData.length > 65536) [self.readBufferData setLength:0];
}

- (void)handleUciLine:(NSString *)line {
    if ([line isEqualToString:@"uciok"]) {
        @synchronized (self) { self.sawUciok = YES; }
        if (self.handshakeSem) dispatch_semaphore_signal(self.handshakeSem);
        return;
    }
    if ([line isEqualToString:@"readyok"]) {
        @synchronized (self) { self.sawReadyok = YES; }
        if (self.handshakeSem) dispatch_semaphore_signal(self.handshakeSem);
        return;
    }
    if ([line hasPrefix:@"id name "]) { self.idInfo[@"name"] = [line substringFromIndex:8]; return; }
    if ([line hasPrefix:@"id author "]) { self.idInfo[@"author"] = [line substringFromIndex:10]; return; }
    if ([line hasPrefix:@"bestmove "]) {
        if (!self.currentRequest) return;
        NSString *rest = [line substringFromIndex:9];
        NSArray *parts = [[rest componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        NSString *uci = parts.count > 0 ? parts[0] : @"";
        if ([uci isEqualToString:@"(none)"]) {
            NSError *e = [NSError errorWithDomain:@"ChessAPI" code:-42 userInfo:@{NSLocalizedDescriptionKey: @"Offline: chieu het / hoa - khong con nuoc di"}];
            [self failCurrentWithError:e fatal:NO];
            return;
        }
        [self fulfillCurrentWithUCI:uci raw:line];
    }
}

- (void)handleEngineExited {
    if (self.childPid <= 0 && !self.readSource) return;
    NSLog(@"[OfflineEngine] engine da exit (pid=%d)", (int)self.childPid);
    if (self.handshakeSem) dispatch_semaphore_signal(self.handshakeSem);
    NSError *e = [NSError errorWithDomain:@"ChessAPI" code:-44 userInfo:@{NSLocalizedDescriptionKey: @"Offline engine da thoat dot ngot"}];
    [self failAllRequestsWithError:e];
    [self stopReadingOnIOQueue];
    [self closeFdsOnIOQueue];
    self.childPid = -1;
    @synchronized (self) {
        self.state = OfflineEngineStateUnavailable;
        self.lastFailureDate = [NSDate date];
    }
}

- (void)sendCommand:(NSString *)cmd {
    if (self.stdinFd < 0) return;
    os_unfair_lock_lock(&gWriteLock);
    NSString *full = [cmd stringByAppendingString:@"\n"];
    NSData *data = [full dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t w = write(self.stdinFd, bytes, remaining);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) { usleep(1000); continue; }
            dispatch_async(self.ioQueue, ^{ [self handleEngineExited]; });
            break;
        }
        bytes += w;
        remaining -= (size_t)w;
    }
    os_unfair_lock_unlock(&gWriteLock);
}

- (void)ensureEngineReadyWithCompletion:(void (^)(BOOL))completion {
    if (!completion) return;
    BOOL alreadyReady = NO;
    BOOL inCooldown = NO;
    BOOL shouldStart = NO;
    @synchronized (self) {
        if (self.state == OfflineEngineStateReady && self.childPid > 0 && [self isEngineAlive]) alreadyReady = YES;
        else if ([self isInFailureCooldown]) inCooldown = YES;
        else {
            if (!self.detectWaiters) self.detectWaiters = [NSMutableArray array];
            [self.detectWaiters addObject:[completion copy]];
            if (!self.isDetecting) { self.isDetecting = YES; shouldStart = YES; }
        }
    }
    if (alreadyReady) { completion(YES); return; }
    if (inCooldown) { completion(NO); return; }
    if (!shouldStart) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = [self runDetectInBackground];
        NSArray *waiters = nil;
        @synchronized (self) {
            self.isDetecting = NO;
            waiters = [self.detectWaiters copy];
            self.detectWaiters = nil;
            if (!ok) self.lastFailureDate = [NSDate date];
        }
        if (!ok) {
            NSError *e = [NSError errorWithDomain:@"ChessAPI" code:-40 userInfo:@{NSLocalizedDescriptionKey: @"Offline engine chua san sang"}];
            dispatch_async(self.ioQueue, ^{ [self failAllRequestsWithError:e]; });
        }
        for (void (^cb)(BOOL) in waiters) cb(ok);
        if (ok) [self processQueueAsync];
    });
}

- (BOOL)runDetectInBackground {
    NSString *path = [self extractBundledBinary];
    if (!path) {
        @synchronized (self) { self.state = OfflineEngineStateUnavailable; }
        return NO;
    }
    [self runOnIOQueueSync:^{
        [self stopReadingOnIOQueue];
        [self closeFdsOnIOQueue];
        [self killChildOnIOQueue];
    }];
    if (![self spawnStockfishAtPath:path]) {
        @synchronized (self) { self.state = OfflineEngineStateUnavailable; }
        return NO;
    }
    self.currentBinaryPath = path;
    [self startReadingSync];
    @synchronized (self) { self.sawUciok = NO; self.handshakeSem = dispatch_semaphore_create(0); }
    [self sendCommand:@"uci"];
    long w1 = dispatch_semaphore_wait(self.handshakeSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHandshakeTimeout * NSEC_PER_SEC)));
    BOOL ok1 = (w1 == 0);
    @synchronized (self) { ok1 = ok1 && self.sawUciok; }
    if (!ok1) { [self cleanupAfterFailedDetect]; return NO; }

    @synchronized (self) { self.sawReadyok = NO; self.handshakeSem = dispatch_semaphore_create(0); }
    [self sendCommand:@"isready"];
    long w2 = dispatch_semaphore_wait(self.handshakeSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHandshakeTimeout * NSEC_PER_SEC)));
    BOOL ok2 = (w2 == 0);
    @synchronized (self) { ok2 = ok2 && self.sawReadyok; }
    if (!ok2) { [self cleanupAfterFailedDetect]; return NO; }

    @synchronized (self) {
        self.state = OfflineEngineStateReady;
        self.detectedClassName = [NSString stringWithFormat:@"%@ (bundled)", self.idInfo[@"name"] ?: @"Stockfish"];
        self.detectedMethodName = @"UCI: position fen -> go depth N -> bestmove";
    }
    return YES;
}

- (void)cleanupAfterFailedDetect {
    [self runOnIOQueueSync:^{
        [self stopReadingOnIOQueue];
        [self closeFdsOnIOQueue];
        [self killChildOnIOQueue];
    }];
    @synchronized (self) { self.state = OfflineEngineStateUnavailable; }
}

- (BOOL)detectEngine {
    if ([self isAvailable]) return YES;
    if ([self isInFailureCooldown]) return NO;
    if ([NSThread isMainThread] || [self isOnIOQueue]) {
        [self ensureEngineReadyWithCompletion:^(BOOL ok){}];
        return NO;
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL result = NO;
    [self ensureEngineReadyWithCompletion:^(BOOL ok) { result = ok; dispatch_semaphore_signal(sem); }];
    long w = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC));
    if (w != 0) return NO;
    return result;
}

- (NSURLSessionDataTask *)requestBestMoveForFEN:(NSString *)fen depth:(NSInteger)depth completion:(void (^)(ChessAPIResult *, NSError *))completion {
    if (fen.length == 0) {
        if (completion) {
            NSError *e = [NSError errorWithDomain:@"ChessAPI" code:-41 userInfo:@{NSLocalizedDescriptionKey: @"Offline: FEN rong"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, e); });
        }
        return nil;
    }
    NSInteger d = MIN(MAX(depth, 1), 30);
    NSDictionary *req = @{@"fen": [fen copy], @"depth": @(d), @"completion": completion ? [completion copy] : [^(ChessAPIResult *r, NSError *e){} copy]};
    dispatch_async(self.ioQueue, ^{ [self.requestQueue addObject:req]; [self processQueue]; });
    return nil;
}

- (void)processQueue {
    if (self.currentRequest) return;
    if (self.requestQueue.count == 0) return;
    if (self.state != OfflineEngineStateReady || self.childPid <= 0 || ![self isEngineAlive]) {
        [self ensureEngineReadyWithCompletion:^(BOOL ok){}];
        return;
    }
    NSDictionary *req = self.requestQueue[0];
    [self.requestQueue removeObjectAtIndex:0];
    self.currentRequest = req;
    [self startRequestTimerForDepth:[req[@"depth"] integerValue]];
    [self sendCommand:[NSString stringWithFormat:@"position fen %@", req[@"fen"]]];
    [self sendCommand:[NSString stringWithFormat:@"go depth %ld", (long)[req[@"depth"] integerValue]]];
}

- (void)startRequestTimerForDepth:(NSInteger)depth {
    [self cancelTimer];
    NSTimeInterval timeout = TimeoutForDepth(depth);
    __weak typeof(self) weakSelf = self;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.ioQueue);
    self.requestTimer = t;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{ [weakSelf handleRequestTimeout]; });
    dispatch_resume(t);
}

- (void)cancelTimer {
    if (self.requestTimer) { dispatch_source_cancel(self.requestTimer); self.requestTimer = nil; }
}

- (void)handleRequestTimeout {
    if (!self.currentRequest) return;
    NSInteger d = [self.currentRequest[@"depth"] integerValue];
    NSLog(@"[OfflineEngine] timeout sau %.0fs o depth %ld", TimeoutForDepth(d), (long)d);
    NSError *e = [NSError errorWithDomain:@"ChessAPI" code:-43 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Offline timeout sau %.0fs (depth %ld)", TimeoutForDepth(d), (long)d]}];
    [self failAllRequestsWithError:e];
    [self stopReadingOnIOQueue];
    [self closeFdsOnIOQueue];
    [self killChildOnIOQueue];
    @synchronized (self) { self.state = OfflineEngineStateUnavailable; self.lastFailureDate = [NSDate date]; }
}

- (void)fulfillCurrentWithUCI:(NSString *)rawUci raw:(NSString *)rawResponse {
    NSDictionary *req = self.currentRequest;
    if (!req) return;
    [self cancelTimer];
    self.currentRequest = nil;
    void (^cb)(ChessAPIResult *, NSError *) = req[@"completion"];
    NSInteger depth = [req[@"depth"] integerValue] ?: 12;
    NSString *cleanUCI = [ChessAPIClient extractUCIMove:rawUci] ?: rawUci;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cleanUCI.length >= 4) {
            ChessAPIResult *res = [ChessAPIResult new];
            res.bestMoveUCI = cleanUCI;
            res.depth = depth;
            res.rawResponse = rawResponse;
            cb(res, nil);
        } else {
            NSError *err = [NSError errorWithDomain:@"ChessAPI" code:-42 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Nuoc di offline khong hop le: %@", rawUci ?: @"nil"]}];
            cb(nil, err);
        }
    });
    [self processQueue];
}

- (void)failCurrentWithError:(NSError *)err fatal:(BOOL)fatal {
    NSDictionary *req = self.currentRequest;
    if (!req) return;
    [self cancelTimer];
    self.currentRequest = nil;
    void (^cb)(ChessAPIResult *, NSError *) = req[@"completion"];
    dispatch_async(dispatch_get_main_queue(), ^{ cb(nil, err); });
    if (fatal) [self failAllRequestsWithError:err];
    else [self processQueue];
}

- (void)failAllRequestsWithError:(NSError *)err {
    NSMutableArray *all = [NSMutableArray array];
    if (self.currentRequest) { [all addObject:self.currentRequest]; self.currentRequest = nil; }
    [all addObjectsFromArray:self.requestQueue];
    [self.requestQueue removeAllObjects];
    [self cancelTimer];
    for (NSDictionary *req in all) {
        void (^cb)(ChessAPIResult *, NSError *) = req[@"completion"];
        if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(nil, err); });
    }
}

- (void)cancelAllRequests {
    dispatch_async(self.ioQueue, ^{
        if (self.currentRequest) [self sendCommand:@"stop"];
        NSError *e = [NSError errorWithDomain:@"ChessAPI" code:-49 userInfo:@{NSLocalizedDescriptionKey: @"Offline request da bi huy (doi FEN / Clear)"}];
        [self failAllRequestsWithError:e];
    });
}

- (void)reset {
    @synchronized (self) {
        self.state = OfflineEngineStateNotDetected;
        self.lastFailureDate = nil;
        self.detectedClassName = nil;
        self.detectedMethodName = nil;
    }
    dispatch_async(self.ioQueue, ^{
        NSError *e = [NSError errorWithDomain:@"ChessAPI" code:-49 userInfo:@{NSLocalizedDescriptionKey: @"Offline engine da reset"}];
        [self failAllRequestsWithError:e];
        [self stopReadingOnIOQueue];
        [self closeFdsOnIOQueue];
        [self killChildOnIOQueue];
        [self.readBufferData setLength:0];
        self.currentBinaryPath = nil;
    });
}

@end
