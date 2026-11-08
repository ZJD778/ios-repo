import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { AppProvider } from "./store";
import { invoke } from "@tauri-apps/api/core";
import { setMediaOrigin } from "./api";
import "./index.css";

/* 运行期错误统一落到 debug.log，便于自查 */
function report(kind: string, msg: string) {
  invoke("debug_log", { msg: `[${kind}] ${msg}` }).catch(() => {});
}
window.addEventListener("error", (e) => {
  report("error", `${e.message} @ ${e.filename}:${e.lineno}:${e.colno}`);
});
window.addEventListener("unhandledrejection", (e) => {
  report("reject", String((e.reason && (e.reason.stack || e.reason.message)) || e.reason));
});

/* 媒体基址必须在任何组件挂载前取到。
   iOS 的视频走 Rust 侧起的回环 HTTP（端口随机），拿不到就只能退回 hg://，
   而 AVFoundation 不认自定义协议 —— 结果就是「封面有、视频无限转圈」。
   所以这里先 await 一次（毫秒级），再渲染。失败不阻塞启动。 */
async function bootstrap() {
  try {
    const origin = await invoke<string>("media_origin");
    if (origin) {
      setMediaOrigin(origin);
      report("boot", `media origin = ${origin}`);
    }
  } catch (e) {
    report("boot", `media_origin failed: ${String(e)}`);
  }

  ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <AppProvider>
        <App />
      </AppProvider>
    </React.StrictMode>,
  );
}

void bootstrap();
