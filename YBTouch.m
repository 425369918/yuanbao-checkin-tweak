#import "YBTouch.h"
#import "YBLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface YBTouch ()
+ (UIView *)_enclosingTable:(UIView *)v;
+ (UIView *)deepHit:(CGPoint)pt in:(UIView *)root;
+ (BOOL)activateView:(UIView *)v;
+ (BOOL)tapAccessibilityElement:(NSArray<NSString *> *)keys in:(UIView *)root;
@end

@implementation YBTouch

static NSHashTable *gOwnWindows = nil;

static BOOL YBIsOwnOverlay(UIWindow *w) {
    if (!w) return NO;
    static Class ownCls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ownCls = NSClassFromString(@"YBPassWindow"); });
    if (ownCls && [w isKindOfClass:ownCls]) return YES;
    @synchronized (gOwnWindows ?: (gOwnWindows = [NSHashTable weakObjectsHashTable])) {
        for (UIWindow *o in gOwnWindows) if (o == w) return YES;
    }
    return NO;
}

+ (void)registerOwnWindow:(UIWindow *)w {
    if (!w) return;
    if (!gOwnWindows) gOwnWindows = [NSHashTable weakObjectsHashTable];
    @synchronized (gOwnWindows) { [gOwnWindows addObject:w]; }
    YBLog(@"[窗口] 已登记自己的悬浮窗 %@ level=%.0f", NSStringFromClass(w.class), w.windowLevel);
}

// 截图前把自己的浮窗藏起来（否则会被截进画面，OCR 会认到我们自己的按钮文字）
+ (void)setOwnOverlaysHidden:(BOOL)hidden {
    if (!gOwnWindows) return;
    NSMutableArray *ws = [NSMutableArray array];
    @synchronized (gOwnWindows) {
        for (UIWindow *o in gOwnWindows) if (o) [ws addObject:o];
    }
    for (UIWindow *o in ws) { @try { o.hidden = hidden; } @catch (NSException *e) { } }
}

// 拿 App 自己的窗口：key window 常常不可靠（我们自己的浮窗、键盘窗、弹窗各占一个 level），
// 所以按"可见 + 不是自己的 + 层级最低 + 面积最大"来挑。
// 注意：这里不再调已废弃的 UIApplication.windows —— 它在个别系统版本上会直接抛断言。
+ (UIWindow *)keyWindow {
    NSMutableArray<UIWindow *> *cand = [NSMutableArray array];

    // 1) 所有 UIWindowScene 上的窗口
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            NSArray *ws = ((UIWindowScene *)sc).windows;
            if ([ws isKindOfClass:NSArray.class]) for (UIWindow *w in ws) if (w) [cand addObject:w];
        }
    } @catch (NSException *e) { YBLog(@"[窗口] 枚举 scene 异常: %@", e.reason); }

    // 2) 我们自己浮窗所在的 scene（保险，防 connectedScenes 里没列出来）
    @try {
        if (!gOwnWindows) gOwnWindows = [NSHashTable weakObjectsHashTable];
        for (UIWindow *o in gOwnWindows) {
            if (o.windowScene) for (UIWindow *w in o.windowScene.windows) if (w) [cand addObject:w];
        }
    } @catch (NSException *e) { }

    // 3) App 的 delegate.window
    @try {
        id dg = UIApplication.sharedApplication.delegate;
        if ([dg respondsToSelector:@selector(window)]) {
            UIWindow *w = [(id)dg window];
            if (w) [cand addObject:w];
        }
    } @catch (NSException *e) { }

    UIWindow *best = nil;
    CGFloat bestArea = 0;
    NSInteger bestLevel = 999999;
    for (UIWindow *w in cand) {
        @try {
            if (YBIsOwnOverlay(w)) continue;
            if (w.hidden || w.alpha < 0.01) continue;
            if (w.windowLevel > 10) continue;                 // 键盘/系统窗跳过
            if (w.bounds.size.width < 1 || w.bounds.size.height < 1) continue;
            CGFloat area = w.bounds.size.width * w.bounds.size.height;
            if (area > bestArea || (area == bestArea && w.windowLevel < bestLevel)) {
                best = w; bestArea = area; bestLevel = (NSInteger)w.windowLevel;
            }
        } @catch (NSException *e) { }
    }
    return best;
}

