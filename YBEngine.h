#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
extern NSString *const YBEngineRunStateChanged; // userInfo["running"] = @(BOOL)

// 流程编排：每一步 = 找文字 -> 点 / 输入 -> 等目标文字出现。
// 全部用「文字锚点」而非坐标，元宝改版/换机型都不用改坐标。
@interface YBEngine : NSObject
+ (instancetype)shared;

@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL keepForeground;  // 调试：跑完不自动收尾

- (void)warmUp;                 // 预热 Vision
- (void)scheduleDailyTimer;     // 每天按配置时间自动跑

// 任务：checkin / ask / write / photo / pimage / tpl / all / auto
- (void)runTasks:(NSArray<NSString *> *)tasks
           count:(NSInteger)count
            auto:(BOOL)autoFill;

- (void)stop;                   // 请求停止（下一检查点生效）

// 自检：只做"截图 -> OCR -> 找福利中心 -> 点一下 -> 回读屏幕文字"这一条最小链路，
// 用来把"点执行就闪"拆开定位：这一步崩就是截图/OCR 的问题，不崩就是任务流程的问题。
- (void)selfTest;
- (void)testCapture;   // 只截图
- (void)testOCR;       // 截图 + OCR（已废弃：Vision 在本进程会崩，仅留作取证）
- (void)testTextTree;  // 只取视图树里的文字（判断能不能完全不依赖 OCR）
- (void)probeWelfare;  // 点进福利中心并把页面全部文字打出来（校准锚点用）
- (void)diagnoseWelfare; // 诊断「福利中心」每个候选的位置/可点性/点击效果
- (void)autoWelfare;    // 真正干活：进福利中心 -> 打卡 -> 领奖励（纯视图树/H5，手动触发）
- (void)probeWeb;       // 只读 H5 页面文字（判断福利中心是不是 WebView）
@end
NS_ASSUME_NONNULL_END