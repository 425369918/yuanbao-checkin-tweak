#import "YBEngine.h"
#import "YBScreen.h"
#import "YBTouch.h"
#import "YBConfig.h"
#import "YBStep.h"
#import "YBLog.h"
#import <Vision/Vision.h>

@interface YBEngine ()
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *report;
@property (nonatomic, strong) dispatch_queue_t workQ;
@property (nonatomic, assign) BOOL stopRequested;

- (void)setRunning:(BOOL)running;
- (void)runOneTask:(NSString *)task count:(NSInteger)count auto:(BOOL)autoFill;
- (BOOL)performStep:(YBStep *)s;
- (BOOL)ocrTap:(NSArray<NSString *> *)keys;
- (BOOL)visibleTextMatches:(NSArray<NSString *> *)keys;
- (void)onMainVoid:(dispatch_block_t)block;
- (BOOL)onMain:(BOOL(^)(void))block;
- (void)beginBG;
- (void)endBG;
- (void)saveReport;
@end

NSString *const YBEngineRunStateChanged = @"YBEngineRunStateChanged";

@implementation YBEngine

+ (instancetype)shared {
    static YBEngine *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [YBEngine new];
        s.workQ = dispatch_queue_create("yb.engine", DISPATCH_QUEUE_SERIAL);
    });
    return s;
}

- (void)warmUp {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(8, 8), NO, 1);
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        VNRecognizeTextRequest *r = [[VNRecognizeTextRequest alloc] init];
        r.recognitionLanguages = @[@"zh-Hans"];
        VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img.CGImage options:@{}];
        [h performRequests:@[r] error:NULL];
        YBLog(@"[预热] Vision 就绪");
    });
}

- (void)stop { self.stopRequested = YES; }

- (void)setRunning:(BOOL)running {
    _running = running;
    [[NSNotificationCenter defaultCenter] postNotificationName:YBEngineRunStateChanged
                                                        object:nil userInfo:@{@"running": @(running)}];
}

- (void)runTasks:(NSArray<NSString *> *)tasks count:(NSInteger)count auto:(BOOL)autoFill {
    if (self.running) { YBLog(@"[跳过] 已有任务在跑"); return; }
    [self setRunning:YES];
    self.stopRequested = NO;
    [self beginBG];
    self.report = [NSMutableArray array];

    NSArray *list = tasks;
    if (!list.count || [list containsObject:@"all"]) {
        list = [YBConfig enabledTasks];
    }
    if ([list containsObject:@"auto"]) list = [YBConfig enabledTasks];

    dispatch_async(self.workQ, ^{
        YBSetTrace("run:start");
        YBLogSync(@"===== 开始，任务 %@ count=%@ auto=%@ =====",
                  list, count > 0 ? @(count) : @"默认", autoFill ? @"是" : @"否");
        for (NSString *task in list) {
            if (self.stopRequested) { YBLog(@"[停止] 收到停止请求"); break; }
            YBSetTrace("run:task");
            YBLogSync(@"----- 任务开始 %@ -----", task);
            @try { [self runOneTask:task count:count auto:autoFill]; }
            @catch (NSException *e) { YBLogSync(@"[异常] %@: %@ %@", task, e.name, e.reason); }
            [NSThread sleepForTimeInterval:1.2];
        }
        YBLogSync(@"===== 全部结束 =====");
        [self setRunning:NO];
        [self endBG];
        [YBConfig markRunToday];
        [self saveReport];
    });
}

- (void)runOneTask:(NSString *)task count:(NSInteger)count auto:(BOOL)autoFill {
    YBLog(@"----- %@ (%@) -----", task, [YBConfig displayNameFor:task]);
    NSArray<YBStep *> *steps = [YBConfig stepsForTask:task];
    if (!steps.count) { YBLog(@"[跳过] 未知任务 %@", task); return; }

    NSInteger loops = count > 0 ? count : 1;
    for (NSInteger i = 0; i < loops; i++) {
        if (self.stopRequested) break;
        BOOL any = NO;
        for (YBStep *s in steps) {
            if (self.stopRequested) break;
            BOOL ok = [self performStep:s];
            any = any || ok;
            [NSThread sleepForTimeInterval:[YBConfig stepGap]];
        }
        [self.report addObject:@{@"task": task, @"iter": @(i+1), @"ok": @(any)}];
        YBLog(@"%@ 第 %ld 轮 %@", task, (long)(i+1), any ? @"完成" : @"可能未生效");
    }
}

