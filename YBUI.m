#import "YBUI.h"
#import "YBEngine.h"
#import "YBConfig.h"
#import "YBTouch.h"
#import "YBLog.h"



// 被点的视图上提取“可读文字”
static NSString *YBExtractText(UIView *v) {
    NSMutableArray *s = [NSMutableArray array];
    if ([v isKindOfClass:UILabel.class]) { UILabel *l=(UILabel*)v; if(l.text.length)[s addObject:l.text]; }
    if ([v isKindOfClass:UIButton.class]) {
        UIButton *b=(UIButton*)v;
        if (b.currentTitle.length) [s addObject:b.currentTitle];
        if (b.titleLabel.text.length) [s addObject:b.titleLabel.text];
    }
    if (v.accessibilityLabel.length) [s addObject:v.accessibilityLabel];
    return [s componentsJoinedByString:@" / "];
}

// ---------- 录制覆盖层：点一下目标按钮，抓它那串文字 ----------
// 悬浮窗：只处理自己子视图（悬浮球/面板）上的触摸，其它一律穿透给 App
@interface YBPassWindow : UIWindow
@end
@implementation YBPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    // 命中根视图 = 点到空白处，交给下层窗口
    if (v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface YBRecordView : UIView
@property (nonatomic, copy) void (^onPick)(NSString *text);
@end
@implementation YBRecordView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
        UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(0, frame.size.height*0.5-40, frame.size.width, 80)];
        tip.text = @"点一下要自动点击的按钮\n（或它的文字所在位置）";
        tip.numberOfLines = 0; tip.textAlignment = NSTextAlignmentCenter;
        tip.textColor = UIColor.whiteColor; tip.font = [UIFont boldSystemFontOfSize:17];
        [self addSubview:tip];
    }
    return self;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint pt = [[touches anyObject] locationInView:self];
    self.hidden = YES;
    UIWindow *win = [YBTouch keyWindow];
    UIView *hit = [win hitTest:pt withEvent:nil];
    self.hidden = NO;
    NSString *txt = YBExtractText(hit);
    // 往上找带文字/可交互的祖先
    UIView *cur = hit.superview; int depth = 0;
    while (!txt.length && cur && depth < 6) { txt = YBExtractText(cur); cur = cur.superview; depth++; }
    if (self.onPick) self.onPick(txt ?: @"");
    [self removeFromSuperview];
}
@end

// ---------- 悬浮面板 ----------

@interface YBUI ()
+ (instancetype)shared;
- (UIWindow *)window;
- (void)buildBall;
- (void)togglePanel;
- (void)buildPanel;
- (UILabel *)label:(NSString *)t y:(CGFloat)y w:(CGFloat)w pad:(CGFloat)pad;
- (UIButton *)mkButton:(NSString *)title color:(UIColor *)c action:(SEL)a;
- (void)refreshTimeLabel;
- (void)askSlotForText:(NSString *)text;
- (UIViewController *)vc;

@property (nonatomic, strong) UIButton *ball;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *logLabel;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIButton *> *taskBtns;
@property (nonatomic, strong) NSTimer *logTimer;
@property (nonatomic, weak) UILabel *timeLabel;
@property (nonatomic, strong) UIWindow *overlay;
@property (nonatomic, copy) NSArray<NSString *> *replay;   // 崩溃回放的行
- (NSString *)logText;
- (void)startLogTimer;
- (void)tickLog;
@end

@implementation YBUI

+ (instancetype)shared { static YBUI *s; static dispatch_once_t o; dispatch_once(&o, ^{ s=[YBUI new]; }); return s; }

+ (void)install {
    if ([self shared].ball) return;
    YBSetTrace("install:1 建悬浮球");
    YBLogSync(@"[面板] install 开始");
    [[self shared] buildBall];
    YBLogSync(@"[面板] 悬浮球 OK");
    YBSetTrace("install:2 观测通知");
    [[NSNotificationCenter defaultCenter] addObserver:[self shared] selector:@selector(onRunState:)
                                                 name:YBEngineRunStateChanged object:nil];
    YBSetTrace("install:done");
    YBLogSync(@"[面板] 悬浮球已挂载");
}

+ (void)showPanel { [[self shared] togglePanel]; }

+ (void)showCrashReplay:(NSArray<NSString *> *)lines {
    if (!lines.count) return;
    [self shared].replay = lines;
    if (![self shared].panel) [[self shared] togglePanel];
}

