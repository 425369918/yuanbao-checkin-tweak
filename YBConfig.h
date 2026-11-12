#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@class YBStep;

@interface YBConfig : NSObject
+ (void)registerDefaults;
// 设置（存 NSUserDefaults）
+ (NSInteger)fireHour;
+ (NSInteger)fireMinute;
+ (void)setFireHour:(NSInteger)h minute:(NSInteger)m;
+ (NSTimeInterval)stepGap;
+ (void)setStepGap:(NSTimeInterval)g;
+ (BOOL)autoTopup;
+ (void)setAutoTopup:(BOOL)v;
+ (NSArray<NSString *> *)enabledTasks;
+ (void)setEnabledTasks:(NSArray<NSString *> *)t;

+ (BOOL)autoRunOnLaunch;
+ (void)setAutoRunOnLaunch:(BOOL)v;
+ (NSString *)lastRunDay;          // "yyyy-MM-dd"，用于每天只自动跑一次
+ (void)setLastRunDay:(NSString *)day;
+ (BOOL)hasRunToday;
+ (void)markRunToday;

+ (NSDate *)nextFireDate;
+ (NSArray<NSString *> *)allTasks;                 // ask,write,photo,pimage,tpl,checkin
+ (NSString *)displayNameFor:(NSString *)task;
+ (NSArray<YBStep *> *)stepsForTask:(NSString *)task;

// 用户自定义的“文字锚点”覆盖（录制来的），key 形如 @"write.send"
+ (NSArray<NSString *> *)aliasesFor:(NSString *)slot defaults:(NSArray<NSString *> *)defs;
+ (void)setAliases:(NSArray<NSString *> *)a forSlot:(NSString *)slot;
+ (void)resetAliases;
@end
NS_ASSUME_NONNULL_END