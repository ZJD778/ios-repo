//! iOS 原生能力：屏幕方向 + 系统状态栏显隐。
//!
//! WebView 内部改不了这两样，必须落到 UIKit：
//!
//! * **方向**：iOS 16+ 用官方 `UIWindowScene.requestGeometryUpdateWithPreferences:errorHandler:`；
//!   iOS 15 没有这个 API（app 最低支持 15.0），退回 `UIDevice` 的 KVC 写法
//!   （`setValue:forKey:@"orientation"` + `attemptRotationToDeviceOrientation`）。
//!   同时给根控制器的**类**补一个动态的 `supportedInterfaceOrientations`，
//!   否则系统会按固定的 Info.plist 掩码拒绝我们请求的方向。
//!
//! * **状态栏**：给根控制器的**类**补 `prefersStatusBarHidden`，返回值读全局原子量。
//!   只挂当前 VC 的类，不 swizzle `UIViewController`，键盘、分享面板等不受影响。
//!
//! Tauri command 不保证在主线程执行，而 UIKit 只能在主线程碰，所以所有操作
//! 统一经 `dispatch_async_f` 派到 main queue。用 `dispatch_async_f` 而非
//! `dispatch_async`，是为了派发这一步不依赖 block 的 Rust 表示。
//!
//! 为什么不用 main.mm：那是最外层 ObjC 入口，Rust 静态库引用主可执行文件里的
//! C 符号在 iOS 链接时不可靠；这里直接用 objc2 发消息，没有跨模块符号。

#![cfg(target_os = "ios")]

use objc2::msg_send;
use objc2::runtime::{AnyClass, AnyObject, Bool, Imp, Sel};
use std::ffi::{c_void, CStr};
use std::os::raw::c_char;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// 状态栏是否隐藏。由 [`set_status_bar`] 写，由挂到 VC 上的方法读。
static STATUS_HIDDEN: AtomicBool = AtomicBool::new(false);
/// `UIInterfaceOrientationMask`：2 = Portrait，24 = LandscapeLeft | LandscapeRight。
static ORIENTATION_MASK: AtomicUsize = AtomicUsize::new(2);

unsafe extern "C" {
    // `dispatch_get_main_queue()` 在新 SDK 里是宏，所产生的符号被 ld 隐藏了，
    // 直接链接会报 undefined symbol；改用它实际返回的全局队列对象。
    static _dispatch_main_q: c_void;
    fn dispatch_async_f(queue: *const c_void, context: *mut c_void, work: unsafe extern "C" fn(*mut c_void));
    // objc2 0.6 没有暴露动态加方法的封装，这里直接用 Objective-C runtime。
    // class_replaceMethod 在类本身没有该方法时等价于 class_addMethod，
    // 正好省掉一次 `instance_method` 查询。
    fn class_replaceMethod(cls: *const AnyClass, name: Sel, imp: Imp, types: *const c_char) -> Imp;
}

enum UiAction {
    StatusBar(bool),
    Orientation(bool),
}

/// 把 UIKit 操作放到主线程。context 是一个 Box，回调里负责回收。
unsafe extern "C" fn hg_apply_on_main(ctx: *mut c_void) {
    let action = Box::from_raw(ctx as *mut UiAction);
    match *action {
        UiAction::StatusBar(hidden) => apply_status_bar(hidden),
        UiAction::Orientation(landscape) => apply_orientation(landscape),
    }
}

fn on_main(action: UiAction) {
    let ctx = Box::into_raw(Box::new(action)) as *mut c_void;
    unsafe {
        dispatch_async_f(&_dispatch_main_q as *const c_void, ctx, hg_apply_on_main);
    }
}

/* ── 根控制器 / WindowScene ─────────────────────────────── */

unsafe fn foreground_scene() -> *mut AnyObject {
    let app: *mut AnyObject = msg_send![objc2::class!(UIApplication), sharedApplication];
    if app.is_null() {
        return std::ptr::null_mut();
    }
    let scenes: *mut AnyObject = msg_send![app, connectedScenes];
    if scenes.is_null() {
        return std::ptr::null_mut();
    }
    let enumerator: *mut AnyObject = msg_send![scenes, objectEnumerator];
    if enumerator.is_null() {
        return std::ptr::null_mut();
    }
    loop {
        let scene: *mut AnyObject = msg_send![enumerator, nextObject];
        if scene.is_null() {
            break;
        }
        let is_window_scene: Bool = msg_send![scene, isKindOfClass: objc2::class!(UIWindowScene)];
        if !is_window_scene.as_bool() {
            continue;
        }
        let windows: *mut AnyObject = msg_send![scene, windows];
        if windows.is_null() {
            continue;
        }
        let count: usize = msg_send![windows, count];
        if count > 0 {
            return scene;
        }
    }
    std::ptr::null_mut()
}

unsafe fn root_view_controller() -> *mut AnyObject {
    let scene = foreground_scene();
    if scene.is_null() {
        return std::ptr::null_mut();
    }
    let windows: *mut AnyObject = msg_send![scene, windows];
    let window: *mut AnyObject = msg_send![windows, firstObject];
    if window.is_null() {
        return std::ptr::null_mut();
    }
    msg_send![window, rootViewController]
}

/* ── 给根控制器的类动态挂两个 appearance 方法 ────────────── */

