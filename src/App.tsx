import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { useStore, type Page, type Tab } from "./store";
import { selfTest, isIOS } from "./api";
import { addPluginListener, invoke } from "@tauri-apps/api/core";
import { runBack } from "./back";
import Home from "./pages/Home";
import Search, { RankPage } from "./pages/Search";
import Category, { ChannelPage } from "./pages/Category";
import Profile from "./pages/Profile";
import SettingsPage from "./pages/Settings";
import Feed from "./components/Feed";
import { PostsPage, PostDetail } from "./pages/Posts";
import LoginModal from "./components/LoginModal";
import { ToastHost } from "./components/ui";
import { DesktopRail, DesktopTitleBar } from "./components/DesktopChrome";
import ResizeHandles from "./components/ResizeHandles";
import { IGrid, IGridF, IHome, IHomeF, ISearch, ISearchF, IUser, IUserF, Logo } from "./icons";

/** 底部 TabBar 内容高度（不含 Home 指示条安全区）。
 *  49pt 是 iOS 原生 UITabBar 的标准高度，iPhone 13 Pro Max 上拇指刚好够到。
 *  Feed 的底部信息区、内容页的 pb-* 都要按这个数算，所以提成常量。 */
const TABBAR_H = 49;

/* ============ 底部标签栏（移动端：Android + iOS）============ *  iPhone 13 Pro Max 适配要点：
 *   - 逻辑分辨率 428×926pt、@3x；安全区 top 47pt（刘海）、bottom 34pt（Home 指示条）。
 *   - 内容高度固定 49pt —— 就是 iOS 原生 UITabBar 的高度，符合拇指习惯，
 *     也不会把 428pt 宽的底部压得太挤；34pt 的 Home 条区域只铺背景、不放控件。
 *   - 四个 item 等分 428pt = 107pt 一个，远超 44pt 的触控下限。
 *   - 图标 26pt + 标签 10pt，是 iOS 原生「图标在上、文字在下」的比例。
 *     带填充图标的选中态与未选中态同尺寸，切换时不会左右跳动。
 *   - 首页是沉浸视频 → 底栏压纯黑 + 无分隔线；其余页面用半透明深色 + 细线，
 *     并且加 backdrop-blur，滚动内容从底下透上来时像毛玻璃（原生观感）。
 */
function TabBar() {
  const { tab, setTab, theme, chromeHidden } = useStore();
  const items: { k: Tab; label: string; icon: ReactNode; iconOn: ReactNode }[] = [
    { k: "home", label: "首页", icon: <IHome size={25} />, iconOn: <IHomeF size={25} /> },
    { k: "search", label: "搜索", icon: <ISearch size={25} />, iconOn: <ISearchF size={25} /> },
    { k: "category", label: "分类", icon: <IGrid size={25} />, iconOn: <IGridF size={25} /> },
    { k: "profile", label: "我的", icon: <IUser size={25} />, iconOn: <IUserF size={25} /> },
  ];
  const overVideo = tab === "home";
  const lightBar = !overVideo && theme === "light";
  return (
    <nav className={`hg-tabbar absolute bottom-0 inset-x-0 z-30 ${chromeHidden ? "is-hidden" : ""}`}
      style={{
        paddingBottom: "var(--sab, 0px)",
        background: lightBar
          ? "rgba(249, 249, 249, .92)"
          : overVideo
            ? "rgba(0, 0, 0, .82)"
            : "rgba(22, 22, 22, .92)",
        backdropFilter: "saturate(180%) blur(22px)",
        WebkitBackdropFilter: "saturate(180%) blur(22px)",
        borderTop: lightBar
          ? "0.5px solid rgba(0, 0, 0, .12)"
          : overVideo
            ? "none"
            : "0.5px solid rgba(255, 255, 255, .10)",
      }}>
      <div className="h-[49px] flex items-stretch px-1">
        {items.map(({ k, label, icon, iconOn }) => {
          const on = tab === k;
          const tint = lightBar
            ? (on ? "var(--p-primary)" : "rgba(0, 0, 0, .42)")
            : (on ? "var(--p-primary)" : "rgba(255, 255, 255, .55)");
          return (
            <button key={k} onClick={() => setTab(k)} aria-label={label} aria-current={on ? "page" : undefined}
              className="flex-1 flex flex-col items-center justify-center gap-[3px] pressable">
              <span className="transition-colors duration-200" style={{ color: tint }}>{on ? iconOn : icon}</span>
              <span className="text-[10px] leading-none tracking-[.1px] transition-colors duration-200"
                style={{ color: tint, fontWeight: on ? 600 : 500 }}>
                {label}
              </span>
            </button>
          );
        })}
      </div>
    </nav>
  );
}