// 用独立的悬浮窗，避免被元宝上层视图/模态遮住
- (UIWindow *)window {
    if (self.overlay) return self.overlay;
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class] &&
            ((UIWindowScene *)sc).activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)sc; break; }
    }
    if (!scene) {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
            if ([sc isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)sc; break; }
    }
    UIWindow *w;
    if (scene) w = [[YBPassWindow alloc] initWithWindowScene:scene];
    else       w = [[YBPassWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 20;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc;
    w.hidden = NO;
    self.overlay = w;
    [YBTouch registerOwnWindow:w];      // 登记：取 App 窗口时永远跳过它
    return w;
}

- (void)buildBall {
    CGFloat d = 52;
    self.ball = [UIButton buttonWithType:UIButtonTypeCustom];
    self.ball.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - d - 8, 120, d, d);
    self.ball.backgroundColor = [[UIColor colorWithRed:0.10 green:0.62 blue:0.98 alpha:1] colorWithAlphaComponent:0.92];
    self.ball.layer.cornerRadius = d/2;
    [self.ball setTitle:@"元宝" forState:UIControlStateNormal];
    self.ball.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [self.ball addTarget:self action:@selector(ballTapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)];
    [self.ball addGestureRecognizer:pan];
    [[self window] addSubview:self.ball];
}

- (void)dragBall:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.window];
    CGPoint c = self.ball.center;
    self.ball.center = CGPointMake(c.x + t.x, c.y + t.y);
    [g setTranslation:CGPointZero inView:self.window];
}

- (void)ballTapped { [self togglePanel]; }

- (void)onRunState:(NSNotification *)n {
    BOOL running = [n.userInfo[@"running"] boolValue];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.ball.hidden = running;         // 只把球藏起来（免得被自己的 OCR 认进去）
        // 面板不隐藏：跑任务的时候正好在这里看着日志一行行往下走
        if (self.logLabel) self.logLabel.text = [self logText];
        YBLogSync(@"[界面] 运行状态 -> %@", running ? @"开始（面板保持可见）" : @"结束");
    });
}

- (void)togglePanel {
    if (self.panel) { [self.panel removeFromSuperview]; self.panel = nil; [self.logTimer invalidate]; self.logTimer = nil; self.logLabel = nil; self.replay = nil; return; }
    // 建面板涉及一堆控件，任何一步抛异常都别把 App 带崩：兜住并记日志
    YBSetTrace("panel:start");
    YBLogSync(@"[面板] 开始构建");
    @try {
        [self buildPanel];
        YBLogSync(@"[面板] 已显示");
    } @catch (NSException *e) {
        YBLogSync(@"[面板] 构建异常: %@ | %@\n%@", e.name, e.reason,
                  [e.callStackSymbols componentsJoinedByString:@"\n"]);
        if (self.panel.superview) [self.panel removeFromSuperview];
        self.panel = nil;
        [self.logTimer invalidate];
        self.logTimer = nil;
        self.logLabel = nil;
    }
}

- (UIColor *)panelBG { return [UIColor colorWithRed:0.09 green:0.10 blue:0.13 alpha:0.97]; }

