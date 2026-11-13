#import "YBWeb.h"
#import "YBTouch.h"
#import "YBLog.h"
#import <WebKit/WebKit.h>

// 一个 App 里可能同时有好几个 WKWebView：
//   · 顶部轮播/广告位（"规则 / AI精讲 / 思路没搞懂" 这种）
//   · 福利中心正文（"元宝能力站 / 已打卡 / 每日任务 / 去邀请"）
// 只取第一个会抓错，所以这里把全部列出来，再按"正文关键词 + 面积"挑出对的那个。

static NSString * const kYBWebTextJS = @"(function(){try{return (document.body.innerText||'').slice(0,2000);}catch(e){return 'ERR:'+e;}})()";

static BOOL gYBWebQuiet = NO;   // 点按钮期间静音，免得零碎日志把关键结果挤出面板

@implementation YBWeb

+ (void)setQuiet:(BOOL)q { gYBWebQuiet = q; }

+ (NSString *)fullText {
    UIView *v = [self bestWeb];
    if (!v) return nil;
    return [self syncJS:kYBWebTextJS in:(WKWebView *)v];
}

+ (void)resetCache { /* 预留：目前不缓存，避免页面跳转后拿到失效指针 */ }

+ (NSArray<UIView *> *)webViews {
    if ([NSThread isMainThread]) return [self webViewsOnMain];
    __block NSArray<UIView *> *r = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { r = [self webViewsOnMain]; } @catch (NSException *e) { YBLogSync(@"[H5] 找 WebView 异常: %@", e.reason); }
    });
    return r ?: @[];
}

+ (NSArray<UIView *> *)webViewsOnMain {
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    for (UIWindow *w in [YBTouch appWindows]) {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger visits = 0;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
        while (q.count) {
            if (visits++ > 20000) break;
            if ((visits & 511) == 0 && [deadline timeIntervalSinceNow] < 0) break;
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            @try {
                if ([v isKindOfClass:WKWebView.class] || [v isKindOfClass:NSClassFromString(@"UIWebView")]) {
                    if (!v.hidden && v.alpha > 0.01 && !v.window.hidden) [found addObject:v];
                }
            } @catch (NSException *e) { }
            for (UIView *s in v.subviews) [q addObject:s];
        }
    }
    return found;
}

// 按"屏幕面积从大到小"排：福利中心正文页一定比顶部轮播大
+ (NSArray<UIView *> *)webViewsByArea {
    NSArray<UIView *> *all = [self webViews];
    __block NSArray<UIView *> *sorted = nil;
    dispatch_block_t run = ^{
        sorted = [all sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            CGFloat aa = a.bounds.size.width * a.bounds.size.height;
            CGFloat ab = b.bounds.size.width * b.bounds.size.height;
            if (aa == ab) return NSOrderedSame;
            return aa > ab ? NSOrderedAscending : NSOrderedDescending;
        }];
    };
    if ([NSThread isMainThread]) run();
    else dispatch_sync(dispatch_get_main_queue(), run);
    return sorted ?: @[];
}

+ (NSString *)syncJS:(NSString *)js in:(WKWebView *)wv {
    if (!js.length || !wv) return nil;
    __block NSString *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [wv evaluateJavaScript:js completionHandler:^(id obj, NSError *err) {
                if ([obj isKindOfClass:NSString.class]) result = obj;
                else if (obj) result = [obj description];
                if (err) YBLogSync(@"[H5] JS 报错: %@", err.localizedDescription);
                dispatch_semaphore_signal(sem);
            }];
        } @catch (NSException *e) {
            YBLogSync(@"[H5] 执行 JS 异常: %@", e.reason);
            dispatch_semaphore_signal(sem);
        }
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC))) != 0) {
        YBLogSync(@"[H5] JS 超时（2 秒没返回）");
        return nil;
    }
    return result;
}

// 挑"福利中心正文"那个 WebView：正文里得有任务/积分相关字样，否则退化成面积最大的
+ (UIView *)bestWeb {
    NSArray<UIView *> *sorted = [self webViewsByArea];
    if (!sorted.count) return nil;
    NSArray<NSString *> *marks = @[@"每日任务", @"打卡", @"签到", @"去邀请", @"积分", @"兑换"];
    for (UIView *v in sorted) {
        NSString *t = [self syncJS:kYBWebTextJS in:(WKWebView *)v];
        if (!t.length) continue;
        for (NSString *m in marks) {
            if ([t containsString:m]) {
                if (!gYBWebQuiet) YBLogSync(@"[H5] 选中正文 %.0fx%.0f（命中「%@」）", v.bounds.size.width, v.bounds.size.height, m);
                return v;
            }
        }
    }
    if (!gYBWebQuiet) YBLogSync(@"[H5] 没有 WebView 命中任务关键词，退回面积最大的那个");
    return sorted.firstObject;
}

