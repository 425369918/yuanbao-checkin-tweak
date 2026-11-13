#import "YBWeb.h"
#import "YBTouch.h"
#import "YBLog.h"
#import <WebKit/WebKit.h>

// 一个 App 里可能同时有好几个 WKWebView：
//   · 顶部轮播/广告位（"规则 / AI精讲 / 思路没搞懂" 这种）
//   · 福利中心正文（"元宝能力站 / 已打卡 / 每日任务 / 兑换商城"）
// 只取第一个会抓错，所以这里把全部列出来，再按"正文关键词 + 面积"挑出对的那个。

@implementation YBWeb

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

static NSString * const kYBWebTextJS = @"(function(){try{return (document.body.innerText||'').slice(0,2000);}catch(e){return 'ERR:'+e;}})()";

// 挑"福利中心正文"那个 WebView：正文里得有任务/积分相关字样，否则退化成面积最大的
+ (UIView *)bestWeb {
    NSArray<UIView *> *sorted = [self webViewsByArea];
    if (!sorted.count) return nil;
    NSArray<NSString *> *marks = @[@"打卡", @"签到", @"积分", @"兑换", @"每日任务", @"奖品", @"福利"];
    for (UIView *v in sorted) {
        NSString *t = [self syncJS:kYBWebTextJS in:(WKWebView *)v];
        if (!t.length) continue;
        for (NSString *m in marks) {
            if ([t containsString:m]) {
                YBLogSync(@"[H5] 选中正文 %@（命中关键词「%@」）", NSStringFromClass(v.class), m);
                return v;
            }
        }
    }
    YBLogSync(@"[H5] 没有 WebView 命中任务关键词，退回面积最大的那个");
    return sorted.firstObject;
}

+ (NSString *)textOfFirstWeb {
    UIView *v = [self bestWeb];
    return v ? [self syncJS:kYBWebTextJS in:(WKWebView *)v] : nil;
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

    NSString *jsBtn = @"(function(){try{var q=document.querySelectorAll('button,a,div[role=button],span,div');var out=[];var n=0;for(var i=0;i<q.length;i++){var e=q[i];var t=(e.innerText||'').trim();if(!t||t.length>12)continue;var r=e.getBoundingClientRect();if(r.width<20||r.height<10)continue;out.push(t);if(++n>=40)break;}return out.join(' | ');}catch(e){return 'ERR:'+e;}})()";
    NSString *btns = [self syncJS:jsBtn in:(WKWebView *)best];
    YBLogSync(@"[H5可点] %@", btns.length ? btns : @"(空)");
}

+ (NSString *)textSignature {
    NSString *t = [self textOfFirstWeb];
    if (!t) return @"(无)";
    return [NSString stringWithFormat:@"%lu/%lu", (unsigned long)t.length, (unsigned long)t.hash];
}

+ (BOOL)tapText:(NSArray<NSString *> *)keys {
    NSArray<UIView *> *sorted = [self webViewsByArea];
    if (!sorted.count) { YBLogSync(@"[H5] 没有 WebView，跳过"); return NO; }

    NSMutableArray *quoted = [NSMutableArray array];
    for (NSString *k in keys) {
        NSString *esc = [k stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        esc = [esc stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        esc = [esc stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [quoted addObject:[NSString stringWithFormat:@"\"%@\"", esc]];
    }
    NSString *jsKeys = [quoted componentsJoinedByString:@","];

    NSString *js = [NSString stringWithFormat:
        @"(function(keys){try{"
         "var all=document.querySelectorAll('*');"
         "for(var i=0;i<keys.length;i++){var k=keys[i];"
         " for(var j=0;j<all.length;j++){var e=all[j];"
         "  var t=(e.innerText||e.textContent||'').trim();if(!t)continue;"
         "  if(t===k||(t.indexOf(k)===0&&t.length<=k.length+6)){"
         "   var r=e.getBoundingClientRect();if(r.width<10||r.height<8)continue;"
         "   var tag=e.tagName;"
         "   e.click();"
         "   return 'clicked:'+t.slice(0,16)+'|'+tag+'|'+Math.round(r.left)+','+Math.round(r.top);"
         "  }}}"
         "return 'notfound';}catch(err){return 'ERR:'+err;}})([%@])", jsKeys];

    // 先在"福利中心正文"那个里点；没点着就挨个再试（多 WebView 场景）
    UIView *best = [self bestWeb];
    NSMutableArray<UIView *> *order = [NSMutableArray array];
    if (best) [order addObject:best];
    for (UIView *v in sorted) if (v != best) [order addObject:v];

    NSString *before = [self textSignature];
    for (UIView *v in order) {
        NSString *r = [self syncJS:js in:(WKWebView *)v];
        YBLogSync(@"[H5] 在 %@x%.0f 里点「%@」-> %@", NSStringFromClass(v.class),
                  v.bounds.size.width, YBJoinKeys(keys), r ?: @"(无返回)");
        if (!r || [r hasPrefix:@"ERR"] || [r isEqualToString:@"notfound"]) continue;
        [NSThread sleepForTimeInterval:1.0];
        NSString *after = [self textSignature];
        BOOL changed = ![after isEqualToString:before];
        YBLogSync(@"[H5] 正文指纹 %@ -> %@ %@", before, after, changed ? @"（已变）" : @"（没变）");
        return changed;
    }
    return NO;
}

@end
