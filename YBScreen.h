#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// 一屏截图 + OCR 结果，纯进程内获取，不需要 root
@interface YBScreen : NSObject
+ (instancetype)capture;                       // 取当前窗口截图（主线程调用）
@property (nonatomic, strong) UIImage *image;   // 截图
@property (nonatomic, assign) CGSize pointSize; // 逻辑点尺寸
@property (nonatomic, assign) CGFloat scale;    // 像素/点
@property (nonatomic, copy)   NSArray<NSDictionary *> *lines; // 每行: text/rect/NSText
- (void)runOCR;                                 // Vision 中文 OCR（同步，可后台调）
// 找包含关键字的文字块中心点（点坐标）；没找到返回 CGPointZero
- (CGPoint)centerOfTextContaining:(NSArray<NSString *> *)keys;
- (NSArray<NSDictionary *> *)lineDicts;         // 调试用：所有行文字+矩形
@end
NS_ASSUME_NONNULL_END