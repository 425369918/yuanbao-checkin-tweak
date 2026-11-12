#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YBStepKind) {
    YBStepTapText,     // 视图树里按文字找控件并点（首选）
    YBStepTapOCR,      // OCR 找文字后按坐标点（视图树没文字时兜底）
    YBStepInputText,   // 在关键字命中的输入框写入文本
    YBStepWait,        // 等某文字出现
    YBStepSleep,       // 固定延迟
};

@interface YBStep : NSObject
@property (nonatomic, assign) YBStepKind kind;
@property (nonatomic, copy) NSArray<NSString *> *keys;
@property (nonatomic, copy, nullable) NSString *text;
@property (nonatomic, assign) NSTimeInterval seconds;
+ (instancetype)tap:(NSArray<NSString *> *)keys;
+ (instancetype)tapOCR:(NSArray<NSString *> *)keys;
+ (instancetype)input:(NSString *)text at:(NSArray<NSString *> *)keys;
+ (instancetype)wait:(NSArray<NSString *> *)keys secs:(NSTimeInterval)t;
+ (instancetype)sleep:(NSTimeInterval)t;
@end
NS_ASSUME_NONNULL_END