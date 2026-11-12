#import "YBStep.h"
@implementation YBStep
+ (instancetype)tap:(NSArray *)k { YBStep *s=[YBStep new]; s.kind=YBStepTapText; s.keys=k; return s; }
+ (instancetype)tapOCR:(NSArray *)k { YBStep *s=[YBStep new]; s.kind=YBStepTapOCR; s.keys=k; return s; }
+ (instancetype)input:(NSString *)t at:(NSArray *)k { YBStep *s=[YBStep new]; s.kind=YBStepInputText; s.keys=k; s.text=t; return s; }
+ (instancetype)wait:(NSArray *)k secs:(NSTimeInterval)t { YBStep *s=[YBStep new]; s.kind=YBStepWait; s.keys=k; s.seconds=t; return s; }
+ (instancetype)sleep:(NSTimeInterval)t { YBStep *s=[YBStep new]; s.kind=YBStepSleep; s.seconds=t; return s; }
@end