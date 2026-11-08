#!/usr/bin/env bash
# Build an UNSIGNED arm64 device IPA for TrollStore / SideStore / AltStore.
#
# Why this exists:
#   `tauri ios build` insists on archive + export signing, which requires a
#   logged-in Apple account and a provisioning profile. TrollStore (and
#   SideStore) sign on-device anyway, so the IPA itself does not need to be
#   signed. This script links a device build with CODE_SIGNING_ALLOWED=NO and
#   wraps it into the standard Payload/*.app layout.
#
# Three non-obvious requirements:
#   1. `--features tauri/custom-protocol` is required. Without it Tauri's
#      codegen takes the `dev` branch (devUrl is configured) and embeds EMPTY
#      assets, so the app would launch to a blank screen on a real device.
#   2. The generated Xcode project has a "Build Rust Code" phase that talks to
#      the Tauri CLI over a local WebSocket. It only works when the CLI itself
#      is driving the build, so we temporarily replace it with a no-op and
#      restore the project file afterwards (trap guarantees cleanup).
#   3. The iOS native entry (scripts/ios/main.mm) must replace the template one,
#      and Info.plist must allow loopback HTTP — otherwise the video player
#      blacks out (white bar + AVFoundation refusing hg:// URLs).
#      Both patches are verified after linking; a missing symbol fails the build
#      instead of silently producing a broken IPA.
#
# Usage:  pnpm ios:ipa
#         bash scripts/build-ios-ipa.sh
#         IPA_OUT=/path/to/custom.ipa bash scripts/build-ios-ipa.sh
#
# Environment:
#   IPA_OUT                 output path (default: ./HGhub-unsigned.ipa)
#   HG_IOS_NO_SWIFT_SHIM=1  skip the SwiftPM sandbox workaround

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAURI_DIR="$ROOT/src-tauri"
GEN="$TAURI_DIR/gen/apple"
PBX="$GEN/huangguo-client.xcodeproj/project.pbxproj"
TMP="${TMPDIR:-/tmp}"
SHIM_DIR="$TMP/hghub-ios-bin"
DD="$TMP/hghub-ios-dd-release"
OUT="${IPA_OUT:-$ROOT/HGhub-unsigned.ipa}"

# --- prerequisites ---------------------------------------------------------
# rustup installs cargo into ~/.cargo/bin, so load it before the command checks.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
if [ ! -f "$PBX" ]; then
  echo "ERROR: iOS Xcode project not found at $GEN" >&2
  echo "       Run 'pnpm tauri ios init' once before using this script." >&2
  exit 1
fi
for cmd in pnpm cargo rustup xcodebuild python3 plutil; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done

# --- toolchain -------------------------------------------------------------
# Some SwiftPM / Xcode combinations cannot apply the generated sandbox profile
# (`sandbox_apply: Operation not permitted`). swift-rs invokes `swift build`
# from its build script, so a shim adds --disable-sandbox to SwiftPM
# subcommands only, leaving plain compiler invocations untouched.
# Opt out with HG_IOS_NO_SWIFT_SHIM=1 if your toolchain does not need it.
if [ "${HG_IOS_NO_SWIFT_SHIM:-0}" != "1" ]; then
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/swift" <<'SHIM'
#!/bin/bash
REAL_SWIFT="$(xcrun --find swift)"
for a in "$@"; do
  if [ "$a" = "--disable-sandbox" ]; then exec "$REAL_SWIFT" "$@"; fi
done
case "$1" in
  build|package|test|run) exec "$REAL_SWIFT" "$@" --disable-sandbox ;;
  *) exec "$REAL_SWIFT" "$@" ;;
esac
SHIM
  chmod +x "$SHIM_DIR/swift"
  export PATH="$SHIM_DIR:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
else
  export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
fi

# 不要写 `rustup target list --installed | grep -qx "$t"`：pipefail 下 grep -q
# 命中即关管道，rustup 吃 SIGPIPE 后整条管道返回 141，会被误判成「没装」。
INSTALLED_TARGETS="$(rustup target list --installed)"
for t in aarch64-apple-ios; do
  case "$INSTALLED_TARGETS" in
    *"$t"*) ;;
    *) rustup target add "$t" ;;
  esac
done

# --- iOS 原生入口补丁 -----------------------------------------------------
# gen/apple 被 .gitignore，重新 `tauri ios init` 会还原成默认 main.mm。
# Tauri 模板里 main.mm 的位置随版本变过，所以把 gen/apple 下所有 main.mm 都覆盖，
# 一个都找不到就报错（宁可失败，也不要产出一个白条还在的 IPA）。
echo "==> Applying iOS native entry patch"
MAIN_MM_COUNT=0
while IFS= read -r f; do
  cp "$ROOT/scripts/ios/main.mm" "$f"
  MAIN_MM_COUNT=$((MAIN_MM_COUNT + 1))
  echo "    patched: ${f#$GEN/}"
