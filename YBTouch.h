#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// 进程内“点按”：不走 root/input，直接命中视图树触发控件/手势。
@interface YBTouch : NSObject
+ (UIWindow *)keyWindow;                            // 尽量拿到 App 自己的那个窗口
+ (void)registerOwnWindow:(UIWindow *)w;            // 把自己的悬浮窗登记进来，永远不当作 App 窗口
+ (void)setOwnOverlaysHidden:(BOOL)hidden;          // 截图时临时藏起自己的浮窗
+ (void)logDiagnostics;                             // 打一行环境/窗口/控件诊断到日志（排查用）
+ (BOOL)tapPoint:(CGPoint)pt;                       // 命中控件并触发
+ (BOOL)tapText:(NSArray<NSString *> *)keys;        // 视图树里按文字找控件并点
+ (BOOL)inputText:(NSString *)text nearKeys:(NSArray<NSString *> *)keys; // 找输入框并写入
+ (id)findViewWithText:(NSArray<NSString *> *)keys; // 返回命中视图（调试）
+ (NSArray<NSString *> *)dumpVisibleTexts;          // 当前屏幕可见文字（调试/录制）
@end
NS_ASSUME_NONNULL_END