/// 签名 `BOOL (id, SEL)`，类型编码 `B@:`。
unsafe extern "C-unwind" fn hg_prefers_status_bar_hidden(
    _this: &AnyObject,
    _cmd: Sel,
) -> Bool {
    Bool::new(STATUS_HIDDEN.load(Ordering::Relaxed))
}

/// 签名 `NSUInteger (id, SEL)`，类型编码 `Q@:`。
unsafe extern "C-unwind" fn hg_supported_orientations(
    _this: &AnyObject,
    _cmd: Sel,
) -> usize {
    ORIENTATION_MASK.load(Ordering::Relaxed)
}

unsafe fn add_or_replace(cls: &AnyClass, sel: Sel, imp: Imp, types: &CStr) {
    class_replaceMethod(cls as *const AnyClass, sel, imp, types.as_ptr());
}

/// 幂等：VC 的类已有该方法的实现就替换，没有就新增。
unsafe fn install_overrides() {
    let vc = root_view_controller();
    if vc.is_null() {
        return;
    }
    let cls: *const AnyClass = msg_send![vc, class];
    if cls.is_null() {
        return;
    }
    let cls = &*cls;

    let status_imp: Imp = std::mem::transmute(
        hg_prefers_status_bar_hidden
            as unsafe extern "C-unwind" fn(&AnyObject, Sel) -> Bool,
    );
    add_or_replace(cls, objc2::sel!(prefersStatusBarHidden), status_imp, c"B@:");

    let orient_imp: Imp = std::mem::transmute(
        hg_supported_orientations
            as unsafe extern "C-unwind" fn(&AnyObject, Sel) -> usize,
    );
    add_or_replace(cls, objc2::sel!(supportedInterfaceOrientations), orient_imp, c"Q@:");
}

/* ── 状态栏 ────────────────────────────────────────────── */

unsafe fn apply_status_bar(hidden: bool) {
    STATUS_HIDDEN.store(hidden, Ordering::Relaxed);
    let vc = root_view_controller();
    if vc.is_null() {
        return;
    }
    install_overrides();
    let _: () = msg_send![vc, setNeedsStatusBarAppearanceUpdate];
}

/// 显示 / 隐藏系统状态栏。iOS 15+ 走 VC 的 appearance 回调，不需要私有 API。
pub fn set_status_bar(hidden: bool) -> Result<(), String> {
    on_main(UiAction::StatusBar(hidden));
    Ok(())
}

/* ── 屏幕方向 ──────────────────────────────────────────── */

unsafe fn apply_orientation(landscape: bool) {
    let mask: usize = if landscape { 24 } else { 2 };
    ORIENTATION_MASK.store(mask, Ordering::Relaxed);

    let vc = root_view_controller();
    if !vc.is_null() {
        install_overrides();
        let _: () = msg_send![vc, setNeedsUpdateOfSupportedInterfaceOrientations];
    }

    let scene = foreground_scene();
    if !scene.is_null() {
        let sel = objc2::sel!(requestGeometryUpdateWithPreferences:errorHandler:);
        let responds: Bool = msg_send![scene, respondsToSelector: sel];
        if responds.as_bool() {
            if let Some(prefs_cls) = AnyClass::get(c"UIWindowSceneGeometryPreferencesIOS") {
                let raw: *mut AnyObject = msg_send![prefs_cls as *const AnyClass as *mut AnyObject, alloc];
                if !raw.is_null() {
                    let prefs: *mut AnyObject = msg_send![raw, initWithInterfaceOrientations: mask];
                    // errorHandler 需要一个真实 block：传 nil 在失败回调时可能被直接调用而崩溃。
                    let handler = block2::RcBlock::new(|_err: *mut AnyObject| {});
                    let block: *const block2::Block<dyn Fn(*mut AnyObject)> = &*handler;
                    let _: () = msg_send![
                        scene,
                        requestGeometryUpdateWithPreferences: prefs,
                        errorHandler: block as *mut c_void
                    ];
                    let _: () = msg_send![prefs, release];
                }
            }
            return;
        }
    }

    // iOS 15 兜底：UIDevice KVC。值取 UIInterfaceOrientation
    // （1 = Portrait，3 = LandscapeRight）。
    let device: *mut AnyObject = msg_send![objc2::class!(UIDevice), currentDevice];
    if device.is_null() {
        return;
    }
    let key: *mut AnyObject = msg_send![
        objc2::class!(NSString),
        stringWithUTF8String: c"orientation".as_ptr()
    ];
    let value: *mut AnyObject = msg_send![
        objc2::class!(NSNumber),
        numberWithInt: if landscape { 3i32 } else { 1i32 }
    ];
    let _: () = msg_send![device, setValue: value, forKey: key];
    let _: () = msg_send![
        objc2::class!(UIViewController),
        attemptRotationToDeviceOrientation
    ];
}

/// 切换横竖屏。`landscape = true` → 左右横屏，`false` → 竖屏。
pub fn set_orientation(landscape: bool) -> Result<(), String> {
    on_main(UiAction::Orientation(landscape));
    Ok(())
}

#[tauri::command]
pub fn set_orientation_cmd(landscape: bool) -> Result<(), String> {
    set_orientation(landscape)
}

#[tauri::command]
pub fn set_status_bar_cmd(hidden: bool) -> Result<(), String> {
    set_status_bar(hidden)
}
