#import "CrashHandler.h"
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <execinfo.h>
#import <string.h>
#import <stdio.h>

static char gCrashPath[512] = "/tmp/ChessAssistant/crash.log";
static char gSegvPath[512] = "/tmp/ChessAssistant_segv.log";

static void WriteAll(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t w = write(fd, buf, len);
        if (w <= 0) break;
        buf += w;
        len -= (size_t)w;
    }
}

@implementation CrashHandler

+ (void)safeWriteCrashLog:(NSString *)msg {
    if (msg.length == 0) return;
    NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        WriteAll(fd, (const char *)data.bytes, data.length);
        fsync(fd);
        close(fd);
    }
}

static void handleUncaughtException(NSException *exception) {
    @try {
        NSString *msg = [NSString stringWithFormat:@"[CRASH] %@: %@\n%@\n",
            exception.name ?: @"?", exception.reason ?: @"?",
            [[exception callStackSymbols] componentsJoinedByString:@"\n"]];
        [CrashHandler safeWriteCrashLog:msg];
    } @catch (NSException *e) { }
    NSLog(@"[ChessAssistant] CRASH: %@", exception.reason);
}

static void sigHandler(int sig, siginfo_t *info, void *ucontext) {
    (void)ucontext;
    char header[256];
    int n = snprintf(header, sizeof(header), "\n=== SIGNAL %d at %p (ChessAssistant) ===\n", sig, info ? info->si_addr : NULL);
    if (n > 0) {
        int fd = open(gSegvPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            WriteAll(fd, header, (size_t)n);
            void *frames[64];
            int count = backtrace(frames, 64);
            if (count > 0) backtrace_symbols_fd(frames, count, fd);
            fsync(fd);
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

+ (void)installCrashHandlers {
    NSString *dir = nil;
    @try {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (docs.length > 0) dir = [docs stringByAppendingPathComponent:@"ChessAssistant"];
    } @catch (NSException *e) { dir = nil; }
    if (dir.length == 0) dir = @"/tmp/ChessAssistant";
    @try { [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]; } @catch (NSException *e) { }
    strlcpy(gCrashPath, [[dir stringByAppendingPathComponent:@"crash.log"] fileSystemRepresentation], sizeof(gCrashPath));
    NSSetUncaughtExceptionHandler(&handleUncaughtException);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sigHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
}

@end
