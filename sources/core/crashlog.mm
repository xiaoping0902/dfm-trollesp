//
//  crashlog.mm
//  DFM TrollESP
//

#import "crashlog.h"

#import <Foundation/Foundation.h>

#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static char gCrashPath[512] = {0};
static char gTag[32] = {0};
static int gLogFd = -1;
static volatile int gInCrash = 0;

static void ESPPickLogPath(void) {
    const char *candidates[] = {
        "/var/mobile/Library/Caches/dfm_crash.log",
        "/tmp/dfm_crash.log",
    };
    for (const char *p : candidates) {
        int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            gLogFd = fd;
            strncpy(gCrashPath, p, sizeof(gCrashPath) - 1);
            return;
        }
    }
    gLogFd = -1;
}

static void ESPWriteRaw(const char *text, size_t len) {
    if (gLogFd < 0 || !text || !len) return;
    ssize_t ignored = write(gLogFd, text, len);
    (void)ignored;
}

static void ESPWriteString(const char *text) {
    if (!text) return;
    ESPWriteRaw(text, strlen(text));
}

static void ESPWriteTimePrefix(const char *kind) {
    char buf[64];
    time_t now = time(nullptr);
    struct tm tmv;
    localtime_r(&now, &tmv);
    int n = snprintf(buf, sizeof(buf), "%02d:%02d:%02d [%s/%s] ", tmv.tm_hour, tmv.tm_min,
                     tmv.tm_sec, gTag[0] ? gTag : "?", kind ? kind : "-");
    if (n > 0) ESPWriteRaw(buf, (size_t)n);
}

void ESPLogStep(const char *fmt, ...) {
    if (gLogFd < 0) ESPPickLogPath();
    if (gLogFd < 0) return;

    ESPWriteTimePrefix("step");
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
    va_end(ap);
    if (n < 0) n = 0;
    if (n > (int)sizeof(buf) - 2) n = (int)sizeof(buf) - 2;
    buf[n++] = '\n';
    ESPWriteRaw(buf, (size_t)n);
}

static void ESPCrashHandler(int sig) {
    if (gInCrash) {
        _exit(sig);
    }
    gInCrash = 1;

    if (gLogFd < 0) ESPPickLogPath();

    char buf[128];
    ESPWriteString("\n=== CRASH ===\n");
    ESPWriteTimePrefix("signal");
    int n = snprintf(buf, sizeof(buf), "signal %d (%s)\n", sig, strsignal(sig));
    if (n > 0) ESPWriteRaw(buf, (size_t)n);

    void *frames[64];
    int count = backtrace(frames, 64);
    if (gLogFd >= 0) {
        backtrace_symbols_fd(frames, count, gLogFd);
    }

    ESPWriteString("=== END ===\n");
    if (gLogFd >= 0) fsync(gLogFd);

    signal(sig, SIG_DFL);
    raise(sig);
    _exit(sig);
}

@interface ESPCrashExceptionHandler : NSObject
+ (void)handle:(NSException *)exception;
@end

@implementation ESPCrashExceptionHandler
+ (void)handle:(NSException *)exception {
    if (gLogFd < 0) ESPPickLogPath();
    ESPWriteString("\n=== EXCEPTION ===\n");
    ESPWriteTimePrefix("exception");
    ESPWriteString([[exception name] UTF8String]);
    ESPWriteString(": ");
    ESPWriteString([[exception reason] UTF8String]);
    ESPWriteString("\n");
    NSArray *symbols = [exception callStackSymbols];
    for (NSString *line in symbols) {
        ESPWriteString([line UTF8String]);
        ESPWriteString("\n");
    }
    ESPWriteString("=== END ===\n");
    if (gLogFd >= 0) fsync(gLogFd);
}
@end

static void ESPUncaughtHandlerBridge(NSException *exception) {
    [ESPCrashExceptionHandler handle:exception];
}

void ESPInstallCrashLogger(const char *tag) {
    if (tag) {
        strncpy(gTag, tag, sizeof(gTag) - 1);
    }
    ESPPickLogPath();

    NSSetUncaughtExceptionHandler(&ESPUncaughtHandlerBridge);

    static const int kSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE};
    for (int s : kSignals) {
        signal(s, ESPCrashHandler);
    }

    ESPLogStep("crash logger installed (pid=%d)", getpid());
}

const char *ESPCrashLogPath(void) {
    if (gCrashPath[0] == 0) ESPPickLogPath();
    return gCrashPath;
}

char *ESPCrashLogRead(void) {
    const char *path = ESPCrashLogPath();
    if (!path || !*path) return nullptr;

    FILE *fp = fopen(path, "r");
    if (!fp) return nullptr;
    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (size <= 0 || size > 512 * 1024) {
        fclose(fp);
        return nullptr;
    }
    char *buf = static_cast<char *>(malloc(static_cast<size_t>(size) + 1));
    if (!buf) {
        fclose(fp);
        return nullptr;
    }
    size_t got = fread(buf, 1, static_cast<size_t>(size), fp);
    buf[got] = 0;
    fclose(fp);
    return buf;
}
