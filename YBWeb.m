#import "YBWeb.h"
#import "YBTouch.h"
#import "YBLog.h"
#import <WebKit/WebKit.h>

@implementation YBWeb

// 遍历 UIKit 必须在主线程：后台线程直接来会踩到 App 的渲染线程
+ (NSArray<UIView *> *)webViews {
    if ([NSThread isMainThread]) return [self webViewsOnMain];
    __block NSArray<UIView *> *r = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { r = [self webViewsOnMain]; } @catch (NSException *e) { YBLogSync(@"[H5] 找 WebView 异常: %@", e.reason); }
    });
    return r ?: @[];
}

// 在所有 App 窗口里找 WebView（WKWebView / UIWebView 都算）
+ (NSArray<UIView *> *)webViewsOnMain {
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    NSArray<UIWindow *> *wins = [YBTouch appWindows];
    for (UIWindow *w in wins) {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger visits = 0;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
        while (q.count) {
            if (visits++ > 20000) break;
            if ((visits & 511) == 0 && [deadline timeIntervalSinceNow] < 0) break;
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            @try {
                if ([v isKindOfClass:WKWebView.class] || [v isKindOfClass:NSClassFromString(@"UIWebView")]) {
                    if (!v.hidden && v.alpha > 0.01) [found addObject:v];
                }
            } @catch (NSException *e) { }
            for (UIView *s in v.subviews) [q addObject:s];
        }
    }
    return found;
}

// 同步执行 JS：WebKit 的回调永远在主线程，这里从后台线程等信号量，最多等 2 秒
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

+ (NSString *)textOfFirstWeb {
    NSArray *wv = [self webViews];
    if (!wv.count) return nil;
    NSString *js = @"(function(){try{return (document.body.innerText||'').slice(0,2000);}catch(e){return 'ERR:'+e;}})()";
    return [self syncJS:js in:wv.firstObject];
}

+ (void)logSummary {
    NSArray<UIView *> *wv = [self webViews];
    YBLogSync(@"[H5] 找到 %lu 个 WebView", (unsigned long)wv.count);
    if (!wv.count) { YBLogSync(@"[H5] 没有 WebView —— 这个页面不是 H5"); return; }

    NSString *txt = [self textOfFirstWeb];
    if (!txt.length) { YBLogSync(@"[H5] 读不到正文"); return; }
    // 正文压成一行、每 60 字一行打出去，面板上能看几行，日志文件里是全的
    NSString *flat = [txt stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSUInteger len = MIN(flat.length, (NSUInteger)900);
    NSString *cut = [flat substringToIndex:len];
    NSUInteger step = 60;
    for (NSUInteger i = 0; i < cut.length; i += step) {
        NSUInteger l = MIN(step, cut.length - i);
        YBLogSync(@"[H5正文] %@", [cut substringWithRange:NSMakeRange(i, l)]);
    }

    NSString *jsBtn = @"(function(){try{var q=document.querySelectorAll('button,a,div[role=button],span,div');var out=[];var n=0;for(var i=0;i<q.length;i++){var e=q[i];var t=(e.innerText||'').trim();if(!t||t.length>12)continue;var r=e.getBoundingClientRect();if(r.width<20||r.height<10)continue;out.push(t);if(++n>=40)break;}return out.join(' | ');}catch(e){return 'ERR:'+e;}})()";
    NSString *btns = [self syncJS:jsBtn in:wv.firstObject];
    YBLogSync(@"[H5可点] %@", btns.length ? btns : @"(空)");
}

+ (NSString *)textSignature {
    NSString *t = [self textOfFirstWeb];
    if (!t) return @"(无)";
    return [NSString stringWithFormat:@"%lu/%lu", (unsigned long)t.length, (unsigned long)t.hash];
}

+ (BOOL)tapText:(NSArray<NSString *> *)keys {
    NSArray<UIView *> *wv = [self webViews];
    if (!wv.count) { YBLogSync(@"[H5] 没有 WebView，跳过"); return NO; }

    // 把锚点数组做成 JS 数组字面量
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

    NSString *before = [self textSignature];
    NSString *r = [self syncJS:js in:wv.firstObject];
    YBLogSync(@"[H5] 点「%@」-> %@", YBJoinKeys(keys), r ?: @"(无返回)");
    if (!r || [r hasPrefix:@"ERR"]) return NO;
    if ([r isEqualToString:@"notfound"]) return NO;

    [NSThread sleepForTimeInterval:1.0];
    NSString *after = [self textSignature];
    BOOL changed = ![after isEqualToString:before];
    YBLogSync(@"[H5] 正文指纹 %@ -> %@ %@", before, after, changed ? @"（已变）" : @"（没变）");
    return changed;
}

@end