- (UIButton *)mkButton:(NSString *)title color:(UIColor *)c action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = c;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 8;
    b.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildPanel {
    YBSetTrace("panel:1 取窗口");
    UIWindow *win = self.window;
    if (!win || win.bounds.size.width < 100) {
        YBLogSync(@"[面板] 没有可用窗口，放弃打开");
        return;
    }
    CGFloat w = MIN(MAX(win.bounds.size.width - 40, 240), 340);
    CGFloat h = 362;
    CGRect f = CGRectMake((win.bounds.size.width - w) / 2, (win.bounds.size.height - h) / 2, w, h);

    UIView *p = [[UIView alloc] initWithFrame:f];
    p.backgroundColor = [self panelBG];
    p.layer.cornerRadius = 14;
    p.layer.masksToBounds = YES;
    self.panel = p;
    [win addSubview:p];
    YBLogSync(@"[面板] 1 容器 OK (%.0fx%.0f)", w, h);

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, w - 28, 20)];
    t.text = [NSString stringWithFormat:@"元宝签到 · 上次停: %@", YBPrevTrace()];
    t.textColor = UIColor.whiteColor;
    t.font = [UIFont boldSystemFontOfSize:13];
    t.adjustsFontSizeToFitWidth = YES;
    t.minimumScaleFactor = 0.6;
    [p addSubview:t];
    YBLogSync(@"[面板] 2 标题 OK");

    UIButton *go = [self mkButton:@"▶ 执行全部任务" color:[UIColor colorWithRed:0.13 green:0.60 blue:0.35 alpha:1] action:@selector(runAll)];
    go.frame = CGRectMake(14, 36, w - 28, 34);
    [p addSubview:go];
    YBLogSync(@"[面板] 3 执行按钮 OK");

    // 自检拆成三段：哪一段崩，就把问题锁死在哪一段
    UIButton *stA = [self mkButton:@"A 只截图" color:[UIColor colorWithRed:0.16 green:0.42 blue:0.78 alpha:1] action:@selector(testCapture)];
    stA.frame = CGRectMake(14, 74, (w - 34) / 2, 28);
    [p addSubview:stA];

    UIButton *stB = [self mkButton:@"B 截图+OCR" color:[UIColor colorWithRed:0.16 green:0.42 blue:0.78 alpha:1] action:@selector(testOCR)];
    stB.frame = CGRectMake(14 + (w - 34) / 2 + 6, 74, (w - 34) / 2, 28);
    [p addSubview:stB];
    YBLogSync(@"[面板] 4 自检 A/B OK");

    UIButton *stC = [self mkButton:@"C 截图+OCR+点福利中心" color:[UIColor colorWithRed:0.16 green:0.42 blue:0.78 alpha:1] action:@selector(selfTest)];
    stC.frame = CGRectMake(14, 106, w - 28, 28);
    [p addSubview:stC];

    UIButton *stD = [self mkButton:@"D 只取视图树文字（不截图不OCR）" color:[UIColor colorWithRed:0.20 green:0.32 blue:0.52 alpha:1] action:@selector(testTextTree)];
    stD.frame = CGRectMake(14, 138, w - 28, 28);
    [p addSubview:stD];

    UIButton *cl = [self mkButton:@"关闭" color:[UIColor colorWithWhite:0.30 alpha:1] action:@selector(togglePanel)];
    cl.frame = CGRectMake(14, 170, w - 28, 26);
    [p addSubview:cl];
    YBLogSync(@"[面板] 5 按钮全部 OK");

    UILabel *lg = [[UILabel alloc] initWithFrame:CGRectMake(14, 200, w - 28, 122)];
    lg.numberOfLines = 19;
    lg.font = [UIFont systemFontOfSize:7.5];
    lg.textColor = [UIColor colorWithRed:0.6 green:0.95 blue:0.6 alpha:1];
    lg.text = [self logText];
    [p addSubview:lg];
    self.logLabel = lg;
    [self startLogTimer];

    YBSetTrace("panel:done");
    YBLogSync(@"[面板] 6 全部 OK（最小面板）");
}

- (NSString *)logText {
    // 崩溃回放：上次进程没跑完，就把那一段的最后几行摊在面板上（不用用户自己去翻文件）
    if (self.replay.count) {
        NSMutableArray *rls = [NSMutableArray arrayWithObject:@"=== 上次没跑完，下面是崩溃前的日志 ==="];
        NSUInteger rn = MIN(self.replay.count, (NSUInteger)16);
        [rls addObjectsFromArray:[self.replay subarrayWithRange:NSMakeRange(self.replay.count - rn, rn)]];
        return [rls componentsJoinedByString:@"\n"];
    }
    // 直接读日志文件的末尾：这样连"上一个进程崩溃前的最后几行"也能显示出来
    // （内存里的环形缓冲只属于当前进程，崩了就没东西可看）
    NSString *p = YBLogFilePath();
    NSString *all = p ? [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (all.length) {
        NSArray<NSString *> *ls = [all componentsSeparatedByString:@"\n"];
        NSUInteger n = MIN(ls.count, (NSUInteger)16);
        return [[ls subarrayWithRange:NSMakeRange(ls.count - n, n)] componentsJoinedByString:@"\n"];
    }
    NSArray<NSString *> *t = YBLogTail(8);
    return t ? [t componentsJoinedByString:@"\n"] : @"";
}

// 面板里的日志实时滚动（target/selector 版定时器，不用 block 版）
- (void)startLogTimer {
    [self.logTimer invalidate];
    self.logTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tickLog) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.logTimer forMode:NSRunLoopCommonModes];
}

- (void)tickLog {
    if (!self.logLabel) { [self.logTimer invalidate]; self.logTimer = nil; return; }
    self.logLabel.text = [self logText];
}

- (UILabel *)label:(NSString *)t y:(CGFloat)y w:(CGFloat)w pad:(CGFloat)pad {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, w, 22)];
    l.text = t; l.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    return l;
}

// ---- 交互 ----

- (void)runAll { [[YBEngine shared] runTasks:@[@"all"] count:-1 auto:YES]; }