- (BOOL)performStep:(YBStep *)s {
    YBSetTrace("step:run");
    YBLogSync(@"[步骤] kind=%ld keys=%@ secs=%.1f", (long)s.kind, s.keys ?: @[], (double)s.seconds);
    switch (s.kind) {
        case YBStepSleep:
            [NSThread sleepForTimeInterval:s.seconds];
            return YES;

        case YBStepWait: {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:s.seconds];
            while ([deadline timeIntervalSinceNow] > 0) {
                if ([self visibleTextMatches:s.keys]) return YES;
                if (self.stopRequested) return NO;
                [NSThread sleepForTimeInterval:0.6];
            }
            YBLog(@"[等待] %@ 未在 %.0fs 内出现", s.keys, s.seconds);
            return NO;
        }

        case YBStepTapText: {
            BOOL ok = [self onMain:^BOOL{ return [YBTouch tapText:s.keys]; }];
            if (!ok) ok = [self ocrTap:s.keys];
            return ok;
        }

        case YBStepTapOCR:
            return [self ocrTap:s.keys];

        case YBStepInputText:
            return [self onMain:^BOOL{ return [YBTouch inputText:s.text nearKeys:s.keys]; }];
    }
    return NO;
}

- (BOOL)ocrTap:(NSArray<NSString *> *)keys {
    __block YBScreen *sc = nil;
    [self onMainVoid:^{ sc = [YBScreen capture]; }];
    [sc runOCR];
    CGPoint p = [sc centerOfTextContaining:keys];
    if (CGPointEqualToPoint(p, CGPointZero)) { YBLog(@"[OCR点按] 未找到 %@", keys); return NO; }
    CGPoint pt = p;
    return [self onMain:^BOOL{ return [YBTouch tapPoint:pt]; }];
}

- (BOOL)visibleTextMatches:(NSArray<NSString *> *)keys {
    __block BOOL hit = NO;
    [self onMainVoid:^{
        NSArray<NSString *> *texts = [YBTouch dumpVisibleTexts];
        for (NSString *t in texts) {
            for (NSString *k in keys) {
                if (k.length && [t containsString:k]) { hit = YES; return; }
            }
        }
    }];
    return hit;
}

- (void)onMainVoid:(dispatch_block_t)block {
    // 注意：主线程 block 里抛的异常，外面 workQ 上的 @try 是接不住的（会直接 abort）。
    // 所以这里在"主线程那一侧"自己兜异常。
    dispatch_block_t run = ^{
        @try { block(); }
        @catch (NSException *e) { YBLogSync(@"[主线程异常] %@ | %@", e.name, e.reason); }
    };
    if ([NSThread isMainThread]) run(); else dispatch_sync(dispatch_get_main_queue(), run);
}
- (BOOL)onMain:(BOOL(^)(void))block {
    __block BOOL r = NO;
    dispatch_block_t run = ^{
        @try { r = block(); }
        @catch (NSException *e) { YBLogSync(@"[主线程异常] %@ | %@", e.name, e.reason); r = NO; }
    };
    if ([NSThread isMainThread]) run(); else dispatch_sync(dispatch_get_main_queue(), run);
    return r;
}

- (void)beginBG {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"YBCheckin"
                                                                   expirationHandler:^{ [self endBG]; }];
    });
}
- (void)endBG {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.bgTask && self.bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
            self.bgTask = UIBackgroundTaskInvalid;
        }
    });
}

- (void)scheduleDailyTimer {
    NSDate *fire = [YBConfig nextFireDate];
    NSTimeInterval iv = [fire timeIntervalSinceNow];
    if (iv < 1) iv = 1;
    YBLog(@"[定时] 下次自动执行: %@ (%.0f 秒后)", fire, iv);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(iv * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YBLog(@"[定时] 触发每日任务");
        [self runTasks:@[@"all"] count:-1 auto:YES];
        [self scheduleDailyTimer];
    });
}

- (void)saveReport {
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    // 注意：NSDate 不能直接进 JSON，先转字符串
    NSDictionary *d = @{@"time": [f stringFromDate:[NSDate date]], @"items": self.report ?: @[]};
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:NULL];
    if (!j) { YBLog(@"[报告] JSON 序列化失败"); return; }
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *p = [dir stringByAppendingPathComponent:
                   [NSString stringWithFormat:@"YuanbaoCheckin-%@.json", [f stringFromDate:[NSDate date]]]];
    [j writeToFile:p atomically:YES];
    YBLog(@"[报告] %@", p);
}

@end