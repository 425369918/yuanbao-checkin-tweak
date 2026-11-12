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
@end
NS_ASSUME_NONNULL_END