done < <(find "$GEN" -name 'main.mm' -type f)

if [ "$MAIN_MM_COUNT" -eq 0 ]; then
  echo "ERROR: no main.mm found under $GEN" >&2
  echo "       Your Tauri CLI version generates a different iOS entry." >&2
  find "$GEN" -name '*.mm' -o -name '*.m' -o -name '*.swift' | head -20 >&2 || true
  exit 1
fi

# --- Info.plist：放行回环 HTTP --------------------------------------------
# iOS 的 AVFoundation 不认 hg:// 自定义协议，视频走 http://127.0.0.1:<port>。
# 两层例外都给上（ATS 本身已豁免 127.0.0.1，但不同系统版本的判定有差异，
# NSAllowsLocalNetworking 兜底不会放宽公网）：
#   NSAllowsLocalNetworking       —— 放行本地/回环地址
#   NSAllowsArbitraryLoadsInMedia —— 专门豁免 AVFoundation 的媒体加载（iOS 10+），
#                                    <video> 拉 HLS 走的就是这条路径
# 127.0.0.1 属于 loopback，不触发「查找本地网络设备」权限弹窗；
# 千万不要改回 *.localhost —— 那会被当成 mDNS 探测，用户一拒就永久黑屏。
echo "==> Patching Info.plist (ATS local networking)"
PLISTS="$(find "$GEN" -name 'Info.plist' -type f)"
if [ -z "$PLISTS" ]; then
  echo "ERROR: no Info.plist found under $GEN" >&2
  exit 1
fi
while IFS= read -r plist; do
  [ -n "$plist" ] || continue
  /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$plist"
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
  # iOS 10+ 的键名是 NSAllowsArbitraryLoadsForMedia（iOS 9 的 InMedia 已废弃），
  # 专门豁免 AVFoundation 的媒体加载 —— <video> 拉 HLS 走的就是这条路径。
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoadsForMedia bool true" "$plist"
  # 刻意不写 NSAllowsArbitraryLoads：它的存在会让上面的细粒度键在 iOS 10+ 失效，
  # 而全局放开 HTTPS 既不必要也不安全。这里只放开回环 + 媒体两条。
  # 强制 UIKit 用深色外观：系统默认背景、键盘、滚动条底衬都跟着变暗，
  # 不再有「某层忘记刷色就是一条白」的漏网之鱼。应用自己的浅色主题由前端
  # localStorage 控制，与 UIKit 外观无关。
  /usr/libexec/PlistBuddy -c "Delete :UIUserInterfaceStyle" "$plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :UIUserInterfaceStyle string Dark" "$plist"
  echo "    patched: ${plist#$GEN/}"
done <<< "$PLISTS"

# --- frontend + Rust device library ---------------------------------------
echo "==> Building frontend"
(cd "$ROOT" && pnpm build >/dev/null)

echo "==> Building arm64 iOS device library (release + custom-protocol)"
(
  cd "$TAURI_DIR"
  cargo build --target aarch64-apple-ios --release --lib \
    --features tauri/custom-protocol 2>&1 | tail -20
  mkdir -p "$GEN/Externals/arm64/release"
  cp target/aarch64-apple-ios/release/libhuangguo_client_lib.a \
    "$GEN/Externals/arm64/release/libapp.a"
)

if ! grep -aq "/assets/index-" "$GEN/Externals/arm64/release/libapp.a"; then
  echo "ERROR: frontend assets were not embedded in libapp.a" >&2
  exit 1
fi

# --- temporarily neutralise the CLI-driven build phase --------------------
BACKUP="$PBX.ipa-backup"
cp "$PBX" "$BACKUP"
trap 'mv -f "$BACKUP" "$PBX"' EXIT
python3 - "$PBX" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
new, n = re.subn(
    r'(?m)^(\s*shellScript = ).*tauri ios xcode-script.*$',
    r'\1"echo \"Using prebuilt device libapp.a\"";',
    s,
)
if n != 1:
    sys.exit(f"expected exactly 1 Build Rust Code script line, found {n}")
open(p, "w", encoding="utf-8").write(new)
PY

# --- link (no signing) ----------------------------------------------------
echo "==> Linking unsigned device app"
rm -rf "$DD"
(
  cd "$GEN"
  xcodebuild \
    -project huangguo-client.xcodeproj \
    -scheme huangguo-client_iOS \
    -configuration release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual \
    ENABLE_DEBUG_DYLIB=NO build 2>&1 | tail -12
)

APP="$DD/Build/Products/release-iphoneos/HGhub.app"
[ -f "$APP/HGhub" ] || { echo "ERROR: HGhub.app was not produced" >&2; exit 1; }
grep -aq "/assets/index-" "$APP/HGhub" || {
  echo "ERROR: frontend assets missing from final binary" >&2; exit 1; }

