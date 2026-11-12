#import <Foundation/Foundation.h>
void YBLogBootstrap(void);
void YBLog(NSString *fmt, ...);
NSString *YBLogFilePath(void);
NSArray<NSString *> *YBLogTail(NSUInteger n);
void YBLogClear(void);