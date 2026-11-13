#import "YBEngine.h"
#import "YBScreen.h"
#import "YBTouch.h"
#import "YBConfig.h"
#import "YBStep.h"
#import "YBLog.h"
#import "YBWeb.h"
#import <Vision/Vision.h>

@interface YBEngine ()
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *report;
@property (nonatomic, strong) dispatch_queue_t workQ;
@property (nonatomic, assign) BOOL stopRequested;

- (void)setRunning:(BOOL)running;
- (void)runOneTask:(NSString *)task count:(NSInteger)count auto:(BOOL)autoFill;
- (BOOL)performStep:(YBStep *)s;
- (void)probeWelfare;
- (void)diagnoseWelfare;
- (void)autoWelfare;
- (void)probeWeb;
- (void)probeWelfareWeb;
- (void)probeA11y;
- (NSArray<NSString *> *)dumpTextsNow;
- (BOOL)pageHasAny:(NSArray<NSString *> *)keys;
- (void)logTexts:(NSArray<NSString *> *)texts tag:(NSString *)tag;
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
    // 曾经这里预热 Vision，实测 Vision 的 performRequests 在元宝进程里必崩（见 v11/v12），
    // 现在已经彻底不用 OCR，也就不再碰 Vision —— 少加载一个框架，少一个崩溃面。
    YBLog(@"[预热] 已启用纯视图树模式（不加载 Vision）");
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
    YBLogSync(@"[步骤] kind=%ld keys=%@ secs=%.1f", (long)s.kind, YBJoinKeys(s.keys), (double)s.seconds);
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
            YBLog(@"[等待] %@ 未在 %.0fs 内出现", YBJoinKeys(s.keys), s.seconds);
            return NO;
        }

        case YBStepTapText: {
            // 只用视图树：实测 Vision 在这个注入进程里 performRequests 必崩，OCR 已彻底弃用
            return [self onMain:^BOOL{ return [YBTouch tapText:s.keys]; }];
        }

        case YBStepTapOCR: {
            // 老配置里写的是"OCR 点按"，现在统一走视图树
            return [self onMain:^BOOL{ return [YBTouch tapText:s.keys]; }];
        }

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

// 读当前页面的全部文字（主线程）
- (NSArray<NSString *> *)dumpTextsNow {
    __block NSArray<NSString *> *texts = nil;
    [self onMainVoid:^{ texts = [YBTouch dumpVisibleTexts]; }];
    return texts ?: @[];
}

- (BOOL)pageHasAny:(NSArray<NSString *> *)keys {
    for (NSString *t in [self dumpTextsNow])
        for (NSString *k in keys)
            if (k.length && [t containsString:k]) return YES;
    // 福利中心页面的字全在 H5 里，UIKit 只有「返回」，所以还要看一份 H5 正文
    NSString *web = [YBWeb textOfFirstWeb];
    if (web.length) {
        for (NSString *k in keys)
            if (k.length && [web containsString:k]) return YES;
    }
    return NO;
}

// 把页面文字分条打出来（每行 5 条，面板一屏能看几行，日志文件里是全的）
- (void)logTexts:(NSArray<NSString *> *)texts tag:(NSString *)tag {
    YBLogSync(@"[%@] 页面文字 %lu 条", tag, (unsigned long)texts.count);
    NSMutableString *line = [NSMutableString string];
    NSInteger inLine = 0;
    for (NSString *t in texts) {
        if (inLine >= 5) { YBLogSync(@"[%@] %@", tag, line); [line setString:@""]; inLine = 0; }
        [line appendFormat:@"%@ / ", t];
        inLine++;
    }
    if (line.length) YBLogSync(@"[%@] %@", tag, line);
}