+ (NSString *)textOfFirstWeb {
    UIView *v = [self bestWeb];
    return v ? [self syncJS:kYBWebTextJS in:(WKWebView *)v] : nil;
}

// 扫"像按钮"的元素：文字短、有尺寸、显示着
static NSString * const kYBWebBtnJS =
 @"(function(){try{var all=document.querySelectorAll('*');var out=[];var n=0;"
  "for(var i=0;i<all.length;i++){var e=all[i];var t=(e.innerText||'').trim();"
  "if(!t||t.length>14)continue;var r=e.getBoundingClientRect();"
  "if(r.width<24||r.height<12)continue;if(r.bottom<0||r.top>2000)continue;"
  "out.push(t);if(++n>=30)break;}return out.join(' | ');}catch(e){return 'ERR:'+e;}})()";

// 点按钮：先找"文字完全等于关键词"的（最准），找不到再退化成"包含"匹配，
// 都会挑面积最小的那个（最深/最精确的元素）；click 不生效时补发 touchstart/touchend。
// 注意排除「已打卡 / 已完成 / 距结束…」这类"状态文字"，它们不是按钮。
static NSString * const kYBWebClickJS =
 @"(function(keys){try{var all=document.querySelectorAll('*');"
  "var ex=null,ea=1e9,ext='',co=null,ca=1e9,cot='';"
  "var bad=['已打卡','已完成','距结束','个新用户','领取过','明天再来'];"
  "for(var i=0;i<all.length;i++){var e=all[i];var t=(e.innerText||'').trim();"
  "if(!t||t.length>16)continue;var r=e.getBoundingClientRect();"
  "if(r.width<24||r.height<12)continue;"
  "for(var b=0;b<bad.length;b++){if(t.indexOf(bad[b])>=0){t='';break;}}"
  "if(!t)continue;"
  "var a=r.width*r.height;"
  "for(var k=0;k<keys.length;k++){var key=keys[k];"
  "if(t===key){if(a<ea){ea=a;ex=e;ext=t;}break;}"
  "if(t.indexOf(key)>=0){if(a<ca){ca=a;co=e;cot=t;}}}}"
  "var best=ex||co;var bt=ex?ext:cot;"
  "if(!best)return 'notfound';var rr=best.getBoundingClientRect();"
  "var x=rr.left+rr.width/2,y=rr.top+rr.height/2;"
  "try{best.click();}catch(e){}"
  "try{var ev=function(n){var t=new Touch({identifier:1,target:best,clientX:x,clientY:y});"
  "best.dispatchEvent(new TouchEvent(n,{bubbles:true,cancelable:true,touches:n=='touchend'?[]:[t],"
  "targetTouches:n=='touchend'?[]:[t],changedTouches:[t]}));};"
  "ev('touchstart');ev('touchend');}catch(e2){}"
  "return (ex?'exact:':'fuzzy:')+bt.slice(0,14)+'@'+Math.round(x)+','+Math.round(y);"
  "}catch(err){return 'ERR:'+err;}})";

