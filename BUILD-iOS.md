# HGhub iOS（未签名 IPA / 巨魔商店）构建与安装手册

本目录 = 「HGhub 加 iOS 支持」的可构建源码树，基底是社区 PR
[`Minireel/HGhub#4`](https://github.com/Minireel/HGhub/pull/4)（作者 `ken861222`，分支 `feat/ios-support`）的树，
加上本手册配套的两个改动：

| 改动 | 文件 | 目的 |
| --- | --- | --- |
| 新增 | `.github/workflows/ios.yml` | 在 GitHub 免费 macOS runner 上编译未签名 IPA |
| 修改 | `package.json` → `scripts.ios:ipa` | 改成 `bash scripts/build-ios-ipa.sh`（原为 `./scripts/...`，在 `sh` 下无执行位会失败） |

其余全部保留 PR4 原样，包括三处 iOS 专有修复（详见文末「为什么能跑」）。

---

## 0. 前提

| 项 | 要求 |
| --- | --- |
| 手机 | iOS **15.0 – 17.0**，且**已装好 TrollStore**（16.7.x 与 17.0.1+ 永久不支持 TrollStore） |
| GitHub 账号 | 有（免费版即可） |
| Apple 开发者账号 | **不需要**。未签名构建 + TrollStore 自签，全程不碰证书 |
| 本机 macOS / Xcode | **不需要**。编译在 GitHub 的 `macos-14` runner 上完成 |

---

## 1. 路线 A（推荐，10 分钟）：上传现成源码树 + 跑 workflow

整棵树已经打包好（`HGhub-ios-src.zip`，约 1.15 MB，118 个文件），
已剔除 `node_modules/`、`dist/`、`src-tauri/target/`、`src-tauri/gen/`。
**只要拖上去，不需要手工粘任何文件。**

1. 解压 `HGhub-ios-src.zip`，得到一个 `HGhub-ios` 文件夹。
2. GitHub 右上 **+** → **New repository** → Repository name 填 `HGhub-ios`
   → 选 **Public**（私有仓库的 macOS runner 按 10× 分钟计费，而且免费额度只有 2000 分钟/月）
   → **Create repository**。
3. 在空仓库页点 **uploading an existing file**。
4. 打开解压出来的 `HGhub-ios` 文件夹，`Ctrl+A` 全选里面的**所有内容**（含 `.github`、`src-tauri` 等目录），
   整个拖进浏览器上传区。等文件列表全部出现（应看到 100+ 个文件），点 **Commit changes**。
   > 必须在文件管理器里开启「显示隐藏项目」才能看到 `.github`、`.gitignore`、`.npmrc`；
   > 漏了 `.github` 就没有 workflow，Actions 页面会是空的。
5. 仓库页 **Actions** 标签 → 左侧选 **Build iOS IPA (unsigned)**
   → 右侧 **Run workflow** → 分支选 `main` → **Run workflow**。
6. 等 15–35 分钟（首次要拉 457 个 crate；之后有 cargo 缓存会快很多）。
   点进运行页可看到 12 个步骤依次变绿。
7. 运行页底部 **Artifacts** → 下载 `HGhub-unsigned-ipa` → 解压得到
   `HGhub-unsigned.ipa`（约 8–15 MB）+ `HGhub-unsigned.ipa.sha256`。

> 若 Actions 页面没有 Run workflow 按钮：说明 `.github/workflows/ios.yml` 没上传成功。
> 用 **Add file → Create new file** 手工补一个，文件名 `.github/workflows/ios.yml`
> （输入 `/` 会自动建目录），内容整段复制本目录的 `.github/workflows/ios.yml`。

---

## 2. 路线 B（备用）：Fork 上游分支

适用：不想在本地解压/上传，愿意手工粘两个文件。

Fork 会把**所有分支**连二进制图标一起复制过去。

1. 打开 <https://github.com/ken861222/HGhub>，点右上 **Fork** → **Create fork**。
   目标仓库变成 `https://github.com/BigZ202261108/HGhub`。
2. 在你自己的 fork 里，点分支下拉框，切到 **`feat/ios-support`**。
   > 必须是这个分支。`main` 没有 iOS 代码。
3. 添加 workflow：**Add file → Create new file**，文件名填
   `.github/workflows/ios.yml`（输入 `/` 会自动建目录），
   内容整段复制本目录的 `.github/workflows/ios.yml`，**Commit changes**（提交到 `feat/ios-support`）。
4. 改一行：打开 `package.json` → 右上铅笔 → 把
   `"ios:ipa": "./scripts/build-ios-ipa.sh"` 改成 `"ios:ipa": "bash scripts/build-ios-ipa.sh"` → Commit。
5. 触发：仓库页 **Actions** → 首次会看到
   *"Workflows aren't being run on this forked repository"* → 点 **I understand my workflows, go ahead and enable them**；
   左侧选 **Build iOS IPA (unsigned)** → 右侧 **Run workflow** → 分支选 `feat/ios-support` → **Run workflow**。
6. 按路线 A 的第 6–7 步取产物。

---

## 3. 产物自检（workflow 已自动做，也可本地复核）

```
Payload/HGhub.app/Info.plist  CFBundleIdentifier = com.hghub.huangguo
                              MinimumOSVersion   = 15.0
Payload/HGhub.app/HGhub       arm64
二进制里必须能 grep 到 "/assets/index-"
```

最后一条是命门：**没有内嵌前端资源 = 打开纯白屏**。
根因是 `cargo build` 少了 `--features tauri/custom-protocol`，脚本里已带。

---

## 4. 巨魔商店安装

1. 把 `HGhub-unsigned.ipa` 传到手机（隔空投送 / 文件 App / iCloud 云盘 都行）。
2. 在「文件」里点这个 IPA → 分享 → **TrollStore**（或长按 → 共享 → TrollStore）。
   也可以在 TrollStore 里用右上角 **+** 选文件。
3. TrollStore 会自动用永久签名装好，桌面出现 HGhub 图标。
4. 首次启动若提示「未受信任的开发者」——不会出现，TrollStore 装的应用天然受信。

> 卸载重装：TrollStore 里左滑删除，或桌面长按删除。数据随应用一起清掉（登录态在 `hghub_app_v1` 里）。

---

## 5. 首次开屏验收清单（12 项）

| # | 检查点 | 期望 |
| --- | --- | --- |
| 1 | 首屏封面墙 | 6 列网格，封面能出图（不是灰块） |
| 2 | 上滑切下一个视频 | 顺畅，无卡死 |
| 3 | 底部安全区 | 底部按钮不被 Home 指示条遮住，无白色条 |
| 4 | 播放页顶部按钮 | 返回/收藏/评论都在屏内，没被裁到右侧 |
| 5 | 画面比例 | 默认 `contain`，不裁切；设置里可切 `cover` |
| 6 | 连播 30 秒 | 不黑屏、不出声无画 |
| 7 | 横竖屏切换 | 能切，锁定按钮生效 |
| 8 | 评论区 | 能开、能发 |
| 9 | 搜索 | 有结果 |
| 10 | 登录 | 弹键盘不遮挡输入框，登录成功 |
| 11 | 退出重进 | 登录态还在 |
| 12 | 线路切换 | LinePicker 能切线路并生效 |

---

## 6. 故障处置

| 现象 | 判断 | 处理 |
| --- | --- | --- |
| 打开**纯白屏**，无任何 UI | 前端资源没内嵌 | 看构建日志里 `ASSETS EMBEDDED` 是否打印；确认 `cargo build` 带 `--features tauri/custom-protocol` |
| 封面全灰、视频一直转圈 | `hg://` 自定义协议被 WKWebView 拦了 | 走 **A′**：把 `hg://localhost` 换成 `http://127.0.0.1:PORT` 本地监听（见第 8 节） |
| 播放有声音无画面 | WKWebView 背景被设成透明 | 已在 `scripts/ios/main.mm` 修掉；若改过该文件请还原 |
| 竖屏画面被裁掉上下 | `object-fit: cover` | 设置里切 `contain`（默认已是 contain） |
| 弹「App 想要查找并连接本地网络设备」 | iOS 14+ 对 `.localhost` 的 mDNS 探测 | 点允许；或直接走 A′ 用 `127.0.0.1` |
| 构建报 `sandbox_apply: Operation not permitted` | SwiftPM 沙箱 | 脚本里的 swift shim 已处理；被 `HG_IOS_NO_SWIFT_SHIM=1` 关掉过就会复现 |
| `xcodebuild` 报签名相关错误 | 漏了开关 | 必须有 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual ENABLE_DEBUG_DYLIB=NO` |
| `expected exactly 1 Build Rust Code script line, found 0` | Tauri CLI 版本改了 pbxproj 写法 | 用 `@tauri-apps/cli 2.10.1`（`package.json` 已锁） |

---

## 7. 为什么能跑（三个已被 PR4 修掉的 iOS 坑）

1. **布局模式 vs 真实平台**
   `src/api.ts` 里 `platform` 必须返回 `"android"`（布局模式），真实平台另存 `runtimePlatform`。
   若把 `platform` 改成 `"ios"`，`Feed.tsx` 的 `isDesktop = platform !== "android"` 成立 →
   走桌面控制条 + 372px 右侧评论栏，窄屏按钮直接被裁出屏外。
2. **真机黑屏**
   为了消底部白条，最初把 WKWebView 设 `opaque=NO` + 透明背景；
   视频切到硬件解码层后整层被丢弃（有声音、无画面、按钮全消失）。
   正确做法：把 WKWebView 与它内部 `scrollView` 的 `backgroundColor` 染成不透明深色 `#1a1a1a`，
   并在启动后 0.05/0.15/0.35/0.8/1.5 秒各刷一次。见 `scripts/ios/main.mm`。
3. **画面裁切**
   移动端竖屏硬编码 `object-fit: cover` 会裁掉上下，改为可切 `contain`/`cover`（`videoFit`，默认 contain）。

另外 iPhone 上 **MSE 不可用**（`caniuse`：iOS 13+ 仅 iPadOS 完整支持），
所以 `hls.js` 的 `Hls.isSupported()` 为 false，播放必然落到原生 `<video src>` 分支 ——
这条分支依赖 `hg://localhost/hls?u=...` 的播放列表代理改写。这也是 A′ 方案的由来。

---

## 8. A′ 预案（仅在视频/封面加载失败时启用）

把自定义协议换成回环 HTTP 服务，绕开 WKWebView 对自定义 scheme 的所有限制。

1. Rust 侧：在 `src-tauri/src/lib.rs` 的 `.setup()` 里起一个
   `tokio::net::TcpListener`，`bind("127.0.0.1:0")` 拿随机端口，
   把端口写进 `net::bind_base` 已管理的状态里；handler 直接复用 `media::handle(&path, &query, origin)`。
2. 前端：`src/api.ts:52` 把 `LOCAL` 改成 `http://127.0.0.1:${PORT}`，端口由
   一个新增命令（如 `local_media_port`）在启动时取值。
3. Info.plist：加
   ```xml
   <key>NSAppTransportSecurity</key>
   <dict>
     <key>NSAllowsLocalNetworking</key><true/>
   </dict>
   ```
4. `media.rs` 的 `respond()` 已经带 `Access-Control-Allow-Origin: *`，跨源不用另外配。

不要用 `http://hg.localhost` 这种写法：iOS 14+ 会当成 mDNS 名字去探测，触发本地网络权限弹窗，拒绝后直接黑屏。

---

## 9. 构建参数速查

```bash
# 一次性
pnpm install
pnpm build
pnpm exec tauri ios init --ci        # 生成 src-tauri/gen/apple

# 出 IPA
pnpm ios:ipa                          # → ./HGhub-unsigned.ipa
IPA_OUT=/tmp/custom.ipa pnpm ios:ipa  # 自定义输出路径

# 单步手动
cd src-tauri && cargo build --target aarch64-apple-ios --release --lib \
  --features tauri/custom-protocol
```

CI 侧环境变量：`APPLE_DEVELOPMENT_TEAM=ABCDE12345`（假值，只为跳过交互）、`CI=true`。