// App 的所有可见窗口（不含自己的浮窗）—— H5 页面可能在别的窗口里，所以要全拿
+ (NSArray<UIWindow *> *)appWindows {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    NSMutableArray<UIWindow *> *cand = [NSMutableArray array];
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            NSArray *ws = ((UIWindowScene *)sc).windows;
            if ([ws isKindOfClass:NSArray.class]) for (UIWindow *w in ws) if (w) [cand addObject:w];
        }
    } @catch (NSException *e) { }
    @try {
        id dg = UIApplication.sharedApplication.delegate;
        if ([dg respondsToSelector:@selector(window)]) {
            UIWindow *w = [(id)dg window];
            if (w) [cand addObject:w];
        }
    } @catch (NSException *e) { }
    for (UIWindow *w in cand) {
        @try {
            if (YBIsOwnOverlay(w)) continue;
            if (w.hidden || w.alpha < 0.01) continue;
            if (w.windowLevel > 10) continue;
            if (w.bounds.size.width < 1 || w.bounds.size.height < 1) continue;
            if (![out containsObject:w]) [out addObject:w];
        } @catch (NSException *e) { }
    }
    return out;
}

// 一次性诊断：把 App 的 UI 框架、窗口、根控制器、根视图子类打出来
// 这几行决定了"到底能不能用视图树取文字，还是只能靠 OCR 点坐标"
+ (void)logDiagnostics {
    UIWindow *w = [self keyWindow];
    if (!w) { YBLog(@"[诊断] 仍然拿不到 App 窗口"); return; }
    YBLog(@"[诊断] 窗口 %@ level=%.0f %.0fx%.0f key=%d",
          NSStringFromClass(w.class), w.windowLevel, w.bounds.size.width, w.bounds.size.height, w.isKeyWindow);
    UIViewController *vc = w.rootViewController;
    YBLog(@"[诊断] 根控制器 %@", vc ? NSStringFromClass(vc.class) : @"(nil)");
    UIView *rv = vc.view ?: w;
    NSMutableArray *cls = [NSMutableArray array];
    NSUInteger n = MIN(rv.subviews.count, (NSUInteger)8);
    for (NSUInteger i = 0; i < n; i++) [cls addObject:NSStringFromClass([rv.subviews[i] class])];
    YBLog(@"[诊断] 根视图 %@ 子视图(%lu): %@", NSStringFromClass(rv.class),
          (unsigned long)rv.subviews.count, [cls componentsJoinedByString:@", "]);
}

// 视图“自己身上的文字”
static NSString *YBViewText(UIView *v) {
    NSMutableArray *s = [NSMutableArray array];
    // 逐段包 @try：自绘界面某些节点读 accessibility 属性会往里抛异常，不能让它带走整个遍历
    @try {
        if ([v isKindOfClass:UILabel.class]) { UILabel *l=(UILabel*)v; if(l.text.length)[s addObject:l.text]; }
        if ([v isKindOfClass:UIButton.class]) {
            UIButton *b=(UIButton*)v;
            if (b.currentTitle.length) [s addObject:b.currentTitle];
            if (b.titleLabel.text.length) [s addObject:b.titleLabel.text];
        }
        if ([v isKindOfClass:UITextField.class]) { UITextField *t=(UITextField*)v; if(t.text.length)[s addObject:t.text]; if(t.placeholder.length)[s addObject:t.placeholder]; }
        if ([v isKindOfClass:UITextView.class]) { UITextView *t=(UITextView*)v; if(t.text.length)[s addObject:t.text]; }
    } @catch (NSException *e) { }

    @try {
        NSString *al = v.accessibilityLabel;
        if (al.length) [s addObject:al];
    } @catch (NSException *e) { }
    @try {
        NSString *av = v.accessibilityValue;
        if (av.length) [s addObject:av];
    } @catch (NSException *e) { }
    return [s componentsJoinedByString:@" | "];
}

static BOOL YBTextMatches(NSString *txt, NSArray<NSString *> *keys) {
    if (!txt.length) return NO;
    for (NSString *k in keys) if (k.length && [txt containsString:k]) return YES;
    return NO;
}

