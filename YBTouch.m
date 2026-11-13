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
+ (UIWindow *)keyWindow {
    NSMutableArray<UIWindow *> *cand = [NSMutableArray array];
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w) [cand addObject:w];
        }
    } @catch (NSException *e) { YBLog(@"[窗口] 枚举 scene 异常: %@", e.reason); }
    // 老 API 兜底（iOS 16 上仍能用）
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *w in UIApplication.sharedApplication.windows) if (w) [cand addObject:w];
#pragma clang diagnostic pop

    UIWindow *best = nil;
    CGFloat bestArea = 0;
    NSInteger bestLevel = 999999;
    for (UIWindow *w in cand) {
        if (YBIsOwnOverlay(w)) continue;
        if (w.hidden || w.alpha < 0.01) continue;
        if (w.windowLevel > 10) continue;                 // 键盘/系统窗跳过
        if (w.bounds.size.width < 1 || w.bounds.size.height < 1) continue;
        CGFloat area = w.bounds.size.width * w.bounds.size.height;
        // 面积大优先；同面积取层级低的
        if (area > bestArea || (area == bestArea && w.windowLevel < bestLevel)) {
            best = w; bestArea = area; bestLevel = (NSInteger)w.windowLevel;
        }
    }
    if (best) return best;

    // 最后一层：App 的 delegate.window
    @try {
        id dg = UIApplication.sharedApplication.delegate;
        if ([dg respondsToSelector:@selector(window)]) {
            UIWindow *w = [(id)dg window];
            if (w && !YBIsOwnOverlay(w) && !w.hidden) return w;
        }
    } @catch (NSException *e) { }

    UIWindow *app = UIApplication.sharedApplication.keyWindow;
    if (app && !YBIsOwnOverlay(app)) return app;
    return nil;
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
    UIView *root = [self keyWindow];
    if (!root) return nil;
    __block UIView *found = nil;
    __block CGFloat bestArea = CGFLOAT_MAX;

    // 广度优先遍历（含 cell / collectionViewCell 内层）
    // 限数量 + 限时：这里是主线程，元宝的视图树上万个节点，不能无限跑（否则卡死被系统看门狗杀掉）
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger visits = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.2];
    while (queue.count) {
        if (visits++ > 15000) { YBLog(@"[遍历] 节点超过上限，停止（可能没找到）"); break; }
        if ((visits & 511) == 0 && [deadline timeIntervalSinceNow] < 0) { YBLog(@"[遍历] 超时 1.2s，停止"); break; }
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        if (YBTextMatches(YBViewText(v), keys)) {
            // 优先可交互的祖先
            UIView *cur = v;
            while (cur && ![cur isKindOfClass:UIControl.class] &&
                   ![cur isKindOfClass:UITableViewCell.class] &&
                   ![cur isKindOfClass:UICollectionViewCell.class]) {
                cur = cur.superview;
            }
            UIView *cand = cur ?: v;
            CGRect inWin = [cand convertRect:cand.bounds toView:root];
            CGFloat a = inWin.size.width * inWin.size.height;
            if (a > 1 && a < bestArea) { bestArea = a; found = cand; }   // 取最小的匹配块
        }
        for (UIView *sub in v.subviews) [queue addObject:sub];
    }
    return found;
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
    UIView *v = [self findViewWithText:keys];
    if (!v) {
        // 视图树里没有文字（自绘 UI）：走无障碍元素
        if ([self tapAccessibilityElement:keys in:[self keyWindow]]) return YES;
        YBLog(@"[点按] 未找到文字 %@", keys);
        return NO;
    }
    // 先在命中的视图上直接触发（不走坐标，最安全）
    if ([self activateView:v]) {
        YBLog(@"[点按] 文字命中 %@ -> 已触发 (%@)", keys, NSStringFromClass(v.class));
        return YES;
    }
    // 直接触发不了，再退到坐标点按
    UIWindow *win = [self keyWindow];
    CGRect r = [v convertRect:v.bounds toView:win];
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    YBLog(@"[点按] 文字命中 %@ -> %@ (%.0f,%.0f) 改走坐标", keys, NSStringFromClass(v.class), c.x, c.y);
    return [self tapPoint:c];
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
    if (!tf && !tv) { YBLog(@"[输入] 未找到输入框 %@", keys); return NO; }
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