// 「执行全部任务」= 真正干活的那条：进福利中心 → 打卡 → 领奖励
- (void)autoWelfare {
    if (self.running) { YBLogSync(@"[打卡] 已有任务在跑"); return; }
    [self setRunning:YES];
    self.stopRequested = NO;
    [self beginBG];
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自动打卡开始 =====");

        // 1) 先进福利中心（已经在里面就跳过）
        YBSetTrace("auto:1 判断是否在福利中心");
        BOOL inside = [self pageHasAny:@[@"元宝能力站", @"已打卡", @"每日任务", @"兑换商城", @"奖品记录"]];
        YBLogSync(@"[打卡] 当前已在福利中心: %@", inside ? @"是" : @"否");
        if (!inside) {
            YBSetTrace("auto:2 点福利中心");
            BOOL ok = [self onMain:^BOOL{ return [YBTouch tapText:@[@"福利中心"] ]; }];
            YBLogSync(@"[打卡] 点「福利中心」-> %@", ok ? @"已触发" : @"没找到");
            [NSThread sleepForTimeInterval:2.0];
        }
        YBLogSync(@"[打卡] 福利中心页面文字 %lu 条（UIKit 里通常只有「返回」）",
                  (unsigned long)[self dumpTextsNow].count);

        // 1.5) 这个页面如果是 H5，就走 WebView 通道（UIKit 里只有个「返回」，读不到正文）
        YBSetTrace("auto:1b 判断H5");
        NSArray<UIView *> *wvs = [YBWeb webViews];
        BOOL isH5 = wvs.count > 0;
        YBLogSync(@"[打卡] 页面 WebView %lu 个 -> H5 通道: %@", (unsigned long)wvs.count,
                  isH5 ? @"开启" : @"关闭（走原生视图树）");

        // 2) H5：按页面上"真实按钮文字"点（签到 / 打卡 / 领奖 / 去邀请）
        NSInteger hitCount = 0;
        if (isH5) {
            YBSetTrace("auto:2 列按钮");
            [YBWeb logClickables];
            NSArray<NSArray *> *groups = @[
                @[@"立即打卡", @"打卡", @"立即签到", @"签到领积分", @"签到"],
                @[@"开心收下", @"收下", @"立即领取", @"领取", @"查看奖励"],
                @[@"确定", @"知道了", @"我知道了", @"开心收下"],
                @[@"去邀请", @"邀请"],
            ];
            for (NSArray *g in groups) {
                if (self.stopRequested) break;
                YBSetTrace("auto:3 试按钮");
                BOOL ok = [YBWeb tapText:g];
                YBLogSync(@"[打卡] 「%@」-> %@", YBJoinKeys(g), ok ? @"已点" : @"没有这个按钮");
                if (ok) { hitCount++; [NSThread sleepForTimeInterval:1.2]; }
            }
            YBLogSync(@"[打卡] 本轮点中 %ld 组", (long)hitCount);
            YBSetTrace("auto:3b 复查");
            NSString *t2 = [YBWeb textOfFirstWeb];
            NSString *flat = [[t2 stringByReplacingOccurrencesOfString:@"\n" withString:@" "] ?: @"" copy];
            YBLogSync(@"[打卡] 复查正文 %lu 字: %@", (unsigned long)flat.length,
                      flat.length ? [flat substringToIndex:MIN(flat.length, (NSUInteger)220)] : @"(读不到)");
        } else {
            // 原生页面：退回按文字找 UIView
            NSArray<NSString *> *anchors = @[
                @"签到", @"打卡", @"立即签到", @"签到领积分",
                @"领取", @"开心收下", @"收下", @"立即领取", @"查看奖励",
                @"确定", @"知道了",
            ];
            for (NSString *a in anchors) {
                if (self.stopRequested) break;
                YBSetTrace("auto:3 试锚点");
                BOOL ok = [self onMain:^BOOL{ return [YBTouch tapText:@[a] ]; }];
                YBLogSync(@"[打卡] 锚点「%@」-> %@", a, ok ? @"已触发" : @"无此文字/没生效");
                if (ok) { hitCount++; [NSThread sleepForTimeInterval:1.2]; }
            }
            YBLogSync(@"[打卡] 本轮命中 %ld 个锚点", (long)hitCount);
        }

        // 3) 收尾：把最终正文打出来（能直接看出「已打卡N天」变没变）
        YBSetTrace("auto:4 收尾");
        if (isH5) {
            NSString *t = [YBWeb textOfFirstWeb];
            NSString *flat = [[t stringByReplacingOccurrencesOfString:@"\n" withString:@" "] ?: @"" copy];
            NSLog(@"[YB] 收尾正文 %lu 字", (unsigned long)flat.length);
            YBLogSync(@"[打卡完成] 最终正文 %lu 字: %@", (unsigned long)flat.length,
                      flat.length ? [flat substringToIndex:MIN(flat.length, (NSUInteger)200)] : @"(读不到)");
        } else {
            [self logTexts:[self dumpTextsNow] tag:@"打卡完成"];
        }
        YBSetTrace("auto:done");
        YBLogSync(@"===== 自动打卡结束 =====");
        [self setRunning:NO];
        [self endBG];
    });
}

// 自检 I：进福利中心（不在就点进去），然后只读 H5 信息，不点任何任务
- (void)probeWelfareWeb {
    if (self.running) { YBLogSync(@"[自检I] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检I 开始（进福利中心 + 读 H5） =====");
        YBSetTrace("I:1 判断是否在福利中心");
        BOOL inside = [self pageHasAny:@[@"元宝能力站", @"已打卡", @"每日任务", @"兑换商城", @"奖品记录"]];
        if (!inside) {
            YBSetTrace("I:2 点福利中心");
            BOOL ok = [self onMain:^BOOL{ return [YBTouch tapText:@[@"福利中心"] ]; }];
            YBLogSync(@"[自检I] 点「福利中心」-> %@", ok ? @"已触发" : @"没找到");
            [NSThread sleepForTimeInterval:2.0];
        } else {
            YBLogSync(@"[自检I] 已在福利中心页面");
        }
        YBSetTrace("I:3 读H5");
        [YBWeb logSummary];
        YBSetTrace("I:done");
        YBLogSync(@"===== 自检I 结束 =====");
    });
}

