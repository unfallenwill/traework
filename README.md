# TRAE SOLO — 非官方 Linux 包（`.deb` / `.rpm`）

> ⚠️ **非官方。** 本项目与 **TRAE**、**SPRING (SG) PTE. LTD.** 无任何关联、授权或赞助关系。**TRAE SOLO 的版权归 © SPRING (SG) PTE. LTD. 所有。** 这里的包是从 TRAE 官方 macOS 包（DMG）中提取其跨平台 payload，再用匹配的 Linux Electron 运行时重新打包得到。详见 [NOTICE.md](NOTICE.md)。

官方产品：<https://www.trae.ai>

本仓库产出 **TRAE SOLO** 的 **非官方** Linux 包（x86-64），`.deb` 与 `.rpm` 格式。

TRAE SOLO 只发布 macOS 与 Windows 版本。因为它是 [Electron](https://www.electronjs.org/) 应用，其主体（`app.asar` 等核心代码）在三大平台之间兼容。本仓库从官方 `.dmg` 中提取这部分 payload，再用 **ByteDance 魔改版 Linux Electron**（从官方 `Trae-linux-x64.deb` 中抽出）作为运行时重新打包，从而在 Linux 上直接 `apt install` 或 `dnf install` 即可用。详见下文 [为什么不能用官方原版 Electron](#为什么不能用官方原版-electron)。

## 安装

下载与你的发行版/架构对应的文件，然后：

```bash
# Debian / Ubuntu / Mint / Pop!_OS
sudo apt install ./trae-solo_0.1.36_amd64.deb

# Fedora / RHEL / openSUSE
sudo dnf install ./trae-solo-0.1.36.x86_64.rpm
```

在应用菜单里启动，或在终端执行 `trae-solo`。可对照下载文件与 `checksums_*.txt`：

```bash
sha256sum -c checksums_trae-solo_0.1.36_amd64.txt
```

## 包做了什么

- 安装目录 `/opt/trae-solo`，包含：Linux Electron 运行时 + 经过转换的 TRAE SOLO 资源 + 启动脚本。
- 启动器：`/usr/bin/trae-solo` → `/opt/trae-solo/start.sh`。
- 桌面集成：`/usr/share/applications/trae-solo.desktop`。
- 图标：`/usr/share/icons/hicolor/{16,32,48,64,128,256,512}x{16,32,48,64,128,256,512}/apps/trae.png`。
- `chrome-sandbox` 在安装后会被 `postinst` 设为 setuid root（Electron 启动要求）。
- 软件包依赖：声明了 GTK / NSS / ALSA / X11 / libsecret 等运行时库，包管理器会一并拉取。

> TRAE SOLO 是 VS Code 的衍生品，包含大量 macOS/Windows-only 的原生 addon。本包在安装阶段移除它们（`@vscode/windows-mutex`、`windows-foreground-love`、`@vscode/deviceid`），它们的 require 失败会被上游 Electron 兜住，应用能优雅降级运行。

## 重新打包（本地构建）

需求：`curl`、`7z`（p7zip）、`perl`、`node`/`npm`、`dpkg-deb`，和 [`nfpm`](https://github.com/goreleaser/nfpm)。

首次构建需要一份官方的 **`Trae-linux-x64.deb`**。先将 ByteDance 运行时和 Linux 原生模块写入仓库（建议使用 Git LFS）：

```bash
./scripts/vendor_linux_runtime.sh "/path/to/Trae-linux-x64.deb"

# 直接产出一个可运行的 Linux app（写到 build/trae-solo/）
./install.sh \
  --dmg "/path/to/TRAE_Work-darwin-x64.dmg" \
  --install-dir build/trae-solo
./build/trae-solo/start.sh            # 启动它

# 产出 .deb + .rpm（写到 dist/）
DMG="/path/to/TRAE_Work-darwin-x64.dmg" \
  ./packaging/build.sh
```

运行时保存在 `vendor/bytedance-electron-linux-x64/`，后续构建不再重复抽取 deb。

`ARCH` 默认 `x64`。`./packaging/build.sh` 接受的环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DMG` | （必填） | 本地 macOS DMG 路径 |
| `DMG_URL` | 空 | 不传 `DMG` 时从这里下载（写入 `~/.cache/trae-solo-linux/dmg`） |
| `PRODUCT_VERSION` | 从 DMG 检测 | 显式指定时覆盖检测值 |
| `ARCH` | `x64` | 目前仅支持 `x64` |
| `TRAE_NATIVE_REBUILD_LIST` | 见下 | 覆盖要替换为 Linux 版本的原生模块列表 |

## 为什么不能用官方原版 Electron

Trae 的主进程 JS 里写死了 `import { ahaNet, ahaDeviceService, ahaReporter, ahaIpc, ahaDoctor, ... } from "electron"`。这些 `aha*` 命名导出 **不是** Electron 公开 API，而是 ByteDance 自家魔改版 Electron（`@aha-kit/electron`）的私有扩展，背后还链接着 `libaha_net.so`（TTNet 网络）、`libsscronet.so` 等专有库。官方原版 `electron/electron` 根本不导出它们，于是第一个 `import` 就在 ESM 链接阶段报致命错误：

```
SyntaxError: The requested module 'electron' does not provide an export named 'ahaDeviceService'
```

这个错误无法 try/catch，主进程在开窗前就死了（即「无法启动」）。日志里的 Wayland / MESA / libva / sandbox 警告都是 GPU 进程临死前的噪音，不是病因。

魔改版 Linux Electron 没有发布到 npm（`@aha-kit/electron` → 404），macOS DMG 里的又是 Mach-O（Linux 不能用）。唯一公开来源是 **官方 Trae Linux 包**：它的 `/usr/share/trae` 里就有这个魔改 `trae` 二进制（`RPATH=$ORIGIN`）以及上述专有 `.so`。所以本仓库的做法是：

1. 从官方 `Trae-linux-x64.deb` 抽出魔改 Electron 运行时（`trae` 二进制重命名为 `electron`，连同 `libaha_net.so` 等、`chrome-sandbox`、`*.pak`/`*.dat`），**但不拷贝** 它自带的 `resources/app`（payload）与 `node_modules`——那些由 DMG 提供。
2. 把 DMG 的 payload 放进 `resources/app`，原生 addon 走下面的 npm prebuild 替换。

### 版本漂移与 aha\* 打桩

DMG 的 payload（TRAE SOLO `1.107.1`）比官方 Trae deb 多用了 2 个 `aha*` API：`ahaAccessibility`、`ahaCustomException`（可观测性/无障碍相关，**非** 网络/鉴权）。官方 deb 的 Electron 不再导出它们，于是会报 `...does not provide an export named 'ahaCustomException'`。ESM 命名导入无法用 JS 给 `electron` 内置模块打补丁，所以 `scripts/patch_aha_shim.js` 会：在 `node_modules/__aha-electron-shim/` 生成一个 no-op 代理 shim，并把 payload 里引用这两个符号的 `import{...}from"electron"` 改写为从 shim 导入（真正共导入的符号如 `app`/`ahaNet`/`ahaDeviceService` 仍走 `electron`）。上游代码本就写了 `if(!k3) return warn('unavailable')` 兜底，所以这两个 API 缺失只会让崩溃上报/无障碍检测失效，不影响编辑器与 AI 主链路。可用 `TRAE_AHA_STUBS=foo,bar` 覆盖打桩列表。

## 原生模块策略

DMG 内 **所有** 原生 addon 都只携带 macOS 预编译二进制，且大多不包含 `binding.gyp`（VS Code 风格的 asar 不存源码）。本包的策略：

1. **删除 macOS/Windows-only**：`@vscode/windows-mutex`、`windows-foreground-love`、`@vscode/deviceid`。
2. **同版本 npm 重装取 Linux prebuild**：`node-pty`、`@vscode/sqlite3`、`@vscode/spdlog`、`@parcel/watcher`（附带 `@parcel/watcher-linux-x64-glibc`）、`native-watchdog`、`@vscode/policy-watcher`、`kerberos` —— 大多数都有 napi-v3 / 平台 subpackage 形式的 Linux 预编译。
3. **`native-keymap` 列为可选**：编译它需要 `libxkbfile-dev` / `libx11-dev`，本环境无 sudo 安装这些。在装有这些 dev 库的系统上重跑 `./install.sh` 即重新编译它。

可通过 `TRAE_NATIVE_REBUILD_LIST="node-pty,@vscode/sqlite3,..."` 微调要替换的模块。

## 限制

- **x86_64 only**。本 DMG 是 darwin-x64，里面的 Electron 派生版与原生模块都是 64 位；树莓派等 ARM 设备需要单独适配。
- **离线安装可能缺 lib**：`postinst` 把 `chrome-sandbox` setuid 设为 4755，但若当前内核禁用了 `noexec` 或 `nosuid`（容器常见），仍需 `--no-sandbox` 启动。`start.sh` 会自动检测并切换。
- **`native-keymap` 缺失**：在没有装 `libxkbfile-dev` 的环境里，键位映射可能不准。其它所有原生模块均替换为 Linux 版本。

## 项目目录

```
.
├── install.sh                    # DMG → 可运行的 Linux app
├── packaging/
│   ├── build.sh                  # 渲染模板 + 调 nfpm 打包
│   ├── extract-icon.sh           # .icns → hicolor 多尺寸 PNG
│   ├── icons/trae-solo/hicolor/  # 已抽好的图标
│   └── templates/                # nfpm.yaml / .desktop / wrapper / *.inst
├── scripts/
│   ├── lib_common.sh             # 常量 / 日志 / arch 映射
│   ├── lib_dmg.sh                # 7z 解 DMG + 读 Info.plist
│   ├── lib_electron.sh           # 下 Linux Electron zip
│   ├── lib_native.sh             # 原生模块替换逻辑
│   └── patch_linux.js            # 小修改（productName、注册数据路径）
├── launcher/start.sh.template    # 自定位启动器
├── docs/                         # 杂项文档（按需添加）
├── build/                        # 转换产物（不在版本控制里）
├── dist/                         # 产出的 .deb / .rpm（不在版本控制里）
├── LICENSE                       # MIT（仅本仓库脚本与模板）
├── NOTICE.md                     # TRAE SOLO 版权声明
└── AGENTS.md                     # 给后续 AI / 贡献者看的实现细节
```

## 许可与声明

TRAE SOLO 是 SPRING (SG) PTE. LTD. 的专有软件。本仓库的打包脚本、模板、构建工具、文档以 MIT 许可证发布，详见 [LICENSE](LICENSE)。"TRAE" 与 "TRAE SOLO" 是 SPRING (SG) PTE. LTD. 的商标，仅用于标识。
