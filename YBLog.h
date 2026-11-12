#import <Foundation/Foundation.h>
void YBLogBootstrap(void);
void YBLog(NSString *fmt, ...);
NSString *YBLogFilePath(void);
NSArray<NSString *> *YBLogTail(NSUInteger n);
void YBLogClear(void);
void YBLogFlush(void);                   // 等队列里未落盘的内容写完
void YBLogSync(NSString *fmt, ...);      // 同步写，立刻落盘（崩了也不丢）
void YBLogEnableCrashHandler(void);      // 未捕获异常写进日志（含调用栈）
void YBSetTrace(const char *step);       // 标记"进行到哪一步"（信号崩溃时一起写出）
void YBLogInstallSignalHandlers(void);   // SIGSEGV/SIGABRT/SIGBUS… 写进日志再退出
