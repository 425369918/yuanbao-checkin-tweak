#import "YBLog.h"
#import <UIKit/UIKit.h>

static NSMutableArray<NSString *> *gRing = nil;
static NSString *gPath = nil;
static dispatch_queue_t gQ;
static NSDateFormatter *gFmt;

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