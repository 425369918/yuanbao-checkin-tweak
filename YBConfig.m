#import "YBConfig.h"
#import "YBStep.h"
#import "YBLog.h"

// 每个“文字锚点”给一组别名，命中任意一个即可 —— 这是“元宝改版也能用”的关键
static NSDictionary<NSString *, NSArray<NSString *> *> *YBDefaultSlots(void) {
    return @{
        @"entry.welfare":   @[@"福利中心", @"福利", @"我的福利"],
        @"entry.checkin":   @[@"能力站", @"签到", @"今日签到"],
        @"ask.entry":       @[@"趣问元宝", @"趣问", @"去提问", @"问元宝"],
        @"ask.quickq":      @[@"推荐问题", @"换个问题", @"换一题"],
        @"write.entry":     @[@"使用写作能力", @"去写作", @"写作", @"写文章"],
        @"write.input":     @[@"输入话题", @"请输入", @"输入你想写", @"话题"],
        @"write.send":      @[@"发送", @"生成", @"开始写作", @"立即生成"],
        @"photo.entry":     @[@"使用拍题能力", @"去拍题", @"拍题", @"解题"],
        @"photo.gallery":   @[@"相册", @"从相册选择", @"选择图片"],
        @"photo.submit":    @[@"提交", @"确认", @"发送", @"开始解题"],
        @"pimage.entry":    @[@"使用P图能力", @"去P图", @"P图", @"修图"],
        @"pimage.pick":     @[@"相册", @"选择图片", @"从相册选择"],
        @"pimage.send":     @[@"发送", @"生成", @"开始P图", @"确定"],
        @"tpl.entry":       @[@"推荐模板", @"做同款", @"模板做同款", @"去体验"],
        @"tpl.tab":         @[@"模板广场", @"模板", @"广场"],
        @"tpl.same":        @[@"做同款", @"使用同款", @"同款"],
        @"tpl.gen":         @[@"生成", @"开始生成", @"立即体验"],
        @"common.reward":   @[@"开心收下", @"收下", @"领取", @"确定", @"知道了"],
        @"common.back":     @[@"返回", @"关闭", @"完成"],
    };
}

static NSString *const kHour = @"yb.fireHour";
static NSString *const kMin  = @"yb.fireMinute";
static NSString *const kGap  = @"yb.stepGap";
static NSString *const kTopup= @"yb.autoTopup";
static NSString *const kTasks= @"yb.enabledTasks";
static NSString *const kAlias= @"yb.slotAliases";

// 用户录制覆盖 + 默认别名
static NSArray<NSString *> *AY(NSString *slot) {
    [YBConfig registerDefaults];
    NSDictionary *map = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAlias];
    NSMutableArray *out = [NSMutableArray array];
    NSArray *custom = map[slot];
    if (custom.count) [out addObjectsFromArray:custom];
    [out addObjectsFromArray:YBDefaultSlots()[slot] ?: @[]];
    return out;
}

// 每项任务前先回福利中心，保证状态干净
static NSArray<YBStep *> *YBNavWelfare(void) {
    return @[ [YBStep tap:AY(@"entry.welfare")],
              [YBStep tapOCR:AY(@"entry.welfare")],
              [YBStep wait:AY(@"entry.welfare") secs:4.0],
              [YBStep sleep:1.0] ];
}

@implementation YBConfig

+ (void)registerDefaults {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kHour: @0, kMin: @5, kGap: @0.9, kTopup: @NO,
            kTasks: @[@"checkin",@"ask",@"write",@"photo",@"pimage",@"tpl"],@"yb.autoRunOnLaunch": @YES,
            kAlias: @{},
        }];
    });
}