/* ============ 堆栈页面 ============ */
function StackPage({ page, onBack, wide, top, bottomInset }: {
  page: Page; onBack: () => void; wide: boolean; top: boolean; bottomInset: number;
}) {
  if (page.kind === "feed") {
    return (
      <Feed videoIds={page.videoIds} startIndex={page.index} title={page.title} kind={page.feedKind || "video"}
        startEp={page.startEp} startTime={page.startTime}
        mode="context" active={top} bottomInset={bottomInset} onBack={onBack} />
    );
  }
  if (page.kind === "channel") return <ChannelPage cate={page.cate} name={page.name} onBack={onBack} wide={wide} />;
  if (page.kind === "ranks") return <RankPage onBack={onBack} wide={wide} />;
  if (page.kind === "settings") return <SettingsPage onBack={onBack} wide={wide} />;
  if (page.kind === "posts") return <PostsPage onBack={onBack} wide={wide} />;
  if (page.kind === "post") return <PostDetail id={page.id} onBack={onBack} />;
  return null;
}

/* ============ 应用主体 ============ */
function AppBody() {
  const { platform, tab, setTab, stack, pop, loginOpen, setLoginOpen, fs } = useStore();
  const mainRef = useRef<HTMLDivElement>(null);
  const [wide, setWide] = useState(platform !== "android");
  const [collapsed, setCollapsed] = useState(false);

  useLayoutEffect(() => {
    const el = mainRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWide(el.clientWidth > 640));
    ro.observe(el);
    setWide(el.clientWidth > 640);
    return () => ro.disconnect();
  }, []);

  /* 全局键盘 */
  useEffect(() => {
    const fn = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) {
        if (e.key === "Escape") t.blur();
        return;
      }
      if (loginOpen) { if (e.key === "Escape") setLoginOpen(false); return; }
      if (e.key === "Escape") { if (stack.length) pop(); return; }
      if (e.key === "/") { e.preventDefault(); setTab("search"); return; }
      if (["1", "2", "3", "4"].includes(e.key) && !e.repeat) {
        setTab((["home", "search", "category", "profile"] as Tab[])[Number(e.key) - 1]);
      }
    };
    window.addEventListener("keydown", fn);
    return () => window.removeEventListener("keydown", fn);
  }, [stack.length, pop, setTab, loginOpen, setLoginOpen]);

  const vis = (k: Tab) => (tab === k ? "absolute inset-0" : "absolute inset-0 invisible pointer-events-none");
  const pageActive = stack.length === 0 && !loginOpen;
  /* 底栏高度：TabBar 固定 49pt 内容（iOS 原生 UITabBar 高度）。
     内容页底部要留出的空间 = 底栏 49 + 一点呼吸位，否则最后一行卡片会被压住。 */
  const bottomInset = platform === "android" ? (fs ? 0 : TABBAR_H) : 14;
  /* 栈页（从搜索/分类/我的进入的播放页、图文页）没有底栏，
     底部只让出安全区。之前多留了 20px，视频底边会露出一条
     「底栏」似的窄缝（底部的压暗渐变到不了屏幕最底）。 */
  const stackInset = platform === "android" ? 0 : 14;

  return (
    <div className={`absolute inset-0 flex bg-canvas plat-${platform}`}>
      {platform !== "android" && <DesktopRail collapsed={collapsed} />}
      <div ref={mainRef} className="relative flex-1 min-w-0 overflow-hidden win-main">
        <div className={vis("home")}><Home active={pageActive && tab === "home"} bottomInset={bottomInset} /></div>
        <div className={vis("search")}><Search active={pageActive && tab === "search"} wide={wide} /></div>
        <div className={vis("category")}><Category wide={wide} /></div>
        <div className={vis("profile")}><Profile wide={wide} /></div>

        {stack.map((p, i) => (
          <div key={p.key} className="absolute inset-0 z-30 bg-bg a-page-in" style={{ boxShadow: "-18px 0 40px rgba(0,0,0,.5)" }}>
            <StackPage page={p} onBack={pop} wide={wide} top={i === stack.length - 1} bottomInset={stackInset} />
          </div>
        ))}

        {platform === "android" && !fs && stack.length === 0 && <TabBar />}
      </div>
    </div>
  );
}