+ (id)findViewWithText:(NSArray<NSString *> *)keys {
    NSArray<NSDictionary *> *cs = [self textCandidates:keys];
    return cs.count ? cs.firstObject[@"view"] : nil;
}

// 找出所有"文字命中"的候选，并且标出它们**到底在不在屏幕上、点不点得着**。
// 元宝的侧边抽屉（收藏/删除/创建新分组…）一直挂在视图树里但整块在屏幕外，
// 里面的「福利中心」和底栏的「福利中心」同名 —— 不过滤的话很容易点到屏幕外那个，
// 结果就是"点了没反应"。这一步就是为此加的。
+ (NSArray<NSDictionary *> *)textCandidates:(NSArray<NSString *> *)keys {
    UIWindow *root = [self keyWindow];
    if (!root) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visits = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.2];
    while (queue.count) {
        if (visits++ > 15000) { YBLog(@"[遍历] 节点超过上限，停止（可能没找到）"); break; }
        if ((visits & 511) == 0 && [deadline timeIntervalSinceNow] < 0) { YBLog(@"[遍历] 超时 1.2s，停止"); break; }
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        if (YBTextMatches(YBViewText(v), keys)) {
            // 优先可交互的祖先
            UIView *cand = v;
            UIView *cur = v;
            int d = 0;
            while (cur && d < 6) {
                if ([cur isKindOfClass:UIControl.class] ||
                    [cur isKindOfClass:UITableViewCell.class] ||
                    [cur isKindOfClass:UICollectionViewCell.class]) { cand = cur; break; }
                cur = cur.superview; d++;
            }
            CGRect r = [cand convertRect:cand.bounds toView:root];
            CGFloat area = r.size.width * r.size.height;
            if (area > 1) {
                CGRect inter = CGRectIntersection(r, root.bounds);
                CGFloat ratio = (inter.size.width * inter.size.height) / area;
                BOOL hitOK = NO;
                if (ratio > 0.55) {
                    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
                    UIView *hit = [self deepHit:c in:root];
                    hitOK = (hit == cand) || (hit && [hit isDescendantOfView:cand]);
                }
                [out addObject:@{@"view": cand, @"rect": [NSValue valueWithCGRect:r],
                                 @"area": @(area), @"ratio": @(ratio), @"hit": @(hitOK)}];
            }
        }
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    return out;
}

// 当前界面的文字指纹：用来判断"点了之后界面到底变没变"
+ (NSString *)textSignature {
    NSArray<NSString *> *t = [self dumpVisibleTexts];
    NSString *j = [t componentsJoinedByString:@"|"];
    return [NSString stringWithFormat:@"%lu/%lu", (unsigned long)t.count, (unsigned long)j.hash];
}

+ (NSArray<NSString *> *)dumpVisibleTexts {
    UIView *root = [self keyWindow];
    if (!root) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
    NSUInteger visits = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.2];
    while (q.count) {
        if (visits++ > 20000) break;
        if ((visits & 511) == 0 && [deadline timeIntervalSinceNow] < 0) break;
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        NSString *t = YBViewText(v);
        if (t.length && !v.hidden && v.alpha > 0.01) [out addObject:t];
        for (UIView *sub in v.subviews) [q addObject:sub];
    }
    return out;
}

