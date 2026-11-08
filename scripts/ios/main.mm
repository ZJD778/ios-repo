#import <UIKit/UIKit.h>
#include "bindings/bindings.h"

/* HGhub iOS 原生入口。
 *
 * 背景：WKWebView 在带 Home 指示条的 iPhone 上，底部会露出一大块白色区域。
 * WKWebView 铺满屏幕，但网页内容只画到安全区，下面露出 WebView 自身（以及
 * 其 scrollView）的白色背景，CSS 覆盖不到，所以要在原生侧把这几层刷成深色。
 *
 * ⚠️ 绝对不要用 opaque=NO / clearColor，也不要递归修改 WebView 内部视图层级。
 *    iOS 视频一开始播放，WKWebView 会切到硬件解码的独立合成层；透明父层会让
 *    整个内容层被丢弃，表现为「声音还在、上下滑动还能切集、但画面和所有按钮
 *    全部消失」的真机黑屏。早期版本就是这么做的，已回退。
 *    现在一律赋「不透明深色」，只改 backgroundColor，不动 opaque / alpha / hidden。
 *
 * 该文件由 scripts/build-ios-ipa.sh 复制到 gen/apple/Sources 下；
 * gen/apple 被 .gitignore，重新执行 `tauri ios init` 后需要重新应用。
 */

/* 固定为应用默认主题色 #1a1a1a。
   注意两点：① 必须用静态颜色，动态颜色（colorWithDynamicProvider）赋给
   UIWindow.backgroundColor 时缺少 trait 解析环境，实际仍渲染成白色；
   ② 不要跟随系统明暗：应用主题由前端 localStorage 控制，系统浅色 + 应用深色时
   会露出 #f3f3f3 浅灰条，视觉上依旧像「白条」。原生层读不到前端主题，
   统一用默认深色最稳。 */
static UIColor *HGThemeBackground(void) {
  return [UIColor colorWithRed:0.102 green:0.102 blue:0.102 alpha:1.0];
}

/* 找到 WKWebView（唯一响应 `scrollView` 的视图），把它和 scrollView 的底色
   直接染成不透明深色 —— 这是消掉底部白条的关键一步。找到即停，不进入
   WebView 内部子视图，避免碰到承载网页合成的私有 view。 */
static void HGTintWebViewBackground(UIView *view, UIColor *bg) {
  if ([view respondsToSelector:NSSelectorFromString(@"scrollView")]) {
    id sv = [view valueForKey:@"scrollView"];
    if ([sv isKindOfClass:[UIScrollView class]]) {
      view.backgroundColor = bg;
      ((UIScrollView *)sv).backgroundColor = bg;
      return;
    }
  }
  for (UIView *sub in view.subviews) HGTintWebViewBackground(sub, bg);
}

static void HGApplyBackground(void) {
  UIColor *bg = HGThemeBackground();
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
      /* 只处理普通层级的应用窗口，跳过状态栏/键盘/视频全屏播放器等高层窗口，
         避免把不透明背景盖到内容上面（那会挡住整个 WebView）。 */
      if (window.windowLevel != UIWindowLevelNormal) continue;
      UIViewController *vc = window.rootViewController;
      if (vc == nil) continue;
      window.backgroundColor = bg;
      vc.view.backgroundColor = bg;
      HGTintWebViewBackground(vc.view, bg);
    }
  }
}

/* start_app() 会接管主线程，不能在它之后同步刷新。
   只做 backgroundColor 赋值：幂等、不改 opaque、不动视图层级，
   即使在视频播放期间执行也安全。覆盖 Tauri 异步创建 WKWebView 的时机。 */
static void HGScheduleBackgroundRefresh(void) {
  for (NSNumber *delay in @[@0.05, @0.15, @0.35, @0.8, @1.5]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ HGApplyBackground(); });
  }
}

__attribute__((constructor))
static void HGSetupBackground(void) {
  dispatch_async(dispatch_get_main_queue(), ^{ HGScheduleBackgroundRefresh(); });
  [[NSNotificationCenter defaultCenter]
    addObserverForName:UIApplicationDidBecomeActiveNotification
                object:nil
                 queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification * _Nonnull note) { HGScheduleBackgroundRefresh(); }];
}

int main(int argc, char * argv[]) {
	ffi::start_app();
	return 0;
}
