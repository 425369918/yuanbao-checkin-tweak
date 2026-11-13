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
- (BOOL)ocrVisible:(NSArray<NSString *> *)keys;
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
    YBSetTrace("run:tap");
    // 这一行在主线程（按钮回调里）同步落盘：万一后面瞬间崩，也能证明"按钮确实被点到了"
    YBLogSync(@"[运行] 收到执行请求 %@", tasks);
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
        // 一次性把窗口/UI 框架/视图树文字打出来，版本不匹配时靠这几行定位
        [self onMainVoid:^{ [YBTouch logDiagnostics]; }];
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
    if (CGPointEqualToPoint(p, CGPointZero)) {
        // 找不到时把 OCR 实际看到的文字打出来 —— 版本不匹配时一眼就能看出该改成哪几个字
        NSMutableArray *seen = [NSMutableArray array];
        for (NSDictionary *d in [sc lineDicts]) {
            if (seen.count >= 20) break;
            [seen addObject:d[@"text"]];
        }
        YBLog(@"[OCR点按] 未找到 %@；屏幕文字: %@", keys,
              seen.count ? [seen componentsJoinedByString:@" / "] : @"(OCR 没认出任何文字)");
        return NO;
    }
    CGPoint pt = p;
    return [self onMain:^BOOL{ return [YBTouch tapPoint:pt]; }];
}

- (BOOL)ocrVisible:(NSArray<NSString *> *)keys {
    __block YBScreen *sc = nil;
    [self onMainVoid:^{ sc = [YBScreen capture]; }];
    [sc runOCR];
    return !CGPointEqualToPoint([sc centerOfTextContaining:keys], CGPointZero);
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
    if (hit) return YES;
    // 视图树里取不到文字（元宝这种自绘 UI 很常见）→ 再让 OCR 看一遍
    return [self ocrVisible:keys];
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

// 最小自检 A：只截图，不碰 OCR、不碰视图树
- (void)testCapture {
    if (self.running) { YBLogSync(@"[自检A] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检A 开始（只截图） =====");
        YBSetTrace("A:1 调用截图");
        __block YBScreen *sc = nil;
        [self onMainVoid:^{ sc = [YBScreen capture]; }];
        YBLogSync(@"[自检A] 截图结果=%@ 尺寸=%.0fx%.0f", sc.image ? @"有图" : @"没有图",
                  sc.image.size.width, sc.image.size.height);
        YBSetTrace("A:done");
        YBLogSync(@"===== 自检A 结束 =====");
    });
}

// 自检 B：截图 + OCR
- (void)testOCR {
    if (self.running) { YBLogSync(@"[自检B] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检B 开始（截图 + OCR） =====");
        YBSetTrace("B:1 截图");
        __block YBScreen *sc = nil;
        [self onMainVoid:^{ sc = [YBScreen capture]; }];
        if (!sc.image) { YBLogSync(@"[自检B] 没有图，停止"); YBLogSync(@"===== 自检B 结束 ====="); return; }
        YBSetTrace("B:2 OCR");
        [sc runOCR];
        NSMutableArray *seen = [NSMutableArray array];
        for (NSDictionary *d in [sc lineDicts]) { if (seen.count >= 25) break; [seen addObject:d[@"text"]]; }
        YBLogSync(@"[自检B] 认出 %lu 行: %@", (unsigned long)[sc lineDicts].count,
                  seen.count ? [seen componentsJoinedByString:@" / "] : @"(0 行，画面可能是空白)");
        YBSetTrace("B:done");
        YBLogSync(@"===== 自检B 结束 =====");
    });
}

// 自检 D：只取视图树文字，完全不碰截图和 OCR
- (void)testTextTree {
    if (self.running) { YBLogSync(@"[自检D] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检D 开始（只取视图树文字） =====");
        YBSetTrace("D:1 遍历视图树");
        __block NSArray<NSString *> *texts = nil;
        [self onMainVoid:^{ texts = [YBTouch dumpVisibleTexts]; }];
        NSMutableArray *pick = [NSMutableArray array];
        for (NSString *t in texts) { if (pick.count >= 30) break; [pick addObject:t]; }
        YBLogSync(@"[自检D] 视图树文字 %lu 条: %@", (unsigned long)texts.count,
                  pick.count ? [pick componentsJoinedByString:@" / "] : @"(0 条 —— 界面是自绘的，只能靠 OCR)");
        YBSetTrace("D:done");
        YBLogSync(@"===== 自检D 结束 =====");
    });
}

// 自检 C：截图 + OCR + 找福利中心 + 点一下
- (void)selfTest {
    if (self.running) { YBLogSync(@"[自检C] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检C 开始（截图 + OCR + 点福利中心） =====");
        YBSetTrace("selftest:1 诊断");
        [self onMainVoid:^{ [YBTouch logDiagnostics]; }];

        YBSetTrace("selftest:2 截图");
        __block YBScreen *sc = nil;
        [self onMainVoid:^{ sc = [YBScreen capture]; }];
        YBLogSync(@"[自检C] 截图=%@", sc.image ? @"有图" : @"没有图");
        if (!sc.image) { YBLogSync(@"===== 自检C 结束 ====="); return; }

        YBSetTrace("selftest:3 OCR");
        [sc runOCR];
        NSMutableArray *seen = [NSMutableArray array];
        for (NSDictionary *d in [sc lineDicts]) { if (seen.count >= 25) break; [seen addObject:d[@"text"]]; }
        YBLogSync(@"[自检C] OCR %lu 行: %@", (unsigned long)[sc lineDicts].count,
                  seen.count ? [seen componentsJoinedByString:@" / "] : @"(0 行)");

        YBSetTrace("selftest:4 找福利中心");
        CGPoint p = [sc centerOfTextContaining:@[@"福利中心", @"福利", @"签到"]];
        if (CGPointEqualToPoint(p, CGPointZero)) {
            YBLogSync(@"[自检C] 没找到福利中心/签到，先看上面 OCR 认出了哪些字");
        } else {
            YBSetTrace("selftest:5 点按");
            BOOL ok = [self onMain:^BOOL{ return [YBTouch tapPoint:p]; }];
            YBLogSync(@"[自检C] 点按 (%.0f,%.0f) 结果=%@", p.x, p.y, ok ? @"成功" : @"没触发");
            [NSThread sleepForTimeInterval:1.2];
        }
        YBSetTrace("selftest:done");
        YBLogSync(@"===== 自检C 结束 =====");
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