// 触发一个视图：按"最安全 → 兜底"的顺序来，全程只用公开 API
// 1) UIControl 发 action
// 2) 表格/集合 cell 走 delegate 选中
// 3) UIAccessibility 的 accessibilityActivate（SwiftUI 也实现这个，公开 API，最稳）
// 注意：原来那条"用 KVC 取 _targets/_action 再 objc_msgSend 打私有手势"的路已经删掉 ——
// SwiftUI 的手势 target 是 Swift 闭包，objc_msgSend 用错 ABI 会直接野指针崩溃。
+ (BOOL)activateView:(UIView *)v {
    UIView *cur = v;
    int depth = 0;
    while (cur && depth < 8) {
        if ([cur isKindOfClass:UIControl.class]) {
            UIControl *c = (UIControl *)cur;
            if (c.enabled && !c.hidden) {
                YBLog(@"[点按] UIControl %@ \"%@\"", NSStringFromClass(c.class), YBViewText(c));
                [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
        if ([cur isKindOfClass:UITableViewCell.class]) {
            UITableView *tv = (UITableView *)[self _enclosingTable:cur];
            NSIndexPath *ip = [tv indexPathForCell:(UITableViewCell *)cur];
            if (tv.delegate && ip && [tv.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                YBLog(@"[点按] 选中 cell %@", ip);
                [tv.delegate tableView:tv didSelectRowAtIndexPath:ip];
                return YES;
            }
        }
        // accessibilityActivate 必须包 @try：SwiftUI 的 accessibility 元素偶尔会往里抛异常
        @try {
            if ([cur accessibilityActivate]) {
                YBLog(@"[点按] accessibilityActivate 成功 (%@)", NSStringFromClass(cur.class));
                return YES;
            }
        } @catch (NSException *e) {
            YBLog(@"[点按] accessibilityActivate 异常: %@", e.reason);
        }
        cur = cur.superview;
        depth++;
    }
    return NO;
}

// 自绘 UI（SwiftUI / 自绘界面）常常整棵树里没有 UILabel，但会暴露无障碍元素。
// accessibilityElements 是公开属性，这里按标签找元素再 activate —— 公开 API，安全。
+ (BOOL)tapAccessibilityElement:(NSArray<NSString *> *)keys in:(UIView *)root {
    if (!root || !keys.count) return NO;
    NSMutableArray *q = [NSMutableArray arrayWithObject:root];
    NSUInteger visits = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.2];
    while (q.count) {
        if (visits++ > 8000) break;
        if ((visits & 255) == 0 && [deadline timeIntervalSinceNow] < 0) break;
        id v = q.firstObject; [q removeObjectAtIndex:0];
        @try {
            if ([v respondsToSelector:@selector(accessibilityElements)]) {
                NSArray *els = [v accessibilityElements];
                if ([els isKindOfClass:NSArray.class]) {
                    for (id el in els) {
                        NSString *label = nil;
                        @try {
                            if ([el respondsToSelector:@selector(accessibilityLabel)]) label = [el accessibilityLabel];
                            if (!label.length && [el respondsToSelector:@selector(accessibilityValue)])
                                label = [el accessibilityValue];
                        } @catch (NSException *e) { }
                        if ([label isKindOfClass:NSString.class] && label.length) {
                            for (NSString *k in keys) {
                                if (k.length && [label containsString:k]) {
                                    YBLog(@"[无障碍] 命中 \"%@\"", label);
                                    @try {
                                        if ([el accessibilityActivate]) return YES;
                                    } @catch (NSException *e) {
                                        YBLog(@"[无障碍] activate 异常: %@", e.reason);
                                    }
                                }
                            }
                        }
                        if ([el isKindOfClass:UIView.class]) [q addObject:el];
                    }
                }
            }
        } @catch (NSException *e) { }
        if ([v isKindOfClass:UIView.class]) {
            for (UIView *s in [(UIView *)v subviews]) [q addObject:s];
        }
    }
    return NO;
}

// 自己手动做命中测试：不用 [win hitTest:withEvent:nil]
// 原因：注入进第三方 App 后，它们自己重写的 hitTest:withEvent: 常常默认 event 不为 nil，
// 传 nil 进去会直接崩（野指针），这是"一点执行就闪退"的典型来源。
+ (UIView *)deepHit:(CGPoint)pt in:(UIView *)root {
    UIView *best = nil;
    for (UIView *sub in root.subviews) {          // 后加的先测（层级更高的在上面）
        if (sub.hidden || sub.alpha < 0.01) continue;
        if (!sub.userInteractionEnabled) continue;
        CGPoint lp = [sub convertPoint:pt fromView:root];
        if (!CGRectContainsPoint(sub.bounds, lp)) continue;
        UIView *deep = [self deepHit:pt in:sub];
        if (deep) best = deep;
    }
    return best ?: (root.userInteractionEnabled || root == root.window ? root : nil);
}

+ (BOOL)tapPoint:(CGPoint)pt {
    UIWindow *win = [self keyWindow];
    if (!win) { YBLog(@"[点按] 无 key window"); return NO; }
    UIView *hit = [self deepHit:pt in:win];
    if (!hit) { YBLog(@"[点按] (%.0f,%.0f) 未命中任何视图", pt.x, pt.y); return NO; }
    if ([self activateView:hit]) return YES;
    YBLog(@"[点按] (%.0f,%.0f) 命中 %@ 但触发不了", pt.x, pt.y, NSStringFromClass(hit.class));
    return NO;
}

+ (UIView *)_enclosingTable:(UIView *)v {
    while (v && ![v isKindOfClass:UITableView.class]) v = v.superview;
    return v;
}

+ (BOOL)tapText:(NSArray<NSString *> *)keys {
    NSArray<NSDictionary *> *cs = [self textCandidates:keys];
    if (!cs.count) {
        // 视图树里没有文字（纯自绘 UI）：走无障碍元素
        if ([self tapAccessibilityElement:keys in:[self keyWindow]]) return YES;
        YBLog(@"[点按] 未找到文字 %@", YBJoinKeys(keys));
        return NO;
    }

    // 排序：屏幕上能真正命中的优先 → 位于屏幕内的比例高的优先 → 面积小的优先（更接近"按钮"本身）
    NSArray<NSDictionary *> *sorted = [cs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL ha = [a[@"hit"] boolValue], hb = [b[@"hit"] boolValue];
        if (ha != hb) return ha ? NSOrderedAscending : NSOrderedDescending;
        double ra = [a[@"ratio"] doubleValue], rb = [b[@"ratio"] doubleValue];
        if (fabs(ra - rb) > 0.1) return ra > rb ? NSOrderedAscending : NSOrderedDescending;
        double aa = [a[@"area"] doubleValue], ab = [b[@"area"] doubleValue];
        if (aa != ab) return aa < ab ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSString *before = [self textSignature];
    NSInteger tries = 0;
    for (NSDictionary *d in sorted) {
        if (tries++ >= 3) break;           // 最多试 3 个，防止来回乱点
        UIView *v = d[@"view"];
        BOOL trig = [self activateView:v];
        YBLog(@"[点按] %@ 候选 %@ 屏内=%.2f 可命中=%@ 触发=%@", YBJoinKeys(keys), NSStringFromClass(v.class),
              [d[@"ratio"] doubleValue], [d[@"hit"] boolValue] ? @"是" : @"否", trig ? @"是" : @"否");
        if (!trig) continue;
        [NSThread sleepForTimeInterval:0.9];
        NSString *after = [self textSignature];
        if (![after isEqualToString:before]) {
            YBLog(@"[点按] %@ 界面已变化（%d 号候选），成功", YBJoinKeys(keys), (int)tries);
            return YES;
        }
        YBLog(@"[点按] %@ 界面没变化，换下一个候选", YBJoinKeys(keys));
    }
    // 候选都触发不了 → 再走"无障碍元素"通道（SwiftUI 按钮的 action 挂在无障碍元素上）
    if ([self tapAccessibilityElement:keys in:[self keyWindow]]) {
        YBLog(@"[点按] %@ 经无障碍元素触发成功", YBJoinKeys(keys));
        return YES;
    }
    // 都不行，最后退到坐标点按（用第一个候选的中心）
    NSDictionary *d0 = sorted.firstObject;
    CGRect r0 = [d0[@"rect"] CGRectValue];
    CGPoint c = CGPointMake(CGRectGetMidX(r0), CGRectGetMidY(r0));
    YBLog(@"[点按] %@ 所有候选都没生效，最后试坐标 (%.0f,%.0f)", YBJoinKeys(keys), c.x, c.y);
    return [self tapPoint:c];
}

// 无障碍元素里的文字。
// 为什么单独做这条：SwiftUI / Flutter 这类"自绘"页面，屏幕上明明有字，
// 但 UIView 层级里一个 UILabel 都没有 —— 字全在 accessibilityElements 里。
+ (NSArray<NSString *> *)dumpAccessibilityTexts {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSUInteger visits = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    for (UIWindow *w in [self appWindows]) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        while (q.count) {
            if (visits++ > 12000) break;
            if ((visits & 255) == 0 && [deadline timeIntervalSinceNow] < 0) break;
            id v = q.firstObject; [q removeObjectAtIndex:0];

            @try {
                if ([v respondsToSelector:@selector(accessibilityElements)]) {
                    id els = [v accessibilityElements];
                    if ([els isKindOfClass:NSArray.class]) {
                        for (id el in (NSArray *)els) {
                            NSString *s = nil;
                            @try {
                                if ([el respondsToSelector:@selector(accessibilityLabel)]) s = [el accessibilityLabel];
                                if (!s.length && [el respondsToSelector:@selector(accessibilityValue)])
                                    s = [el accessibilityValue];
                            } @catch (NSException *e) { }
                            if ([s isKindOfClass:NSString.class] && s.length) [out addObject:s];
                            [q addObject:el];
                        }
                    }
                }
            } @catch (NSException *e) { }

            @try {
                if ([v respondsToSelector:@selector(accessibilityLabel)]) {
                    NSString *s = [v accessibilityLabel];
                    if ([s isKindOfClass:NSString.class] && s.length) [out addObject:s];
                }
            } @catch (NSException *e) { }

            if ([v isKindOfClass:UIView.class]) {
                for (UIView *s in [(UIView *)v subviews]) [q addObject:s];
            }
        }
    }
    return out;
}

// 诊断：把「按文字找控件」这一路上每个候选的真实情况打出来（一屏能看完，方便拍面板）
+ (void)diagnoseText:(NSArray<NSString *> *)keys {
    UIWindow *w = [self keyWindow];
    YBLog(@"[F] 窗口 %@ 尺寸=%.0fx%.0f", w ? NSStringFromClass(w.class) : @"无",
          w.bounds.size.width, w.bounds.size.height);
    NSArray<NSDictionary *> *cs = [self textCandidates:keys];
    YBLog(@"[F] 文字 %@ 命中 %lu 个候选", YBJoinKeys(keys), (unsigned long)cs.count);
    NSInteger i = 0;
    for (NSDictionary *d in cs) {
        if (++i > 6) break;
        UIView *v = d[@"view"];
        CGRect r = [d[@"rect"] CGRectValue];
        YBLog(@"[F] #%ld %@ 位置=(%.0f,%.0f,%.0fx%.0f) 屏内=%.2f 可命中=%@ 父=%@",
              (long)i, NSStringFromClass(v.class), r.origin.x, r.origin.y, r.size.width, r.size.height,
              [d[@"ratio"] doubleValue], [d[@"hit"] boolValue] ? @"是" : @"否",
              NSStringFromClass(v.superview.class));
        @try {
            YBLog(@"[F] #%ld traits=%lu 可激活=%@ 文字=\"%@\"", (long)i,
                  (unsigned long)[v accessibilityTraits],
                  [v respondsToSelector:@selector(accessibilityActivate)] ? @"是" : @"否",
                  YBViewText(v));
        } @catch (NSException *e) { YBLog(@"[F] #%ld 读无障碍属性异常: %@", (long)i, e.reason); }
    }
}

+ (BOOL)inputText:(NSString *)text nearKeys:(NSArray<NSString *> *)keys {
    UIView *v = [self findViewWithText:keys];
    UIWindow *win = [self keyWindow];
    UITextField *tf = nil; UITextView *tv = nil;
    // 从命中视图向下/向上找输入框
    if ([v isKindOfClass:UITextField.class]) tf = (UITextField *)v;
    if ([v isKindOfClass:UITextView.class])  tv = (UITextView *)v;
    if (!tf && !tv) {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:v ?: win];
        while (q.count) {
            UIView *x = q.firstObject; [q removeObjectAtIndex:0];
            if ([x isKindOfClass:UITextField.class]) { tf=(UITextField*)x; break; }
            if ([x isKindOfClass:UITextView.class])  { tv=(UITextView*)x;  break; }
            for (UIView *s in x.subviews) [q addObject:s];
        }
    }
    if (!tf && !tv) { YBLog(@"[输入] 未找到输入框 %@", YBJoinKeys(keys)); return NO; }
    if (tf) {
        tf.text = text;
        [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        [tf sendActionsForControlEvents:UIControlEventEditingDidEnd];
    } else {
        tv.text = text;
        if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) [tv.delegate textViewDidChange:tv];
    }
    YBLog(@"[输入] 已写入: %@", text);
    return YES;
}

@end