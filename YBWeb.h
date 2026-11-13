#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// 元宝的「能力站/福利中心」是 H5 页面：UIKit 层级里只有「返回」一个控件，
// 页面正文全在 WKWebView 里。所以这里直接读 WebView 的文字、按文字点元素。
// 好处：不需要 OCR、不需要坐标，H5 里点什么都能精确命中。
@interface YBWeb : NSObject
+ (NSArray<UIView *> *)webViews;                       // App 窗口里所有 WebView（已跳过自己的浮窗）
+ (NSArray<UIView *> *)webViewsOnMain;                 // 同上，但要求在主线程调用
+ (NSArray<UIView *> *)webViewsByArea;                 // 同上，按屏幕面积从大到小排
+ (UIView *)bestWeb;                                   // 挑"正文那个"（按任务关键词，其次按面积）
+ (void)logSummary;                                    // 打日志：找到几个、正文前 400 字、可点元素清单
+ (NSString *)textOfFirstWeb;                          // 第一个 WebView 的正文（失败返回 nil）
+ (BOOL)tapText:(NSArray<NSString *> *)keys;           // 在 H5 里按文字点元素（点完校验正文变化）
+ (NSString *)textSignature;                            // 正文指纹（判断点击有没有生效）
@end
NS_ASSUME_NONNULL_END