+ (NSInteger)fireHour   { [self registerDefaults]; return [[NSUserDefaults standardUserDefaults] integerForKey:kHour]; }
+ (NSInteger)fireMinute { [self registerDefaults]; return [[NSUserDefaults standardUserDefaults] integerForKey:kMin]; }
+ (void)setFireHour:(NSInteger)h minute:(NSInteger)m {
    [self registerDefaults];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:h forKey:kHour]; [d setInteger:m forKey:kMin];
}
+ (NSTimeInterval)stepGap { [self registerDefaults]; return [[NSUserDefaults standardUserDefaults] doubleForKey:kGap]; }
+ (void)setStepGap:(NSTimeInterval)g { [self registerDefaults]; [[NSUserDefaults standardUserDefaults] setDouble:g forKey:kGap]; }
+ (BOOL)autoTopup { [self registerDefaults]; return [[NSUserDefaults standardUserDefaults] boolForKey:kTopup]; }
+ (void)setAutoTopup:(BOOL)v { [self registerDefaults]; [[NSUserDefaults standardUserDefaults] setBool:v forKey:kTopup]; }
+ (NSArray<NSString *> *)enabledTasks {
    [self registerDefaults];
    NSArray *t = [[NSUserDefaults standardUserDefaults] arrayForKey:kTasks];
    return t.count ? t : @[@"checkin",@"ask",@"write",@"photo",@"pimage",@"tpl"];
}
+ (void)setEnabledTasks:(NSArray<NSString *> *)t { [self registerDefaults]; [[NSUserDefaults standardUserDefaults] setObject:t forKey:kTasks]; }

+ (BOOL)autoRunOnLaunch { [self registerDefaults]; return [[NSUserDefaults standardUserDefaults] boolForKey:@"yb.autoRunOnLaunch"]; }
+ (void)setAutoRunOnLaunch:(BOOL)v { [[NSUserDefaults standardUserDefaults] setBool:v forKey:@"yb.autoRunOnLaunch"]; }
+ (NSString *)lastRunDay { return [[NSUserDefaults standardUserDefaults] stringForKey:@"yb.lastRunDay"] ?: @""; }
+ (void)setLastRunDay:(NSString *)day { [[NSUserDefaults standardUserDefaults] setObject:day forKey:@"yb.lastRunDay"]; }
+ (BOOL)hasRunToday {
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd";
    return [[self lastRunDay] isEqualToString:[f stringFromDate:[NSDate date]]];
}
+ (void)markRunToday {
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyy-MM-dd";
    [self setLastRunDay:[f stringFromDate:[NSDate date]]];
}

+ (NSDate *)nextFireDate {
    NSCalendar *cal = NSCalendar.currentCalendar;
    NSDate *now = [NSDate date];
    NSDateComponents *c = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay) fromDate:now];
    c.hour = [self fireHour]; c.minute = [self fireMinute]; c.second = 0;
    NSDate *fire = [cal dateFromComponents:c];
    if ([fire timeIntervalSinceDate:now] <= 0) { c.day += 1; fire = [cal dateFromComponents:c]; }
    return fire;
}

+ (NSArray<NSString *> *)allTasks { return @[@"ask",@"write",@"photo",@"pimage",@"tpl",@"checkin"]; }

+ (NSString *)displayNameFor:(NSString *)t {
    NSDictionary *m = @{@"checkin":@"能力站签到", @"ask":@"趣问元宝", @"write":@"使用写作能力",
                        @"photo":@"使用拍题能力", @"pimage":@"使用P图能力", @"tpl":@"推荐模板做同款"};
    return m[t] ?: t;
}

+ (NSArray<NSString *> *)aliasesFor:(NSString *)slot defaults:(NSArray<NSString *> *)defs {
    [self registerDefaults];
    NSDictionary *map = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kAlias];
    NSMutableArray *out = [NSMutableArray array];
    NSArray *custom = map[slot];
    if (custom.count) [out addObjectsFromArray:custom];
    [out addObjectsFromArray:defs ?: @[]];
    return out;
}
+ (void)setAliases:(NSArray<NSString *> *)a forSlot:(NSString *)slot {
    [self registerDefaults];
    NSMutableDictionary *map = [([NSUserDefaults.standardUserDefaults dictionaryForKey:kAlias] ?: @{}) mutableCopy];
    map[slot] = a ?: @[];
    [[NSUserDefaults standardUserDefaults] setObject:map forKey:kAlias];
}
+ (void)resetAliases { [[NSUserDefaults standardUserDefaults] removeObjectForKey:kAlias]; }

