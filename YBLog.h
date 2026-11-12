#import <Foundation/Foundation.h>
void YBLogBootstrap(void);
void YBLog(NSString *fmt, ...);
NSString *YBLogFilePath(void);
NSArray<NSString *> *YBLogTail(NSUInteger n);
void YBLogClear(void);
void YBLogFlush(void);                 // 等待队列里未落盘的内容写完
void YBLogEnableCrashHandler(void);    // 未捕获异常写进日志（含调用栈）
