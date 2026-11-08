#!/usr/bin/env bash
# Build an UNSIGNED arm64 device IPA for SideStore / AltStore sideloading.
#
# Why this exists:
#   `tauri ios build` insists on archive + export signing, which requires a
#   logged-in Apple account and a provisioning profile. SideStore re-signs with
#   your own Apple ID anyway, so the IPA itself does not need to be signed.
#   This script links a device build with CODE_SIGNING_ALLOWED=NO and wraps it
#   into the standard Payload/*.app layout.
#
# Two non-obvious requirements:
#   1. `--features tauri/custom-protocol` is required. Without it Tauri's
#      codegen takes the `dev` branch (devUrl is configured) and embeds EMPTY
#      assets, so the app would launch to a blank screen on a real device.
#   2. The generated Xcode project has a "Build Rust Code" phase that talks to
#      the Tauri CLI over a local WebSocket. It only works when the CLI itself
#      is driving the build, so we temporarily replace it with a no-op and
#      restore the project file afterwards (trap guarantees cleanup).
#
# Usage:  pnpm ios:ipa
#         ./scripts/build-ios-ipa.sh
#         IPA_OUT=/path/to/custom.ipa ./scripts/build-ios-ipa.sh
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
for cmd in pnpm cargo rustup xcodebuild python3; do
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

for t in aarch64-apple-ios; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

# --- iOS 原生入口补丁 -----------------------------------------------------
# gen/apple 被 .gitignore，重新 `tauri ios init` 会还原成默认 main.mm。
# 每次构建前把模板复制过去，保证「底部白色安全区」修复始终生效。
echo "==> Applying iOS native entry patch"
cp "$ROOT/scripts/ios/main.mm" "$GEN/Sources/huangguo-client/main.mm"

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
echo "Unsigned on purpose - let SideStore sign it with your Apple ID."