/* ============ 桌面窗口壳（Windows / macOS）============ */
function DesktopShell() {
  const [collapsed, setCollapsed] = useState(false);
  const { theater, platform } = useStore();
  return (
    <div className={`absolute inset-0 flex flex-col bg-canvas win-root plat-${platform}`}>
      <DesktopTitleBar collapsed={collapsed} onToggle={() => setCollapsed((c) => !c)} />
      <div className="relative flex-1 min-h-0">
        <ShellInner collapsed={collapsed || theater} theater={theater} />
      </div>
      {/* 边缘缩放热区只对无边框窗口（Windows）有效，macOS 走原生窗口边框 */}
      {platform === "windows" && <ResizeHandles />}
    </div>
  );
}

function ShellInner({ collapsed, theater }: { collapsed: boolean; theater: boolean }) {
  const { stack, pop, loginOpen, setLoginOpen, tab, setTab, platform } = useStore();
  const mainRef = useRef<HTMLDivElement>(null);
  const [wide, setWide] = useState(true);

  useLayoutEffect(() => {
    const el = mainRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWide(el.clientWidth > 640));
    ro.observe(el);
    setWide(el.clientWidth > 640);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const fn = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) {
        if (e.key === "Escape") t.blur();
        return;
      }
      if (loginOpen) { if (e.key === "Escape") setLoginOpen(false); return; }
      if (e.key === "Escape") { if (stack.length) pop(); return; }
      if (e.key === "/") { e.preventDefault(); setTab("search"); return; }
      if (["1", "2", "3", "4"].includes(e.key) && !e.repeat) {
        setTab((["home", "search", "category", "profile"] as Tab[])[Number(e.key) - 1]);
      }
    };
    window.addEventListener("keydown", fn);
    return () => window.removeEventListener("keydown", fn);
  }, [stack.length, pop, setTab, loginOpen, setLoginOpen]);

  const vis = (k: Tab) => (tab === k ? "absolute inset-0" : "absolute inset-0 invisible pointer-events-none");
  const pageActive = stack.length === 0 && !loginOpen;

  return (
    <div className={`absolute inset-0 flex bg-canvas plat-${platform}`}>
      {!theater && <DesktopRail collapsed={collapsed} />}
      <div ref={mainRef} className={`relative flex-1 min-w-0 overflow-hidden win-main ${theater ? "is-theater-main" : ""}`}>
        <div className={vis("home")}><Home active={pageActive && tab === "home"} bottomInset={14} /></div>
        <div className={vis("search")}><Search active={pageActive && tab === "search"} wide={wide} /></div>
        <div className={vis("category")}><Category wide={wide} /></div>
        <div className={vis("profile")}><Profile wide={wide} /></div>
        {stack.map((p, i) => (
          <div key={p.key} className="absolute inset-0 z-30 bg-bg win-page-in" style={{ boxShadow: "-18px 0 40px rgba(0,0,0,.5)" }}>
            <StackPage page={p} onBack={pop} wide={wide} top={i === stack.length - 1} bottomInset={14} />
          </div>
        ))}
      </div>
    </div>
  );
}

