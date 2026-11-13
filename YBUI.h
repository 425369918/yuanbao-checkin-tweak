#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface YBUI : NSObject
+ (void)install;      // 在主窗口挂上悬浮球
+ (void)showPanel;
+ (void)showCrashReplay:(NSArray<NSString *> *)lines;   // 上次没跑完：自动开面板摊出崩溃前日志
@end
NS_ASSUME_NONNULL_END