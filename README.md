# SCUM Mod Manager v2

适用于《SCUM》游戏的模组管理桌面工具（Windows）。全自绘无框窗口 + 军事暗色主题。

## 功能特性

- **模组扫描** — 自动检测本地 `~mods/`、客户端 `Paks/~mod/`、服务端 `Paks/~mod/`
- **拖拽导入** — OLE IDropTarget 实时拖拽反馈，`.pak` 文件直接拖入
- **多标签筛选** — 自定义标签系统，支持多标签 AND 过滤
- **搜索过滤** — 实时文本搜索过滤模组列表（含中文拼音搜索）
- **加载顺序重排** — 拖拽卡片调整 PAK 加载顺序
- **游戏启动** — 一键启动 SCUM 客户端/服务端，自动处理 `-nobattleye`、`-log`、`-port` 参数
- **标签/备注编辑** — 每模组可自定义标签和备注，悬浮窗编辑，自动保存
- **路径自动检测** — 注册表 + Steam libraryfolders.vdf 自动发现游戏安装路径
- **云上mod 面板** — 浏览/搜索/筛选/下载云端 mod 目录（地址由构建期注入，默认无源）
- **远程服务器面板** — SFTP 浏览/上传自有 SCUM 服务器 `~mods` 目录
- **在线更新** — manifest 拉取 + HMAC 验签 + 增量更新（地址由构建期注入，默认关闭）
- **冲突检测与合并** — repak 扫描 PAK 内部清单，冲突自动合并（`~merged/`）
- **UE4SS 集成** — 框架注入 + Lua/C++ mod 管理（PAK 与 UE4SS 双通道）
- **全自绘 UI** — 无框窗口 + 军事暗色主题，所有控件自绘

## 技术栈

| 层 | 技术 |
|----|------|
| UI | Flutter Desktop (Widget + CustomPaint) |
| 原生桥接 | MethodChannel (C++ → Dart) |
| 进程管理 | CreateProcessW + 句柄追踪 |
| 拖拽系统 | OLE IDropTarget (实时 DragEnter/Leave/Drop) |
| 持久化 | 本地 JSON (`config.json` + `mods_meta.json`) |
| 窗口 | Win32 无框窗口 + HTCAPTION 子类化拖拽 |

## 双版本构建

同一份源码，两种构建形态（由编译期 dart-define 区分，**源码零硬编码域名**）：

| 版本 | 注入 | 云功能 |
|------|------|--------|
| **对外版（无云）** | 不注入任何云地址 | 面板保留但无源：云上mod 空列表、更新静默跳过 |
| **内部版（有云）** | `REGISTRY_BASE_URL` + `UPDATE_MANIFEST_URL` | 完整云上mod + 在线更新 |

### 对外版（默认，无云）

```bash
flutter pub get
flutter build windows --release --dart-define=APP_VERSION=2.6.5
```

或直接运行 `build_public.bat`（产出 NSIS 安装器 `*_public_setup.exe` + v3 布局便携目录）。

### 内部版（需自备云源）

```bash
powershell -File build_release.ps1 -Version 2.6.5 -RegistryUrl https://你的云源地址
```

- `-RegistryUrl` 同时注入 `REGISTRY_BASE_URL` 与 `UPDATE_MANIFEST_URL`（同域 `/app/manifest.json`）
- 更新验签密钥经 `--dart-define-from-file=update_secret.json` 注入（该文件不入库）

## 项目结构

```
lib/
├── main.dart                  # 入口
├── theme/scum_theme.dart      # 军事暗色主题 + 颜色 token（ScumColors）
├── models/                    # 数据模型
├── services/                  # 业务逻辑（mod/launcher/window/registry/update/merge/...）
├── screens/                   # 页面（home/settings/log）
└── widgets/                   # 自绘组件（全自绘，无 Material 控件）

windows/runner/                # C++ 原生后端
├── main.cpp                   # wWinMain + OLE 初始化
├── flutter_window.cpp         # 主窗口/频道/拖拽目标注册
├── win32_window.cpp           # 基类窗口
├── launcher_channel.cpp       # 游戏进程管理 MethodChannel
├── window_service_channel.cpp # 窗口控制/文件对话框
├── drop_target.cpp            # OLE IDropTarget 实现
├── launcher_main.cpp          # v3 引导器（读 app.json 启动版本目录）
└── utils.cpp                  # 控制台/UTF 转换
```

## 配置

- `config.json` — 游戏路径 / 启动选项 / 云源地址（`cloud_sources` 节点）/ 列配置
- `mods_meta.json` — 模组标签/备注/启用/SHA-256/PAK 内部清单（自动创建）

## 第三方项目与致谢

本项目深度依赖以下开源项目，谨致谢忱：

### 核心运行依赖

| 项目 | 地址 | 用途 | 许可 |
|------|------|------|------|
| **UE4SS (RE-UE4SS)** | https://github.com/UE4SS-RE/RE-UE4SS | UE4/UE5 Lua 脚本注入框架：管理器内置 `assets/ue4ss_framework.zip`，启动游戏时注入框架并管理 Lua/C++ mod | MIT |
| **repak** | https://github.com/trumank/repak | Unreal Engine `.pak` 文件读取/打包 CLI：PAK 内部清单（冲突检测）、冲突合并包生成（repak list / unpack / pack） | Apache-2.0 / MIT 双许可 |

### Dart/Flutter 依赖（pub.dev）

| 包 | 版本 | 用途 |
|----|------|------|
| `flutter` | ^3.12.2 (SDK) | UI 框架（全自绘桌面应用） |
| `path` | ^1.9.0 | 跨平台路径拼接 |
| `http` | ^1.2.0 | 云上mod 目录 / 更新 manifest 拉取 |
| `crypto` | ^3.0.3 | SHA-256 校验 + HMAC 签名验证 |
| `archive` | ^4.0.7 | 更新包 ZIP 解压 / 增量包应用 |
| `dartssh2` | ^3.3.1 | 远程服务器面板 SFTP 传输 |
| `lpinyin` | ^2.0.3 | 模组列表中文拼音搜索 |

### 工具链（构建/发布）

| 工具 | 地址 | 用途 |
|------|------|------|
| Flutter SDK | https://flutter.dev | Dart 编译 + Windows 桌面打包 |
| NSIS | https://nsis.sourceforge.io | 安装器制作（`installer/installer.nsi`） |
| Node.js | https://nodejs.org | `make_manifest.js` 更新清单签名 |

## 许可

MIT License