/* ============ 移动端（无壳） ============ */
function MobileShell() {
  return (
    <div className="absolute inset-0 flex flex-col bg-canvas plat-android"
      style={{
        /* WKWebView 全屏延伸时 env() 会给出真实安全区（灵动岛 ~59px / Home 条 ~34px）；
           若 WebView 被系统限制在安全区内，env() 为 0，此时也不需要大留白，
           只补一个最小呼吸位即可，避免顶部按钮贴着屏幕边缘。 */
        "--sat": `max(env(safe-area-inset-top, 0px), ${isIOS ? 20 : 8}px)`,
        "--sab": `max(env(safe-area-inset-bottom, 0px), ${isIOS ? 16 : 6}px)`,
        /* 横屏时刘海/圆角在左右两侧，播放页的操作按钮要避开 */
        "--sal": "env(safe-area-inset-left, 0px)",
        "--sar": "env(safe-area-inset-right, 0px)",
      } as React.CSSProperties}>
      <div className="relative flex-1 min-h-0">
        <AppBody />
      </div>
    </div>
  );
}

/* ============ 入口 ============ */
export default function App() {
  const { platform, loginOpen, setLoginOpen, tab, setTab, stack, pop, fs, setFs } = useStore();

  /* —— 安卓硬件返回键 ——
     层级：全屏 → 面板/弹层 → 登录框 → 页面栈 → 回首页 → 退出应用。
     不注册这个监听，Tauri 会直接 webView.goBack() 或退出，表现就是「任意页面返回都回桌面」。 */
  const backRef = useRef<() => void>(() => {});
  backRef.current = () => {
    if (fs) { setFs(false); return; }                        // 沉浸全屏
    if (document.fullscreenElement) { document.exitFullscreen().catch(() => {}); return; }
    if (runBack()) return;                                  // 播放器的选集/评论/图文面板
    if (loginOpen) { setLoginOpen(false); return; }
    if (stack.length) { pop(); return; }
    if (tab !== "home") { setTab("home"); return; }
    invoke("plugin:app|exit", { code: 0 }).catch(() => {});
  };

  useEffect(() => {
    // iOS 复用移动端布局，但没有安卓硬件返回键，跳过 back-button 监听。
    if (platform !== "android" || isIOS) return undefined;
    let disposed = false;
    let handle: { unregister: () => Promise<void> } | null = null;
    addPluginListener("app", "back-button", () => backRef.current())
      .then((l) => { if (disposed) l.unregister().catch(() => {}); else handle = l; })
      .catch(() => { /* 非安卓宿主忽略 */ });
    return () => {
      disposed = true;
      handle?.unregister().catch(() => {});
    };
  }, [platform]);

  useEffect(() => {
    const prevent = (e: Event) => e.preventDefault();
    document.addEventListener("contextmenu", prevent);
    return () => document.removeEventListener("contextmenu", prevent);
  }, []);

  useEffect(() => {
    if (!import.meta.env.DEV) return;
    const t = window.setTimeout(() => {
      selfTest().then((r) => { invoke("debug_log", { msg: r }).catch(() => {}); }).catch(() => {});
    }, 2500);
    return () => window.clearTimeout(t);
  }, []);

  return (
    <>
      {platform === "android" ? <MobileShell /> : <DesktopShell />}
      <LoginModal />
      <ToastHost />
      {/* 登录遮罩键盘处理占位 */}
      {loginOpen && <div className="hidden" onClick={() => setLoginOpen(false)} />}
    </>
  );
}