# --- 校验原生补丁真的进了二进制 -------------------------------------------
echo "==> Verifying native patches"
# release 档 strip=true，符号名保不住，所以查「只在补丁里出现」的字符串字面量：
#   HGhubBackdrop        → scripts/ios/main.mm 的垫底层（白条修复）
#   Accept-Ranges: bytes → src-tauri/src/local_http.rs 的回环服务
#
# 两个坑都要绕开：
#  ① 不要写 `strings ... | grep -q`：grep -q 命中后立刻关管道退出，strings 还在
#    往管道里写，被 SIGPIPE 打断后报 "strings: failed to flush output"；脚本开了
#    pipefail，这条管道整体算失败，于是「字符串明明在二进制里」却被判成缺失
#    （Xcode 16.4 上稳定复现，日志里那条 ERROR 就是这么来的）。
#    → 直接 grep -a 扫 Mach-O。
#  ② ObjC 的 @"..." 字面量在纯 ASCII 时以 UTF-8 存进 __cstring，含非 ASCII 时
#    改存 UTF-16；纯字节 grep 只认前者。所以 ASCII 查不到时再用 python3 查一遍
#    UTF-16LE，两种编码都覆盖。
STRINGS_DUMP="$TMP/hghub-strings.txt"
strings -a "$APP/HGhub" > "$STRINGS_DUMP" 2>/dev/null || true
echo "    binary strings: $(wc -l < "$STRINGS_DUMP" | tr -d ' ') lines"

# 返回 0 表示二进制里含该标记（UTF-8 或 UTF-16LE 均算）
binary_has() {
  local bin="$1" needle="$2"
  grep -aq -- "$needle" "$bin" && return 0
  python3 - "$bin" "$needle" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
sys.exit(0 if sys.argv[2].encode("utf-16-le") in data else 1)
PY
}

if ! binary_has "$APP/HGhub" "HGhubBackdrop"; then
  echo "ERROR: scripts/ios/main.mm patch is missing from the binary" >&2
  echo "       The white bar at the bottom will still be there." >&2
  echo "       ---- diagnostics ----" >&2
  grep -aiE "Backdrop|HGApply|HGSetup|HGhub|m3u8" "$STRINGS_DUMP" | sort -u | head -20 >&2 || true
  echo "       ---- end ----" >&2
  exit 1
fi
echo "    ok: main.mm (backdrop patch)"

if ! binary_has "$APP/HGhub" "Accept-Ranges: bytes"; then
  echo "ERROR: src-tauri/src/local_http.rs is not compiled in" >&2
  echo "       Video will spin forever (AVFoundation cannot use hg://)." >&2
  echo "       ---- diagnostics ----" >&2
  grep -aiE "Accept-Ranges|Content-Range|127\.0\.0\.1|hls\.m3u8" "$STRINGS_DUMP" | sort -u | head -20 >&2 || true
  echo "       ---- end ----" >&2
  exit 1
fi
echo "    ok: local_http"

# Info.plist 里的 ATS 例外必须落在最终 app bundle 内（Xcode 会重新生成 plist，
# 所以这里核对产物而不是源文件）。同样避开 `cmd | grep -q`：pipefail 下
# grep -q 提前退出会让上游吃 SIGPIPE，命令替换的退出码变成 141。
ATS_LOCAL="$(/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsLocalNetworking" \
  "$APP/Info.plist" 2>/dev/null || true)"
if [ "${ATS_LOCAL}" != "true" ]; then
  echo "ERROR: NSAllowsLocalNetworking missing from built Info.plist (got '${ATS_LOCAL}')" >&2
  /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$APP/Info.plist" >&2 2>/dev/null || true
  exit 1
fi
echo "    ok: NSAllowsLocalNetworking"

# 深色外观兜底：系统背景 / 键盘 / 滚动条底衬全变暗，白条没有藏身处。
UI_STYLE="$(/usr/libexec/PlistBuddy -c "Print :UIUserInterfaceStyle" "$APP/Info.plist" 2>/dev/null || true)"
if [ "${UI_STYLE}" != "Dark" ]; then
  echo "ERROR: UIUserInterfaceStyle is '${UI_STYLE}', expected Dark" >&2
  exit 1
fi
echo "    ok: UIUserInterfaceStyle=Dark"

# --- wrap into IPA --------------------------------------------------------
echo "==> Packaging IPA"
WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
find "$WORK" -name ".DS_Store" -delete
mkdir -p "$(dirname "$OUT")"
(cd "$WORK" && zip -qr -y "$OUT" Payload)
rm -rf "$WORK"

echo
echo "IPA ready: $OUT"
ls -lh "$OUT"
lipo -info "$APP/HGhub"
echo "Unsigned on purpose - TrollStore / SideStore will sign it on device."
