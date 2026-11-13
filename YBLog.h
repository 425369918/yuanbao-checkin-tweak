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

// 上一次进程是不是"没跑完就没了"（信号崩溃 / 被系统杀 / 未捕获异常）。
// 用来在下次启动时自动把崩溃前的日志摊到面板上，省得用户还要自己去翻文件。
BOOL YBLastRunUnfinished(void);
NSArray<NSString *> *YBLastRunLogTail(NSUInteger n);   // 上一个进程那一段日志的末尾