// ============ 任务步骤定义（全部文字锚点，无坐标） ============


+ (NSArray<YBStep *> *)stepsForTask:(NSString *)task {
    NSMutableArray *s = [NSMutableArray arrayWithArray:YBNavWelfare()];

    if ([task isEqualToString:@"checkin"]) {
        [s addObjectsFromArray:@[
            [YBStep tap:AY(@"entry.checkin")],
            [YBStep tapOCR:AY(@"entry.checkin")],
            [YBStep sleep:2.0],
            [YBStep tap:AY(@"common.reward")],
            [YBStep sleep:1.5],
        ]];
    } else if ([task isEqualToString:@"ask"]) {
        [s addObjectsFromArray:@[
            [YBStep tap:AY(@"ask.entry")],
            [YBStep wait:@[@"提问", @"问题", @"输入"] secs:6.0],
            [YBStep tapOCR:AY(@"ask.quickq")],
            [YBStep sleep:1.5],
            [YBStep tap:AY(@"write.send")],
            [YBStep tapOCR:AY(@"write.send")],
            [YBStep sleep:3.0],
            [YBStep tap:AY(@"common.reward")],
            [YBStep sleep:1.5],
        ]];
    } else if ([task isEqualToString:@"write"]) {
        [s addObjectsFromArray:@[
            [YBStep tap:AY(@"write.entry")],
            [YBStep wait:AY(@"write.input") secs:6.0],
            [YBStep input:@"写一段关于健康生活的短文" at:AY(@"write.input")],
            [YBStep sleep:1.0],
            [YBStep tap:AY(@"write.send")],
            [YBStep tapOCR:AY(@"write.send")],
            [YBStep sleep:3.0],
            [YBStep tap:AY(@"common.reward")],
            [YBStep sleep:1.5],
        ]];
    } else if ([task isEqualToString:@"photo"]) {
        [s addObjectsFromArray:@[
            [YBStep tap:AY(@"photo.entry")],
            [YBStep wait:@[@"相册", @"拍照", @"题目"] secs:6.0],
            [YBStep tap:AY(@"photo.gallery")],
            [YBStep tapOCR:AY(@"photo.gallery")],
            [YBStep sleep:2.5],
            [YBStep tapOCR:@[@"最近项目", @"所有照片", @"照片"]],
            [YBStep sleep:1.2],
            [YBStep tap:AY(@"photo.submit")],
            [YBStep tapOCR:AY(@"photo.submit")],
            [YBStep sleep:4.0],
            [YBStep tap:AY(@"common.reward")],
            [YBStep sleep:1.5],
        ]];
    } else if ([task isEqualToString:@"pimage"]) {
        [s addObjectsFromArray:@[
            [YBStep tap:AY(@"pimage.entry")],
            [YBStep wait:@[@"相册", @"图片", @"选择"] secs:6.0],
            [YBStep tap:AY(@"pimage.pick")],
            [YBStep tapOCR:AY(@"pimage.pick")],
            [YBStep sleep:2.5],
            [YBStep tapOCR:@[@"最近项目", @"所有照片", @"照片"]],
            [YBStep sleep:1.2],
            [YBStep tap:AY(@"pimage.send")],
            [YBStep tapOCR:AY(@"pimage.send")],
            [YBStep sleep:6.0],
            [YBStep tap:AY(@"common.reward")],
            [YBStep sleep:1.5],
        ]];
    } else if ([task isEqualToString:@"tpl"]) {
        [s addObjectsFromArray:@[
            [YBStep tap:AY(@"tpl.entry")],
            [YBStep wait:AY(@"tpl.tab") secs:6.0],
            [YBStep tap:AY(@"tpl.same")],
            [YBStep tapOCR:AY(@"tpl.same")],
            [YBStep sleep:2.0],
            [YBStep tap:AY(@"tpl.gen")],
            [YBStep tapOCR:AY(@"tpl.gen")],
            [YBStep sleep:6.0],
            [YBStep tap:AY(@"common.reward")],
            [YBStep sleep:1.5],
        ]];
    }
    return s;
}

@end