#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include "bindings/bindings.h"

/* HGhub iOS 原生入口。
 *
 * 这个文件解决两个只有真机才会出现的显示问题：
 *
 * ① 底部白色横条
 *    成因有四个，逐层修：
 *    a) UIWindow / rootViewController.view 是白的 —— 屏幕底部多出来的那一条露的
 *       就是它们。
 *    b) WKWebView 的 scrollView 被系统自动加了安全区 inset（默认
 *       scrollView.contentInsetAdjustmentBehavior == .automatic），于是
 *       「网页内容底边 → 屏幕底边」之间多出一块没人画的区域。
 *    c) WKWebView 有一层「页面下方背景」underPageBackgroundColor，在内容不足
 *       一屏 / 首帧还没绘制 / 下拉回弹时露出来，颜色恒为白；改 backgroundColor
 *       刷不掉它。
 *    d) 以上都改完仍可能有一条缝：WebView 的 frame 本身就不覆盖 Home 指示条区域。
 *       所以再在最底层垫一块不透明深色 backdrop 视图，任何缝隙都显示 #1a1a1a。
 *
 * ② WKWebView 自己给 scrollView 加 bottom inset
 *    关掉（.never），安全区完全交给 CSS 的 env(safe-area-inset-*)，布局才和
 *    Android / 桌面端一致。
 *
 * ⚠️ 绝对不要用 opaque=NO / clearColor，也不要递归修改 WebView 内部视图层级。
 *    iOS 视频一开始播放，WKWebView 会切到硬件解码的独立合成层；透明父层会让
 *    整个内容层被丢弃，表现为「声音还在、上下滑动还能切集、但画面和所有按钮
 *    全部消失」的真机黑屏。早期版本就是这么做的，已回退。
 *    现在一律赋「不透明深色」，只改 backgroundColor / 背景视图，不动
 *    webView.opaque / alpha / hidden。
 *
 * 实现约束：这里**不 import WebKit**，也不引用 WKWebView 类符号。
 *   Rust 侧产出的是静态库（libapp.a），静态库无法把「链接 WebKit.framework」
 *   这个指令传给 xcodebuild；一旦在 ObjC 里写 [WKWebView class]，链接阶段就会
 *   undefined symbol _OBJC_CLASS_$_WKWebView。所以全部用鸭子类型
 *   （respondsToSelector / valueForKey）识别并操作 WebView，零链接依赖。
 *
 * 该文件由 scripts/build-ios-ipa.sh 覆盖到 gen/apple 下所有 main.mm；
 * gen/apple 被 .gitignore，重新执行 `tauri ios init` 后需要重新应用。
 * 构建脚本末尾会校验二进制里存在 HGhubBackdrop 字面量，缺失即报错，
 * 避免「补丁没生效但构建成功」这种最难查的情况。
 */

/* 固定为应用默认主题色 #1a1a1a。
   注意两点：① 必须用静态颜色，动态颜色（colorWithDynamicProvider）赋给
   UIWindow.backgroundColor 时缺少 trait 解析环境，实际仍渲染成白色；
   ② 不要跟随系统明暗：应用主题由前端 localStorage 控制，系统浅色 + 应用深色时
   会露出 #f3f3f3 浅灰条，视觉上依旧像「白条」。原生层读不到前端主题，
   统一用默认深色最稳（另外 Info.plist 里 UIUserInterfaceStyle=Dark 兜底）。 */
static UIColor *HGThemeBackground(void) {
  return [UIColor colorWithRed:0.102 green:0.102 blue:0.102 alpha:1.0];
}

/* 在容器最底层垫一块不透明深色视图，尺寸永远跟容器一致。
   用 restorationIdentifier 做标记，重复调用不会叠加。 */
static void HGEnsureBackdrop(UIView *container, UIColor *bg) {
  if (container == nil) return;
  for (UIView *sub in container.subviews) {
    if ([sub.restorationIdentifier isEqualToString:@"HGhubBackdrop"]) {
      sub.frame = container.bounds;
      sub.backgroundColor = bg;
      return;
    }
  }
  UIView *backdrop = [[UIView alloc] initWithFrame:container.bounds];
  backdrop.restorationIdentifier = @"HGhubBackdrop";
  backdrop.backgroundColor = bg;
  backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  backdrop.userInteractionEnabled = NO;
  [container insertSubview:backdrop atIndex:0];
}

/* 鸭子类型判断：唯一响应 scrollView、且 scrollView 是 UIScrollView 的视图就是
   WKWebView。不引用 WKWebView 类符号，避免静态库链接问题。 */
