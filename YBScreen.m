#import "YBScreen.h"
#import "YBTouch.h"
#import "YBLog.h"
#import <Vision/Vision.h>
#import <dlfcn.h>

@implementation YBScreen

// 系统内部的全屏截图函数（UIKit 私有）。好处：
//  1) 不强制 App 重新渲染（drawViewHierarchy 会，注入场景里很容易崩）
//  2) 能抓到 Metal / 自绘界面的内容，drawViewHierarchy 抓不到
static UIImage *YBScreenUIImagePrivate(void) {
    static void *fn = NULL;
    static BOOL tried = NO;
    if (!tried) {
        tried = YES;
        fn = dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        YBLogSync(@"[截图] _UICreateScreenUIImage %@", fn ? @"可用" : @"不可用");
    }
    if (!fn) return nil;
    @try { return ((__unsafe_unretained UIImage *(*)(void))fn)(); }
    @catch (NSException *e) { YBLogSync(@"[截图] 私有截图异常: %@", e.reason); return nil; }
}

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
    YBSetTrace("capture:1 开始");

    // 第一优先：系统全屏截图。既不需要窗口对象（拿不到窗口也不会失败），
    // 又不触发 App 重绘，还能抓到 Metal/自绘内容。
    // 它会把我们自己的浮窗也截进去 → 截之前藏起来，截完立刻恢复。
    [YBTouch setOwnOverlaysHidden:YES];
    UIImage *img = YBScreenUIImagePrivate();
    [YBTouch setOwnOverlaysHidden:NO];
    if (img) YBLogSync(@"[截图] 系统全屏截图 %.0fx%.0f", img.size.width, img.size.height);

    // 拿到窗口（后面算坐标要用；私有截图成功时只是顺手取一下）
    UIWindow *root = [YBTouch keyWindow];
    CGSize pts = root.bounds.size;
    if (pts.width < 1 || pts.height < 1) pts = [UIScreen mainScreen].bounds.size;
    if (root) {
        YBLogSync(@"[截图] 窗口 %@ %.0fx%.0f", NSStringFromClass(root.class), pts.width, pts.height);
    } else {
        YBLogSync(@"[截图] 没拿到 App 窗口，按屏幕尺寸 %.0fx%.0f 处理", pts.width, pts.height);
    }

    if (!img && root) {
        // 兜底 1：读当前画面，不强制 App 重新渲染
        YBSetTrace("capture:3 drawViewHierarchy");
        @try {
            UIGraphicsBeginImageContextWithOptions(root.bounds.size, NO, 0);
            [root drawViewHierarchyInRect:root.bounds afterScreenUpdates:NO];
            img = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
        } @catch (NSException *e) {
            YBLogSync(@"[截图] drawViewHierarchy 异常: %@", e.reason);
        }
    }
    if (!img && root) {
        // 兜底 2：直接渲染 layer（拿不到 Metal 内容，但不会崩）
        YBSetTrace("capture:4 renderInContext");
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
    s.pointSize = pts;
    s.scale = (pts.width > 1) ? (small.size.width / pts.width) : 1.0;
    YBLogSync(@"[截图] 完成 %.0fx%.0f -> OCR 输入 %.0fx%.0f (scale %.2f)",
              img.size.width, img.size.height, small.size.width, small.size.height, s.scale);
    YBSetTrace("capture:done");
    return s;
}

- (void)runOCR {
    CGImageRef cg = self.image.CGImage;
    if (!cg) { YBLogSync(@"[OCR] 没有图像，跳过"); self.lines = @[]; return; }
    NSMutableArray *out = [NSMutableArray array];
    // 注意：UIImage.size 已是「点」，OCR 坐标要按「像素」换算后再除以 scale
    CGSize px = CGSizeMake(CGImageGetWidth(cg), CGImageGetHeight(cg));
    // 只用 capture() 里在主线程算好的 scale，避免在后台线程碰 UIScreen
    CGFloat sc = self.scale > 0 ? self.scale : 2.0;
    YBSetTrace("ocr:1 开始");
    YBLogSync(@"[OCR] 开始 %.0fx%.0f px", px.width, px.height);

    NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;

    VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;                  // 关掉语言纠错：省 CPU/内存，中文照样能认
    req.recognitionLanguages = @[@"zh-Hans", @"zh-Hant", @"en-US"];
    if (@available(iOS 16.0, *)) req.revision = VNRecognizeTextRequestRevision3;   // 更准的中文模型

    NSError *err = nil;
    @try {
        if (![h performRequests:@[req] error:&err]) {
            YBLogSync(@"[OCR] 失败: %@", err.localizedDescription);
            self.lines = @[]; return;
        }
    } @catch (NSException *e) {
        YBLogSync(@"[OCR] 异常: %@", e.reason);
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
    YBSetTrace("ocr:done");
    YBLogSync(@"[OCR] %lu 行，用时 %.1fs (屏幕 %.0fx%.0f pt)", (unsigned long)out.count,
              [NSDate date].timeIntervalSince1970 - t0, self.pointSize.width, self.pointSize.height);
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