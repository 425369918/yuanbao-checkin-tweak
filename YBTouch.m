#import "YBTouch.h"
#import "YBLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface YBTouch ()
+ (UIView *)_enclosingTable:(UIView *)v;
+ (UIView *)deepHit:(CGPoint)pt in:(UIView *)root;
@end

@implementation YBTouch

static BOOL YBIsOwnOverlay(UIWindow *w) {
    return [w isKindOfClass:NSClassFromString(@"YBPassWindow")];
}

+ (UIWindow *)keyWindow {
    UIWindow *fallback = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (YBIsOwnOverlay(w)) continue;          // 别拿到自己的悬浮窗
            if (w.isKeyWindow) return w;
            if (!fallback && !w.hidden && w.windowLevel <= UIWindowLevelNormal + 1) fallback = w;
        }
    }
    UIWindow *app = UIApplication.sharedApplication.keyWindow;
    if (app && !YBIsOwnOverlay(app)) return app;
    return fallback ?: app;
}

// 视图“自己身上的文字”
static NSString *YBViewText(UIView *v) {
    NSMutableArray *s = [NSMutableArray array];
    if ([v isKindOfClass:UILabel.class]) { UILabel *l=(UILabel*)v; if(l.text.length)[s addObject:l.text]; }
    if ([v isKindOfClass:UIButton.class]) {
        UIButton *b=(UIButton*)v;
        if (b.currentTitle.length) [s addObject:b.currentTitle];
        if (b.titleLabel.text.length) [s addObject:b.titleLabel.text];
    }
    if ([v isKindOfClass:UITextField.class]) { UITextField *t=(UITextField*)v; if(t.text.length)[s addObject:t.text]; if(t.placeholder.length)[s addObject:t.placeholder]; }
    if ([v isKindOfClass:UITextView.class]) { UITextView *t=(UITextView*)v; if(t.text.length)[s addObject:t.text]; }
    if (v.accessibilityLabel.length) [s addObject:v.accessibilityLabel];
    if (v.accessibilityValue.length) [s addObject:v.accessibilityValue];
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
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
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
    while (q.count) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        NSString *t = YBViewText(v);
        if (t.length && !v.hidden && v.alpha > 0.01) [out addObject:t];
        for (UIView *sub in v.subviews) [q addObject:sub];
    }
    return out;
}

// 触发手势识别器里的 target/action（UIControl 之外的兜底）
static BOOL YBFireGestures(UIView *v) {
    @try {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (![g isKindOfClass:UITapGestureRecognizer.class]) continue;
            NSArray *targets = [g valueForKey:@"_targets"];
            for (id t in targets) {
                id target = [t valueForKey:@"_target"];
                NSString *action = NSStringFromSelector(NSSelectorFromString([t valueForKey:@"_action"]));
                SEL sel = NSSelectorFromString(action);
                if (target && sel && [target respondsToSelector:sel]) {
                    YBLog(@"[点按] 触发手势 %@ -> %@", NSStringFromClass([target class]), action);
                    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, g);
                    return YES;
                }
            }
        }
    } @catch (NSException *e) {
        YBLog(@"[点按] 手势触发异常: %@", e.reason);
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

    // 1) 向上找 UIControl
    UIView *cur = hit;
    while (cur) {
        if ([cur isKindOfClass:UIControl.class]) {
            UIControl *c = (UIControl *)cur;
            if (c.enabled && !c.hidden) {
                YBLog(@"[点按] (%.0f,%.0f) -> UIControl %@ \"%@\"",
                      pt.x, pt.y, NSStringFromClass(c.class), YBViewText(c));
                [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
        // 2) cell 直接走 delegate 选中
        if ([cur isKindOfClass:UITableViewCell.class]) {
            UITableView *tv = (UITableView *)[self _enclosingTable:cur];
            NSIndexPath *ip = [tv indexPathForCell:(UITableViewCell *)cur];
            if (tv.delegate && ip) {
                YBLog(@"[点按] -> 选中 cell %@", ip);
                if ([tv.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)])
                    [tv.delegate tableView:tv didSelectRowAtIndexPath:ip];
                return YES;
            }
        }
        cur = cur.superview;
    }
    // 3) 手势兜底
    cur = hit;
    while (cur) { if (YBFireGestures(cur)) return YES; cur = cur.superview; }

    // 4) 无障碍激活
    if ([hit accessibilityActivate]) { YBLog(@"[点按] accessibilityActivate 成功"); return YES; }
    YBLog(@"[点按] (%.0f,%.0f) 命中 %@ 但无法触发", pt.x, pt.y, NSStringFromClass(hit.class));
    return NO;
}

+ (UIView *)_enclosingTable:(UIView *)v {
    while (v && ![v isKindOfClass:UITableView.class]) v = v.superview;
    return v;
}

+ (BOOL)tapText:(NSArray<NSString *> *)keys {
    UIView *v = [self findViewWithText:keys];
    if (!v) { YBLog(@"[点按] 未找到文字 %@", keys); return NO; }
    UIWindow *win = [self keyWindow];
    CGRect r = [v convertRect:v.bounds toView:win];
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    YBLog(@"[点按] 文字命中 %@ -> %@ (%.0f,%.0f)", keys, NSStringFromClass(v.class), c.x, c.y);
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