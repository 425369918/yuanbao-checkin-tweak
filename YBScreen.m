#import "YBScreen.h"
#import "YBTouch.h"
#import "YBLog.h"
#import <Vision/Vision.h>

@implementation YBScreen

static UIImage *YBScaleDown(UIImage *img, CGFloat maxLong) {
    if (!img) return nil;
    CGFloat w = img.size.width, h = img.size.height;
    CGFloat longest = MAX(w, h);
    if (longest <= maxLong || longest <= 0) return img;
    CGFloat k = maxLong / longest;
    CGSize target = CGSizeMake(w * k, h * k);
    UIGraphicsBeginImageContextWithOptions(target, NO, 1.0);
    [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

+ (instancetype)capture {
    YBScreen *s = [YBScreen new];
    // 窗口统一交给 YBTouch 挑：自己的浮窗、键盘窗都会被排除
    UIWindow *root = [YBTouch keyWindow];
    if (!root) { YBLogSync(@"[截图] 拿不到 App 窗口"); return s; }
    if (root.bounds.size.width < 1 || root.bounds.size.height < 1) {
        YBLogSync(@"[截图] 窗口尺寸为 0，跳过");
        return s;
    }
    YBSetTrace("capture:1 截图开始");
    YBLogSync(@"[截图] 窗口 %@ %.0fx%.0f", NSStringFromClass(root.class),
              root.bounds.size.width, root.bounds.size.height);

    UIImage *img = nil;
    // afterScreenUpdates 必须用 NO：
    // 传 YES 会强制同步做一遍渲染/提交，注入进程里很容易和 App 自己的渲染事务打架，
    // 表现就是"点执行的瞬间直接闪退"。
    @try {
        UIGraphicsBeginImageContextWithOptions(root.bounds.size, NO, 0);
        [root drawViewHierarchyInRect:root.bounds afterScreenUpdates:NO];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    } @catch (NSException *e) {
        YBLogSync(@"[截图] drawViewHierarchy 异常: %@", e.reason);
    }
    if (!img) {
        // 兜底：直接渲染 layer（拿不到 Metal 内容，但不会崩）
        @try {
            UIGraphicsBeginImageContextWithOptions(root.bounds.size, NO, 0);
            [root.layer renderInContext:UIGraphicsGetCurrentContext()];
            img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        } @catch (NSException *e) {
            YBLogSync(@"[截图] renderInContext 异常: %@", e.reason);
        }
    }
    if (!img) { YBLogSync(@"[截图] 失败，拿不到画面"); return s; }

    // 全屏 3x 图直接丢给 Vision 又慢又吃内存（容易触发系统因内存压力杀进程），先缩到长边 1280
    UIImage *small = YBScaleDown(img, 1280);
    s.image = small;
    s.pointSize = root.bounds.size;
    s.scale = (root.bounds.size.width > 1) ? (small.size.width / root.bounds.size.width) : 1.0;
    YBLogSync(@"[截图] 完成 %.0fx%.0f -> OCR 输入 %.0fx%.0f (scale %.2f)",
              img.size.width, img.size.height, small.size.width, small.size.height, s.scale);
    YBSetTrace("capture:done");
    return s;
}

- (void)runOCR {
    CGImageRef cg = self.image.CGImage;
    if (!cg) { self.lines = @[]; return; }
    NSMutableArray *out = [NSMutableArray array];
    // 注意：UIImage.size 已是「点」，OCR 坐标要按「像素」换算后再除以 scale
    CGSize px = CGSizeMake(CGImageGetWidth(cg), CGImageGetHeight(cg));
    // 只用 capture() 里在主线程算好的 scale，避免在后台线程碰 UIScreen
    CGFloat sc = self.scale > 0 ? self.scale : 2.0;

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