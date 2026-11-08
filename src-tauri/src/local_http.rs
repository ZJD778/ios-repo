//! iOS 本地回环 HTTP 服务（`http://127.0.0.1:<port>`）。
//!
//! 为什么非要有它：
//! iOS 上的 `<video>` 播放原生 HLS 时，媒体请求由 **AVFoundation** 直接发起，
//! 不经过 WKWebView 的 `WKURLSchemeHandler`。也就是说 `hg://localhost/hls?u=...`
//! 这个自定义协议在 `<img>` 上能出图（走 WebKit 网络栈），一旦塞给 `<video>`
//! 就永远收不到响应 —— 表现正是「封面墙正常、点开视频无限转圈」。
//!
//! 回环 HTTP 是 AVFoundation 唯一认的「本地」传输方式。用 `127.0.0.1` 而不是
//! `*.localhost`：后者在 iOS 14+ 会被当成 mDNS 服务发现，触发「查找本地网络
//! 设备」权限弹窗，用户一拒绝就永久黑屏；loopback 地址不触发该权限。
//!
//! 实现刻意不引入新依赖：std 阻塞 TcpListener + 每连接一线程，
//! 复用 [`crate::media::handle`] 的全部逻辑（封面 AES 解密、m3u8 改写、分片代理），
//! 只额外补上 AVFoundation 需要的 `Accept-Ranges` / `Content-Range`（拖进度条要用）。

#![cfg(target_os = "ios")]

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};

static PORT: AtomicU16 = AtomicU16::new(0);
static STARTED: AtomicBool = AtomicBool::new(false);

/// 当前回环服务基址；服务没起来时返回空串（前端会退回 `hg://localhost`）。
pub fn origin() -> String {
    let p = PORT.load(Ordering::Relaxed);
    if p == 0 {
        String::new()
    } else {
        format!("http://127.0.0.1:{}", p)
    }
}

/// 绑定 `127.0.0.1` 的随机空闲端口并开始 accept。可重复调用（幂等）。
pub fn start() {
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let listener = match TcpListener::bind(("127.0.0.1", 0)) {
        Ok(l) => l,
        Err(_) => {
            // 绑定失败时把标志复位，允许前端稍后重试
            STARTED.store(false, Ordering::SeqCst);
            return;
        }
    };
    let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
    if port == 0 {
        STARTED.store(false, Ordering::SeqCst);
        return;
    }
    PORT.store(port, Ordering::Relaxed);

    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || serve(stream));
        }
    });
}

/// 在 Tauri 的 tokio 运行时上跑媒体处理，同时阻塞当前连接线程等结果。
///
/// 不用 `tauri::async_runtime::block_on`：在 runtime 线程里再 block_on 会 panic
/// （嵌套 runtime）。这里 spawn 到 multi-thread runtime，用标准库 channel 把值
/// 取回；handler panic 时 recv 报错，调用方回 502，不让连接线程跟着炸。
fn media_response(path: String, query: String, base: String) -> Option<tauri::http::Response<Vec<u8>>> {
    let (tx, rx) = std::sync::mpsc::channel();
    tauri::async_runtime::spawn(async move {
        let resp = crate::media::handle(&path, &query, &base).await;
        let _ = tx.send(resp);
    });
    rx.recv().ok()
}

