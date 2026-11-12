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
- (NSString *)logText;
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
        self.ball.hidden = running;                 // 跑的时候藏起来，别被自己 OCR 认进去
        if (self.panel && running) { self.panel.hidden = YES; }
        if (self.panel && !running) { self.panel.hidden = NO; }
    });
}

- (void)togglePanel {
    if (self.panel) { [self.panel removeFromSuperview]; self.panel = nil; [self.logTimer invalidate]; self.logTimer = nil; self.logLabel = nil; return; }
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
        YBLogSync(@"[面板] 没有可用窗口，放弃打开（%@）", win ? @"尺寸异常" : @"nil");
        return;
    }
    CGFloat w = MIN(MAX(win.bounds.size.width - 24, 220), 380);
    CGFloat h = MIN(MAX(win.bounds.size.height - 140, 260), 560);
    CGRect f = CGRectMake((win.bounds.size.width - w)/2, (win.bounds.size.height - h)/2, w, h);

    UIView *p = [[UIView alloc] initWithFrame:f];
    p.backgroundColor = [self panelBG];
    p.layer.cornerRadius = 16;
    p.layer.masksToBounds = YES;
    self.panel = p;
    [win addSubview:p];
    YBLogSync(@"[面板] 1 容器 OK (%.0fx%.0f)", w, h);

    // 只用 UILabel / UIButton / UIScrollView 这三种最基础的控件：
    // 原来的 UITextView、UIStepper、block 版 NSTimer 在"注入到别人的进程"里最容易出事，全部换掉
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:p.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [p addSubview:sv];
    YBSetTrace("panel:2 滚动区");
    YBLogSync(@"[面板] 2 滚动区 OK");

    CGFloat pad = 12, iw = w - pad*2, y = 10;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, iw, 22)];
    title.text = @"元宝签到 · 巨魔版";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:16];
    [sv addSubview:title];
    y += 26;

    UIButton *close = [self mkButton:@"关闭" color:[UIColor colorWithWhite:0.30 alpha:1] action:@selector(togglePanel)];
    close.frame = CGRectMake(pad, y, 52, 26);
    [sv addSubview:close];

    UIButton *runAll = [self mkButton:@"▶ 立即执行全部任务" color:[UIColor colorWithRed:0.13 green:0.60 blue:0.35 alpha:1] action:@selector(runAll)];
    runAll.frame = CGRectMake(pad + 58, y, iw - 58, 26);
    [sv addSubview:runAll];
    y += 30;

    UIButton *stop = [self mkButton:@"■ 停止当前任务" color:[UIColor colorWithRed:0.75 green:0.18 blue:0.18 alpha:1] action:@selector(stopRun)];
    stop.frame = CGRectMake(pad, y, iw, 26);
    [sv addSubview:stop];
    y += 32;
    YBSetTrace("panel:3 顶部按钮");
    YBLogSync(@"[面板] 3 顶部按钮 OK");

    UILabel *l1 = [self label:@"执行任务" y:y w:iw pad:pad];
    [sv addSubview:l1];
    y += 22;
    self.taskBtns = [NSMutableDictionary dictionary];
    NSArray *tasks = [YBConfig allTasks] ?: @[];
    NSArray *enabled = [YBConfig enabledTasks] ?: @[];
    CGFloat bw = (iw - 8) / 2;
    for (NSUInteger i = 0; i < tasks.count; i++) {
        NSString *t = tasks[i];
        UIButton *b = [self mkButton:[YBConfig displayNameFor:t] color:[UIColor colorWithWhite:0.28 alpha:1] action:@selector(taskToggled:)];
        b.tag = 100 + (NSInteger)i;
        b.frame = CGRectMake(pad + (i % 2) * (bw + 8), y, bw, 28);
        if ([enabled containsObject:t]) b.backgroundColor = [UIColor colorWithRed:0.10 green:0.62 blue:0.98 alpha:1];
        [sv addSubview:b];
        self.taskBtns[t] = b;
        if (i % 2 == 1) y += 32;
    }
    if (tasks.count % 2 == 1) y += 32;
    y += 4;
    YBSetTrace("panel:4 任务开关");
    YBLogSync(@"[面板] 4 任务开关 OK (%lu 个)", (unsigned long)tasks.count);

    UILabel *l2 = [self label:@"自动执行时间" y:y w:iw pad:pad];
    [sv addSubview:l2];
    y += 22;
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(pad, y + 3, 66, 22)];
    tl.textColor = UIColor.whiteColor;
    tl.font = [UIFont boldSystemFontOfSize:15];
    [sv addSubview:tl];
    self.timeLabel = tl;
    [self refreshTimeLabel];
    // 时/分用按钮加减，不用 UIStepper
    NSArray<NSString *> *caps = @[@"时 +", @"时 −", @"分 +", @"分 −"];
    for (NSUInteger i = 0; i < caps.count; i++) {
        SEL act = (i < 2) ? @selector(hourChanged:) : @selector(minChanged:);
        UIButton *b = [self mkButton:caps[i] color:[UIColor colorWithWhite:0.30 alpha:1] action:act];
        b.tag = (i == 0) ? 1 : (i == 1) ? -1 : (i == 2) ? 5 : -5;
        b.frame = CGRectMake(pad + 72 + i * 52, y, 48, 28);
        [sv addSubview:b];
    }
    y += 34;
    YBSetTrace("panel:5 时间控件");
    YBLogSync(@"[面板] 5 时间控件 OK");

    UILabel *l3 = [self label:@"运行日志" y:y w:iw pad:pad];
    [sv addSubview:l3];
    y += 22;
    UILabel *lv = [[UILabel alloc] initWithFrame:CGRectMake(pad, y, iw, 120)];
    lv.numberOfLines = 0;
    lv.font = [UIFont systemFontOfSize:10];
    lv.textColor = [UIColor colorWithRed:0.6 green:0.95 blue:0.6 alpha:1];
    lv.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1];
    lv.text = [self logText];
    [sv addSubview:lv];
    self.logLabel = lv;
    y += 126;
    YBSetTrace("panel:6 日志区");
    YBLogSync(@"[面板] 6 日志区 OK");

    sv.contentSize = CGSizeMake(w, y + 14);

    self.logTimer = [NSTimer timerWithTimeInterval:1.5 target:self selector:@selector(tickLog) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.logTimer forMode:NSRunLoopCommonModes];
    YBSetTrace("panel:7 定时器");
    YBLogSync(@"[面板] 7 定时器 OK");
}

- (NSString *)logText {
    NSArray<NSString *> *t = YBLogTail(12);
    return t ? [t componentsJoinedByString:@"\n"] : @"";
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