- (void)selfTest { [[YBEngine shared] selfTest]; }
- (void)testCapture { [[YBEngine shared] testCapture]; }
- (void)testOCR { [[YBEngine shared] testOCR]; }
- (void)testTextTree { [[YBEngine shared] testTextTree]; }

- (void)stopRun { [[YBEngine shared] stop]; }

- (void)taskToggled:(UIButton *)b {
    NSString *t = [YBConfig allTasks][b.tag - 100];
    NSMutableArray *enabled = [[YBConfig enabledTasks] mutableCopy];
    BOOL on = ![enabled containsObject:t];
    if (on) [enabled addObject:t]; else [enabled removeObjectAtIndex:[enabled indexOfObject:t]];
    [YBConfig setEnabledTasks:enabled];
    b.backgroundColor = on ? [UIColor colorWithRed:0.10 green:0.62 blue:0.98 alpha:1] : [UIColor colorWithWhite:0.28 alpha:1];
}

- (void)refreshTimeLabel {
    self.timeLabel.text = [NSString stringWithFormat:@"%02ld:%02ld", (long)[YBConfig fireHour], (long)[YBConfig fireMinute]];
}
- (void)hourChanged:(UIButton *)b {
    NSInteger h = [YBConfig fireHour] + b.tag;         // 按钮 tag 就是步进量（+1 / -1）
    if (h < 0) h = 23;
    if (h > 23) h = 0;
    [YBConfig setFireHour:h minute:[YBConfig fireMinute]];
    [self refreshTimeLabel];
    YBLog(@"[设置] 自动执行时间 %02ld:%02ld", (long)[YBConfig fireHour], (long)[YBConfig fireMinute]);
    [[YBEngine shared] scheduleDailyTimer];
}
- (void)minChanged:(UIButton *)b {
    NSInteger m = [YBConfig fireMinute] + b.tag;       // 按钮 tag 就是步进量（+5 / -5）
    while (m < 0) m += 60;
    while (m > 59) m -= 60;
    [YBConfig setFireHour:[YBConfig fireHour] minute:m];
    [self refreshTimeLabel];
    YBLog(@"[设置] 自动执行时间 %02ld:%02ld", (long)[YBConfig fireHour], (long)[YBConfig fireMinute]);
    [[YBEngine shared] scheduleDailyTimer];
}

- (void)startRecord {
    UIWindow *win = self.window;
    self.panel.hidden = YES;
    YBRecordView *rv = [[YBRecordView alloc] initWithFrame:win.bounds];
    __weak typeof(self) weakSelf = self;
    rv.onPick = ^(NSString *text) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.panel.hidden = NO;
            [weakSelf askSlotForText:text];
        });
    };
    [win addSubview:rv];
}

- (void)askSlotForText:(NSString *)text {
    if (!text.length) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"没抓到文字"
            message:@"这个位置没有可读取的文字（可能是纯图片按钮）。请对准按钮上的文字再点，或改用手动输入。"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self.vc presentViewController:a animated:YES completion:nil];
        return;
    }
    NSArray *slots = @[@"entry.welfare",@"entry.checkin",@"ask.entry",@"ask.quickq",@"write.entry",
                       @"write.input",@"write.send",@"photo.entry",@"photo.gallery",@"photo.submit",
                       @"pimage.entry",@"pimage.pick",@"pimage.send",@"tpl.entry",@"tpl.tab",@"tpl.same",@"tpl.gen",
                       @"common.reward",@"common.back"];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"抓到文字：%@", text]
        message:@"把它绑定到哪个步骤？之后这一步就用这串文字定位，不再依赖坐标。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *s in slots) {
        [a addAction:[UIAlertAction actionWithTitle:s style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            NSArray *cur = [YBConfig aliasesFor:s defaults:@[]];
            NSMutableArray *nu = [cur mutableCopy];
            if (![nu containsObject:text]) [nu insertObject:text atIndex:0];
            [YBConfig setAliases:nu forSlot:s];
            YBLog(@"[录制] %@ += \"%@\"", s, text);
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self.vc presentViewController:a animated:YES completion:nil];
}

- (UIViewController *)vc {
    // 弹窗挂在悬浮窗的根控制器上；都没有时退到 App 根控制器
    UIViewController *r = [self window].rootViewController;
    while (r.presentedViewController) r = r.presentedViewController;
    if (r) return r;

    UIWindow *win = [YBTouch keyWindow];
    r = win.rootViewController;
    while (r.presentedViewController) r = r.presentedViewController;
    return r;
}

@end