// 自检 J：读无障碍元素里的文字（判断页面是不是 SwiftUI / Flutter 这类自绘页面）
- (void)probeA11y {
    if (self.running) { YBLogSync(@"[自检J] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检J 开始（读无障碍元素） =====");
        YBSetTrace("J:1 遍历无障碍元素");
        __block NSArray<NSString *> *texts = nil;
        [self onMainVoid:^{ texts = [YBTouch dumpAccessibilityTexts]; }];
        YBLogSync(@"[自检J] 无障碍文字 %lu 条", (unsigned long)texts.count);
        NSMutableString *line = [NSMutableString string];
        NSInteger inLine = 0;
        for (NSString *t in texts) {
            if (inLine >= 4) { YBLogSync(@"[J] %@", line); [line setString:@""]; inLine = 0; }
            [line appendFormat:@"%@ / ", t];
            inLine++;
        }
        if (line.length) YBLogSync(@"[J] %@", line);
        YBSetTrace("J:done");
        YBLogSync(@"===== 自检J 结束 =====");
    });
}

// 自检 H：只读 H5 页面（不点任何东西）—— 判断福利中心到底是不是 H5、里面写了什么
- (void)probeWeb {
    if (self.running) { YBLogSync(@"[自检H] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检H 开始（读 H5 页面） =====");
        YBSetTrace("H:1 找WebView");
        [YBWeb logSummary];
        YBSetTrace("H:done");
        YBLogSync(@"===== 自检H 结束 =====");
    });
}

// 自检 F：诊断「福利中心」到底能不能点 —— 每个候选在哪、在不在屏幕内、点不点得着、点完界面变没变
- (void)diagnoseWelfare {
    if (self.running) { YBLogSync(@"[自检F] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检F 开始（诊断福利中心能不能点） =====");
        YBSetTrace("F:1 列候选");
        [self onMainVoid:^{ [YBTouch diagnoseText:@[@"福利中心"] ]; }];

        YBSetTrace("F:2 试点击");
        __block NSString *before = nil;
        [self onMainVoid:^{ before = [YBTouch textSignature]; }];
        BOOL ok = [self onMain:^BOOL{ return [YBTouch tapText:@[@"福利中心"] ]; }];
        __block NSString *after = nil;
        [self onMainVoid:^{ after = [YBTouch textSignature]; }];
        YBLogSync(@"[F] 点击=%@ 指纹 %@ -> %@ %@", ok ? @"成功" : @"失败", before, after,
                  [before isEqualToString:after] ? @"（界面没变）" : @"（界面已变）");
        YBSetTrace("F:done");
        YBLogSync(@"===== 自检F 结束 =====");
    });
}

// 自检 E：点「福利中心」进去，然后把页面上的全部文字分条打出来
// —— 拿到这一版元宝福利中心的真实按钮文案，锚点表才能照着它写
- (void)probeWelfare {
    if (self.running) { YBLogSync(@"[自检E] 已有任务在跑"); return; }
    dispatch_async(self.workQ, ^{
        YBLogSync(@"===== 自检E 开始（点福利中心 + 打印页面文字） =====");
        YBSetTrace("E:1 点福利中心");
        // 已经在福利中心页面里的话就别再点了（点了也找不到「福利中心」，白跑一趟）
        BOOL inside = [self pageHasAny:@[@"元宝能力站", @"已打卡", @"每日任务", @"兑换商城", @"奖品记录"]];
        if (inside) {
            YBLogSync(@"[自检E] 已经在福利中心页面，跳过点击");
        } else {
            BOOL ok = [self onMain:^BOOL{ return [YBTouch tapText:@[@"福利中心"] ]; }];
            YBLogSync(@"[自检E] 点「福利中心」-> %@", ok ? @"已触发" : @"没找到/没触发");
            [NSThread sleepForTimeInterval:2.0];
        }

        for (int round = 1; round <= 3; round++) {
            YBSetTrace("E:2 读页面文字");
            __block NSArray<NSString *> *texts = nil;
            [self onMainVoid:^{ texts = [YBTouch dumpVisibleTexts]; }];
            YBLogSync(@"[自检E] 第%d次 共 %lu 条", round, (unsigned long)texts.count);
            NSMutableString *line = [NSMutableString string];
            NSInteger inLine = 0;
            for (NSString *t in texts) {
                if (inLine >= 5) { YBLogSync(@"[E] %@", line); [line setString:@""]; inLine = 0; }
                [line appendFormat:@"%@ / ", t];
                inLine++;
            }
            if (line.length) YBLogSync(@"[E] %@", line);
            [NSThread sleepForTimeInterval:1.2];
        }
        YBSetTrace("E:done");
        YBLogSync(@"===== 自检E 结束 =====");
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