#import "YBScreen.h"
#import "YBLog.h"
#import <Vision/Vision.h>

@implementation YBScreen

+ (instancetype)capture {
    YBScreen *s = [YBScreen new];
    UIView *root = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if ([w isKindOfClass:NSClassFromString(@"YBPassWindow")]) continue;  // 跳过自己的悬浮窗
            if (w.isKeyWindow) { root = w; break; }
        }
        if (root) break;
    }
    if (!root) {
        UIWindow *app = UIApplication.sharedApplication.keyWindow;
        if (app && ![app isKindOfClass:NSClassFromString(@"YBPassWindow")]) root = app;
    }
    if (!root) { YBLog(@"[截图] 没有 key window"); return s; }
    if (root.bounds.size.width < 1 || root.bounds.size.height < 1) {
        YBLog(@"[截图] key window 尺寸为 0，跳过");
        return s;
    }

    UIGraphicsBeginImageContextWithOptions(root.bounds.size, NO, 0);
    [root drawViewHierarchyInRect:root.bounds afterScreenUpdates:YES];
    s.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    s.pointSize = root.bounds.size;
    s.scale = s.image.scale > 0 ? s.image.scale : UIScreen.mainScreen.scale;
    return s;
}

- (void)runOCR {
    CGImageRef cg = self.image.CGImage;
    if (!cg) { self.lines = @[]; return; }
    NSMutableArray *out = [NSMutableArray array];
    // 注意：UIImage.size 已是「点」，OCR 坐标要按「像素」换算后再除以 scale
    CGSize px = CGSizeMake(CGImageGetWidth(cg), CGImageGetHeight(cg));
    CGFloat sc = self.scale > 0 ? self.scale : UIScreen.mainScreen.scale;

    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = YES;                 // 中文行文有助识别
    req.recognitionLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US"];
    if (@available(iOS 16.0, *)) req.revision = VNRecognizeTextRequestRevision3;   // 更准的中文模型

    NSError *err = nil;
    @try {
        if (![h performRequests:@[req] error:&err]) {
            YBLog(@"[OCR] 失败: %@", err.localizedDescription);
            self.lines = @[]; return;
        }
    } @catch (NSException *e) {
        YBLog(@"[OCR] 异常: %@", e.reason);
        self.lines = @[]; return;
    }
    for (VNRecognizedTextObservation *o in req.results) {
        VNRecognizedText *t = [[o topCandidates:1] firstObject];
        if (!t.string.length) continue;
        CGRect bb = o.boundingBox; // 归一化，左下原点
        CGRect r = CGRectMake(bb.origin.x * px.width,
                              (1.0 - bb.origin.y - bb.size.height) * px.height,
                              bb.size.width * px.width,
                              bb.size.height * px.height);
        // 转到逻辑点坐标
        CGRect pr = CGRectMake(r.origin.x / sc, r.origin.y / sc,
                               r.size.width / sc, r.size.height / sc);
        [out addObject:@{@"text": t.string, @"rect": [NSValue valueWithCGRect:pr], @"conf": @(t.confidence)}];
    }
    self.lines = out;
    YBLog(@"[OCR] %lu 行 (屏幕 %.0fx%.0f pt)", (unsigned long)out.count,
          self.pointSize.width, self.pointSize.height);
}

- (NSArray<NSDictionary *> *)lineDicts { return self.lines ?: @[]; }

- (CGPoint)centerOfTextContaining:(NSArray<NSString *> *)keys {
    NSDictionary *best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    for (NSDictionary *d in self.lines) {
        NSString *txt = d[@"text"];
        for (NSString *k in keys) {
            if (k.length && [txt containsString:k]) {
                CGRect r = [d[@"rect"] CGRectValue];
                CGFloat a = r.size.width * r.size.height;
                if (a < bestArea) { bestArea = a; best = d; }   // 取最贴合的小块
                break;
            }
        }
    }
    if (!best) return CGPointZero;
    CGRect r = [best[@"rect"] CGRectValue];
    CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
    YBLog(@"[定位] \"%@\" -> (%.0f, %.0f)", best[@"text"], c.x, c.y);
    return c;
}

@end