fn serve(mut stream: TcpStream) {
    let mut reader = match stream.try_clone() {
        Ok(s) => BufReader::new(s),
        Err(_) => return,
    };

    // ---- 请求行 ----
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() || request_line.is_empty() {
        return;
    }
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("").to_string();
    let target = parts.next().unwrap_or("/").to_string();
    if method.is_empty() || target.is_empty() {
        return;
    }
    let is_get = method.eq_ignore_ascii_case("GET");
    let is_head = method.eq_ignore_ascii_case("HEAD");
    if !is_get && !is_head {
        let _ = stream.write_all(
            b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
        return;
    }

    // ---- 头部：只留 Range，其余丢弃（读到空行为止）----
    let mut range: Option<String> = None;
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            break;
        }
        if let Some((name, value)) = trimmed.split_once(':') {
            if name.trim().eq_ignore_ascii_case("range") {
                range = Some(value.trim().to_string());
            }
        }
    }

    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p.to_string(), q.to_string()),
        None => (target, String::new()),
    };
    // ---- 复用媒体层（封面解密 / m3u8 改写 / 分片代理）----
    let base = origin();
    let resp = match media_response(path.clone(), query.clone(), base.clone()) {
        Some(r) => r,
        None => {
            let _ = stream.write_all(
                b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
            return;
        }
    };

    let status = resp.status().as_u16();
    let mut ctype = String::from("application/octet-stream");
    let mut cache = String::from("no-store");
    for (name, value) in resp.headers().iter() {
        let v = value.to_str().unwrap_or("").to_string();
        if name.as_str().eq_ignore_ascii_case("content-type") {
            ctype = v;
        } else if name.as_str().eq_ignore_ascii_case("cache-control") {
            cache = v;
        }
    }
    let body = resp.into_body();

    // ---- Range（AVFoundation 拉 fMP4 / 大分片时会带）----
    //
    // 只对媒体字节（/seg、/img）生效。播放列表故意不切：AVFoundation 会先用
    // `Range: bytes=0-1` 嗅探格式，若回一段被截断的 m3u8 又报 206，它会把那
    // 2 字节当完整播放列表解析，直接判定「无法播放」。播放列表本身几 KB，
    // 整段返回最稳。
    let total = body.len();
    let mut out_status = status;
    let mut start = 0usize;
    let mut end = total.saturating_sub(1);
    let mut content_range: Option<String> = None;
    let honor_range = path.starts_with("/seg") || path.starts_with("/img");

    if status == 200 && honor_range && total > 0 {
        if let Some((a, b)) = range.as_deref().and_then(|r| parse_range(r, total)) {
            out_status = 206;
            start = a;
            end = b;
            content_range = Some(format!("bytes {}-{}/{}", a, b, total));
        }
    }
    let slice: &[u8] = if total == 0 { &[] } else { &body[start..=end] };

    // ---- 响应 ----
    let mut head = String::with_capacity(360);
    head.push_str("HTTP/1.1 ");
    head.push_str(&out_status.to_string());
    head.push(' ');
    head.push_str(reason(out_status));
    head.push_str("\r\n");
    head.push_str("Content-Type: ");
    head.push_str(&ctype);
    head.push_str("\r\nContent-Length: ");
    head.push_str(&slice.len().to_string());
    head.push_str("\r\nAccept-Ranges: bytes");
    head.push_str("\r\nAccess-Control-Allow-Origin: *");
    head.push_str("\r\nAccess-Control-Expose-Headers: Content-Length, Content-Range, Accept-Ranges");
    head.push_str("\r\nCache-Control: ");
    head.push_str(&cache);
    if let Some(cr) = content_range {
        head.push_str("\r\nContent-Range: ");
        head.push_str(&cr);
    }
    head.push_str("\r\nConnection: close\r\n\r\n");

    let _ = stream.write_all(head.as_bytes());
    if is_get && !slice.is_empty() {
        let _ = stream.write_all(slice);
    }
    let _ = stream.flush();
}

/// 解析单段 `Range: bytes=a-b` / `bytes=a-` / `bytes=-n`，越界返回 None（走整段）。
fn parse_range(raw: &str, total: usize) -> Option<(usize, usize)> {
    if total == 0 {
        return None;
    }
    let spec = raw.trim().strip_prefix("bytes=")?;
    let spec = spec.split(',').next()?.trim();
    let (a, b) = spec.split_once('-')?;
    let (a, b) = (a.trim(), b.trim());

    if a.is_empty() {
        let suffix: usize = b.parse().ok()?;
        if suffix == 0 {
            return None;
        }
        return Some((total.saturating_sub(suffix), total - 1));
    }

    let start: usize = a.parse().ok()?;
    let end: usize = if b.is_empty() { total - 1 } else { b.parse().ok()? };
    if start > end || start >= total {
        return None;
    }
    Some((start, end.min(total - 1)))
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        206 => "Partial Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        416 => "Range Not Satisfiable",
        502 => "Bad Gateway",
        _ => "Error",
    }
}
