#import "YBLog.h"
#import <UIKit/UIKit.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

static NSMutableArray<NSString *> *gRing = nil;
static NSString *gPath = nil;
static dispatch_queue_t gQ;
static NSDateFormatter *gFmt;
static char gPathC[512];              // 给信号处理用的纯 C 路径
static char gTrace[160] = "boot";     // 当前进行到哪一步（信号处理时一起写出去）

void YBLogBootstrap(void) {
    if (gQ) return;
    gQ = dispatch_queue_create("yb.log", DISPATCH_QUEUE_SERIAL);
    gRing = [NSMutableArray array];
    gFmt = [[NSDateFormatter alloc] init];
    gFmt.dateFormat = @"HH:mm:ss.SSS";

    // 注入进程的沙盒 Documents 一般可写；失败再退到 tmp
    NSArray *cands = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/YuanbaoCheckin.log"],
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"YuanbaoCheckin.log"],
    ];
    for (NSString *p in cands) {
        NSString *dir = [p stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        if ([[NSFileManager defaultManager] isWritableFileAtPath:dir]) { gPath = p; break; }
    }
    YBLog(@"日志文件: %@", gPath ?: @"(不可写)");
    if (gPath) {
        // 存一份 C 字符串路径：信号处理里不能用 ObjC/Foundation
        const char *c = [gPath fileSystemRepresentation];
        if (c) { strncpy(gPathC, c, sizeof(gPathC) - 1); gPathC[sizeof(gPathC) - 1] = '\0'; }
    }
}

NSString *YBLogFilePath(void) { return gPath; }

static void YBLogWrite(NSString *line) {
    NSLog(@"[YB] %@", line);
    if (!gRing) YBLogBootstrap();
    @synchronized (gRing) {
        [gRing addObject:line];
        while (gRing.count > 800) [gRing removeObjectAtIndex:0];
    }
    if (gPath) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gPath];
        if (!fh) { [line writeToFile:gPath atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
        else {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) { (void)e; }
        }
    }
}

// 未捕获异常：直接把原因 + 调用栈同步写进日志，方便事后定位（跑完就闪退也能留痕）
static void YBCrashHandlerRaw(NSException *e) {
    NSString *msg = [NSString stringWithFormat:@"[崩溃] %@ | %@\n%@",
                     e.name ?: @"?",
                     e.reason ?: @"?",
                     [e.callStackSymbols componentsJoinedByString:@"\n"]];
    YBLogWrite(msg);
}

void YBLogFlush(void) {
    if (gQ) dispatch_sync(gQ, ^{});
}

void YBLogEnableCrashHandler(void) {
    NSSetUncaughtExceptionHandler(&YBCrashHandlerRaw);
}

// ---- 同步日志：写完立刻落盘，硬崩溃也不丢最后几行 ----
void YBLogSync(NSString *fmt, ...) {
    if (!gQ) YBLogBootstrap();
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    YBLogWrite([NSString stringWithFormat:@"[%@] %@", [gFmt stringFromDate:[NSDate date]], msg]);
}

// ---- 进度标记：崩溃时把"最后进行到哪一步"一并写进日志 ----
// 同时存进 NSUserDefaults：万一崩在写日志之前，下一次启动面板标题也能看到上次进行到哪
void YBSetTrace(const char *step) {
    if (!step) return;
    strncpy(gTrace, step, sizeof(gTrace) - 1);
    gTrace[sizeof(gTrace) - 1] = '\0';
    @try {
        NSString *s = [NSString stringWithUTF8String:step];
        if (s.length) [[NSUserDefaults standardUserDefaults] setObject:s forKey:@"yb.lastStep"];
    } @catch (NSException *e) { }
}

NSString *YBLastTrace(void) {
    NSString *s = nil;
    @try { s = [[NSUserDefaults standardUserDefaults] stringForKey:@"yb.lastStep"]; } @catch (NSException *e) { }
    return s.length ? s : @"(无)";
}

// 启动时先把"上一次进程最后进行到哪"存下来，本进程会不停覆盖 yb.lastStep
void YBMarkBootTrace(void) {
    @try {
        NSString *prev = [[NSUserDefaults standardUserDefaults] stringForKey:@"yb.lastStep"];
        if (prev.length) [[NSUserDefaults standardUserDefaults] setObject:prev forKey:@"yb.prevStep"];
    } @catch (NSException *e) { }
}

NSString *YBPrevTrace(void) {
    NSString *s = nil;
    @try { s = [[NSUserDefaults standardUserDefaults] stringForKey:@"yb.prevStep"]; } @catch (NSException *e) { }
    return s.length ? s : @"(无)";
}

