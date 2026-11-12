// ============================================================
//  腾讯元宝 · 福利中心每日任务（iOS / TrollStore 巨魔版）
//  纯 constructor 注入：不依赖 substrate / ellekit，任何注入器都能用。
// ============================================================
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <unistd.h>
#import "YBEngine.h"
#import "YBConfig.h"
#import "YBLog.h"
#import "YBUI.h"

// 元宝 iOS bundle id（随版本可能变，用前缀匹配兜底）
static NSArray<NSString *> *kYBBundleIDs(void) {
    return @[@"com.tencent.hunyuan.app.chat",
             @"com.tencent.hunyuan.app",
             @"com.tencent.yuanbao",
             @"com.tencent.hunyuan"];
}

static BOOL YBIsYuanbaoProcess(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    for (NSString *e in kYBBundleIDs()) {
        if ([bid isEqualToString:e] || [bid hasPrefix:e]) return YES;
    }
    NSString *exe = [NSBundle mainBundle].executablePath.lastPathComponent.lowercaseString ?: @"";
    return [exe containsString:@"hunyuan"] || [exe containsString:@"yuanbao"];
}

static void YBStartAfterLaunch(void) {
    // 通知与 5s 兜底两条路都可能进来，这里做全局幂等，避免重复装面板/排双定时器
    static BOOL gStarted = NO;
    if (gStarted) return;
    gStarted = YES;

    if (!YBIsYuanbaoProcess()) {
        YBLog(@"[跳过] 当前不是元宝进程: %@", [NSBundle mainBundle].bundleIdentifier);
        return;
    }
    YBLog(@"==================================================");
    YBLog(@"[启动] YuanbaoCheckin 已注入: %@ (iOS %@, %@)",
          [NSBundle mainBundle].bundleIdentifier,
          [UIDevice currentDevice].systemVersion,
          [UIDevice currentDevice].model);

    [[YBEngine shared] warmUp];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YBSetTrace("install:UI");
        [YBUI install];
        // ============ 手动模式：只装界面，什么都不自动跑 ============
        // 不排每日定时器、不在启动时补做任务；一切等你自己点「执行」。
        YBSetTrace("install:done");
        YBLogSync(@"[模式] 手动运行模式：进入元宝不会自动执行任务，请点悬浮球 → 执行");
    });
}

__attribute__((constructor))
static void YBTweakInit(void) {
    @autoreleasepool {
        YBLogBootstrap();
        YBLogEnableCrashHandler();   // 未捕获异常也写进日志，闪退能留痕
        YBLogInstallSignalHandlers(); // 野指针这类硬崩溃也留一行（含最后进行到哪步）
        YBSetTrace("constructor");

#ifdef YB_SAFE
        // ===== 安全版：只验证「注入 → 加载 → 写日志」，完全不碰 UI / 任务 =====
        YBLog(@"[安全版] dylib 已加载 pid=%d bundle=%@", getpid(),
              [NSBundle mainBundle].bundleIdentifier ?: @"?");
        YBLog(@"[安全版] 日志文件: %@", YBLogFilePath());
        YBLog(@"[安全版] 不装悬浮球、不建面板、不跑任务；能看到这几行就说明注入链路正常");
        YBLogFlush();
        return;
#else
        YBLog(@"[注入] dylib loaded, pid=%d", getpid());

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) { YBStartAfterLaunch(); }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ YBStartAfterLaunch(); });
#endif
    }
}