static UIScrollView *HGWebScrollView(UIView *view) {
  if (![view respondsToSelector:NSSelectorFromString(@"scrollView")]) return nil;
  id sv = [view valueForKey:@"scrollView"];
  return [sv isKindOfClass:[UIScrollView class]] ? (UIScrollView *)sv : nil;
}

/* 把一个 WKWebView 的几层背景全部刷成不透明深色。 */
static void HGTintWebView(UIView *web, UIColor *bg) {
  UIScrollView *scroll = HGWebScrollView(web);
  if (scroll == nil) return;

  web.backgroundColor = bg;
  scroll.backgroundColor = bg;

  /* 内容不足一屏 / 首帧未绘制 / 回弹时露出的白色底层。iOS 15+ 公开属性，
     本项目 minimumSystemVersion 正是 15.0，KVC 赋值不需要 WebKit 头文件。 */
  SEL sel = NSSelectorFromString(@"setUnderPageBackgroundColor:");
  if ([web respondsToSelector:sel]) {
    [web setValue:bg forKey:@"underPageBackgroundColor"];
  }

  /* 安全区交给 CSS，关掉系统自动 inset，否则底部会多一块 WebView 留白。 */
  scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  /* 回弹本身不动（改了会明显改变手感）：回弹时露出的是上面已刷过的
     underPageBackgroundColor / backgroundColor，不再是白色。 */
}

/* 递归找 WKWebView（正常只有一个），找到就 tint 并停止下探；
   顺路给纯容器视图铺底色，保证 WebView 与屏幕边缘之间没有白缝。 */
static void HGWalk(UIView *view, UIColor *bg, int depth) {
  if (view == nil || depth > 6) return;
  if (HGWebScrollView(view) != nil) {
    HGTintWebView(view, bg);
    return;
  }
  for (UIView *sub in view.subviews) {
    if (HGWebScrollView(sub) != nil) {
      HGTintWebView(sub, bg);
      continue;
    }
    /* 只给「看起来是容器」的普通视图铺底：不放宽到所有视图，
       免得把图标 / 遮罩 / 输入框也染成深色。 */
    NSString *cls = NSStringFromClass([sub class]);
    if ([cls isEqualToString:@"UIView"] || [cls containsString:@"Container"]) {
      sub.backgroundColor = bg;
    }
    HGWalk(sub, bg, depth + 1);
  }
}

static void HGApplyBackground(void) {
  UIColor *bg = HGThemeBackground();
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      /* 只处理普通层级的应用窗口，跳过状态栏 / 键盘 / 视频全屏播放器等高层窗口，
         避免把不透明背景盖到内容上面（那会挡住整个 WebView）。 */
      if (window.windowLevel != UIWindowLevelNormal) continue;
      UIViewController *vc = window.rootViewController;
      if (vc == nil) continue;

      window.backgroundColor = bg;
      vc.view.backgroundColor = bg;
      /* (d)：最底层垫一块深色，任何几何缝隙都不会露出白色。 */
      HGEnsureBackdrop(vc.view, bg);
      /* (a)(b)(c)：WebView 自身几层背景 + 关掉自动安全区 inset。 */
      HGWalk(vc.view, bg, 0);
    }
  }
}

/* start_app() 会接管主线程，不能在它之后同步刷新。
   这里只做 backgroundColor / frame / 背景视图赋值：幂等、不改 opaque、不动
   视图层级顺序，即使在视频播放期间执行也安全。
   多次延迟是为了覆盖 Tauri 异步创建 WKWebView、首屏资源加载完成、
   以及旋转 / 重建内部视图等时机。 */
static void HGScheduleBackgroundRefresh(void) {
  for (NSNumber *delay in @[@0.05, @0.15, @0.35, @0.8, @1.5, @2.5, @4.0]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ HGApplyBackground(); });
  }
}

__attribute__((constructor))
static void HGSetupBackground(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    /* 主 runloop 起来之后再开方向通知：constructor 阶段 UIDevice 可能还没初始化完，
       而且不发这一句 UIDeviceOrientationDidChangeNotification 永远不会触发。 */
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    HGScheduleBackgroundRefresh();
  });

  /* 回前台、旋转后都重新刷一遍（几何变了，backdrop 要重新拉满）。 */
  NSArray<NSNotificationName> *events = @[
    UIApplicationDidBecomeActiveNotification,
    UIApplicationDidChangeStatusBarOrientationNotification,
    UIDeviceOrientationDidChangeNotification,
  ];
  for (NSNotificationName name in events) {
    [[NSNotificationCenter defaultCenter]
      addObserverForName:name
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification * _Nonnull note) { HGScheduleBackgroundRefresh(); }];
  }
}

int main(int argc, char * argv[]) {
	ffi::start_app();
	return 0;
}