+ (NSString *)jsArgsFromKeys:(NSArray<NSString *> *)keys {
    NSMutableArray *q = [NSMutableArray array];
    for (NSString *k in keys) {
        NSString *e = [k stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        e = [e stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        e = [e stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [q addObject:[NSString stringWithFormat:@"\"%@\"", e]];
    }
    return [NSString stringWithFormat:@"[%@]", [q componentsJoinedByString:@","]];
}

+ (BOOL)clickContaining:(NSArray<NSString *> *)keys in:(UIView *)wv {
    if (!wv || !keys.count) return NO;
    NSString *js = [NSString stringWithFormat:@"%@(%@)", kYBWebClickJS, [self jsArgsFromKeys:keys]];
    if (!gYBWebQuiet) YBLogSync(@"[H5] 试「%@」", YBJoinKeys(keys));
    NSString *r = [self syncJS:js in:(WKWebView *)wv];
    if (!gYBWebQuiet) YBLogSync(@"[H5] -> %@", r ?: @"(无返回)");
    if (!r || [r hasPrefix:@"ERR"] || [r isEqualToString:@"notfound"]) return NO;
    [NSThread sleepForTimeInterval:1.2];
    return YES;
}

+ (void)logClickables {
    UIView *best = [self bestWeb];
    if (!best) { YBLogSync(@"[H5] 没有 WebView，列不出按钮"); return; }
    NSString *r = [self syncJS:kYBWebBtnJS in:(WKWebView *)best];
    if (!r.length) { YBLogSync(@"[H5可点] (空)"); return; }
    NSArray *parts = [r componentsSeparatedByString:@" | "];
    NSMutableString *line = [NSMutableString string];
    NSInteger n = 0;
    for (NSString *p in parts) {
        if (n == 5) { YBLogSync(@"[H5可点] %@", line); [line setString:@""]; n = 0; }
        [line appendFormat:@"%@ | ", p];
        n++;
    }
    if (line.length) YBLogSync(@"[H5可点] %@", line);
}

+ (NSArray<NSString *> *)textAround:(NSString *)key span:(NSInteger)span {
    NSString *t = [self textOfFirstWeb];
    if (!t.length || !key.length) return @[];
    NSString *flat = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSMutableArray *out = [NSMutableArray array];
    NSRange search = NSMakeRange(0, flat.length);
    while (search.length) {
        NSRange r = [flat rangeOfString:key options:0 range:search];
        if (r.location == NSNotFound) break;
        NSUInteger from = (r.location >= (NSUInteger)span) ? r.location - (NSUInteger)span : 0;
        NSUInteger to = MIN(flat.length, NSMaxRange(r) + (NSUInteger)span);
        [out addObject:[flat substringWithRange:NSMakeRange(from, to - from)]];
        NSUInteger next = NSMaxRange(r);
        if (next >= flat.length) break;
        search = NSMakeRange(next, flat.length - next);
    }
    return out;
}

+ (void)logSummary {
    NSArray<UIWindow *> *wins = [YBTouch appWindows];
    YBLogSync(@"[H5] App 窗口 %lu 个", (unsigned long)wins.count);
    for (UIWindow *w in wins) {
        YBLogSync(@"[H5] 窗口 %@ %.0fx%.0f level=%.0f", NSStringFromClass(w.class),
                  w.bounds.size.width, w.bounds.size.height, w.windowLevel);
    }

    NSArray<UIView *> *sorted = [self webViewsByArea];
    YBLogSync(@"[H5] 找到 %lu 个 WebView", (unsigned long)sorted.count);
    if (!sorted.count) { YBLogSync(@"[H5] 没有 WebView —— 这个页面不是 H5"); return; }

    NSInteger idx = 0;
    for (UIView *v in sorted) {
        CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
        NSString *t = [self syncJS:kYBWebTextJS in:(WKWebView *)v];
        NSString *flat = [[t stringByReplacingOccurrencesOfString:@"\n" withString:@" "] ?: @"" copy];
        NSString *head = flat.length ? [flat substringToIndex:MIN(flat.length, (NSUInteger)70)] : @"(读不到)";
        YBLogSync(@"[H5] #%ld 尺寸=%.0fx%.0f 正文=%lu字 开头: %@", (long)++idx, w, h,
                  (unsigned long)t.length, head);
    }

    UIView *best = [self bestWeb];
    if (!best) return;
    NSString *txt = [self syncJS:kYBWebTextJS in:(WKWebView *)best];
    if (!txt.length) { YBLogSync(@"[H5] 正文那个 WebView 也读不到"); return; }
    NSString *flat = [txt stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSUInteger len = MIN(flat.length, (NSUInteger)900);
    NSString *cut = [flat substringToIndex:len];
    for (NSUInteger i = 0; i < cut.length; i += 60) {
        NSUInteger l = MIN((NSUInteger)60, cut.length - i);
        YBLogSync(@"[H5正文] %@", [cut substringWithRange:NSMakeRange(i, l)]);
    }
}

+ (NSString *)textSignature {
    NSString *t = [self textOfFirstWeb];
    if (!t) return @"(无)";
    return [NSString stringWithFormat:@"%lu", (unsigned long)t.length];
}

+ (NSString *)tapTextVerbose:(NSArray<NSString *> *)keys {
    NSArray<UIView *> *sorted = [self webViewsByArea];
    if (!sorted.count) return @"no-webview";
    UIView *best = [self bestWeb];
    NSMutableArray<UIView *> *order = [NSMutableArray array];
    if (best) [order addObject:best];
    for (UIView *v in sorted) if (v != best) [order addObject:v];

    NSString *js = [NSString stringWithFormat:@"%@(%@)", kYBWebClickJS, [self jsArgsFromKeys:keys]];
    NSString *last = @"notfound";
    for (UIView *v in order) {
        NSString *r = [self syncJS:js in:(WKWebView *)v];
        if (!r) continue;
        last = r;
        if (![r hasPrefix:@"ERR"] && ![r isEqualToString:@"notfound"]) {
            [NSThread sleepForTimeInterval:1.2];
            return r;
        }
    }
    return last;
}

+ (BOOL)tapText:(NSArray<NSString *> *)keys {
    NSString *r = [self tapTextVerbose:keys];
    return !([r hasPrefix:@"ERR"] || [r isEqualToString:@"notfound"] || [r isEqualToString:@"no-webview"]);
}

@end