// 注意：NSArray 的 description 会把中文写成 \U798f 这种转义，日志里就完全没法读。
// 所以凡是"锚点数组"一律先用这个拼成字符串再打。
NSString *YBJoinKeys(NSArray<NSString *> *keys) {
    return keys.count ? [keys componentsJoinedByString:@"/"] : @"(空)";
}

// 信号处理里只能用 open/write/close 这类 async-signal-safe 调用
static void YBSigHandler(int sig) {
    const char *name = "?";
    switch (sig) {
        case SIGSEGV: name = "SIGSEGV(野指针/坏内存)"; break;
        case SIGABRT: name = "SIGABRT(断言/abort)"; break;
        case SIGBUS:  name = "SIGBUS(非法访问)"; break;
        case SIGILL:  name = "SIGILL(非法指令)"; break;
        case SIGFPE:  name = "SIGFPE(算术异常)"; break;
        case SIGTRAP: name = "SIGTRAP(断点/系统陷阱)"; break;
    }
    char buf[400];
    int n = snprintf(buf, sizeof(buf), "\n[信号崩溃] signal=%d %s last_step=%s\n", sig, name, gTrace);
    if (gPathC[0] && n > 0) {
        int fd = open(gPathC, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) { write(fd, buf, (size_t)n); close(fd); }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

void YBLogInstallSignalHandlers(void) {
    signal(SIGSEGV, YBSigHandler);
    signal(SIGBUS,  YBSigHandler);
    signal(SIGABRT, YBSigHandler);
    signal(SIGILL,  YBSigHandler);
    signal(SIGFPE,  YBSigHandler);
    signal(SIGTRAP, YBSigHandler);
}

void YBLog(NSString *fmt, ...) {
    if (!gQ) YBLogBootstrap();
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [gFmt stringFromDate:[NSDate date]], msg];
    dispatch_async(gQ, ^{ YBLogWrite(line); });
}

NSArray<NSString *> *YBLogTail(NSUInteger n) {
    @synchronized (gRing) {
        NSUInteger c = gRing.count;
        NSUInteger from = c > n ? c - n : 0;
        return [gRing subarrayWithRange:NSMakeRange(from, c - from)];
    }
}

void YBLogClear(void) {
    @synchronized (gRing) { [gRing removeAllObjects]; }
    if (gPath) [[NSFileManager defaultManager] removeItemAtPath:gPath error:NULL];
}

// ---- 上一次运行是否没跑完（崩溃 / 被系统杀）----
static NSArray<NSString *> *YBLogFileLines(void) {
    NSString *p = YBLogFilePath();
    if (!p) return @[];
    NSString *all = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
    if (!all.length) return @[];
    return [all componentsSeparatedByString:@"\n"];
}

// 从最后一条 "[启动] YuanbaoCheckin 已注入" 开始，算作"上一次进程"
static NSArray<NSString *> *YBLastRunSlice(void) {
    NSArray<NSString *> *lines = YBLogFileLines();
    if (!lines.count) return @[];
    NSInteger start = -1;
    for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) {
        if ([lines[i] containsString:@"[启动] YuanbaoCheckin 已注入"]) { start = i; break; }
    }
    if (start < 0) return lines;
    return [lines subarrayWithRange:NSMakeRange((NSUInteger)start, lines.count - (NSUInteger)start)];
}

BOOL YBLastRunUnfinished(void) {
    NSArray<NSString *> *slice = YBLastRunSlice();
    if (!slice.count) return NO;
    BOOL began = NO, ended = NO, crash = NO;
    for (NSString *l in slice) {
        if ([l containsString:@"[信号崩溃]"]) crash = YES;
        if ([l containsString:@"[崩溃] "])     crash = YES;
        // 自检 A/B/C/D 和完整任务都算"开始了"
        if ([l containsString:@"===== "] && [l containsString:@"开始"]) began = YES;
        if ([l containsString:@"===== "] && [l containsString:@"结束"]) ended = YES;
    }
    if (crash) return YES;
    return began && !ended;          // 开始了但没结束：被系统 SIGKILL 杀掉也是这种形态
}

NSArray<NSString *> *YBLastRunLogTail(NSUInteger n) {
    NSArray<NSString *> *slice = YBLastRunSlice();
    NSUInteger end = slice.count;
    while (end > 0 &&
           [[slice[end - 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length] == 0) end--;
    if (end == 0) return @[];
    NSUInteger from = end > n ? end - n : 0;
    return [slice subarrayWithRange:NSMakeRange(from, end - from)];
}