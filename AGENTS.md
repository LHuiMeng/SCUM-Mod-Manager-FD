# AGENTS.md — SCUM Mod Manager FD v2

## 项目概述

Flutter Desktop (Windows) 应用，用于管理《SCUM》游戏的 `.pak` 模组文件。全自绘无框窗口 + 军事暗色主题。

- **语言**: Dart 3.12.2 + C++ (Win32)
- **SDK**: `^3.12.2`
- **目标**: Windows x64 Release
- **分支**: `main`（本公开仓库为干净单提交，无历史）

---

## 双版本构建（重要）

本项目同一份源码支持两种构建形态，由编译期 dart-define 区分：

| 版本 | REGISTRY_BASE_URL / UPDATE_MANIFEST_URL | 行为 |
|------|----------------------------------------|------|
| **对外版（无云）** | 不注入（默认空字符串） | 云上mod 面板保留但显示空列表；在线更新链路静默跳过；远程服务器 SFTP 面板保留（地址用户自填） |
| **内部版（有云）** | 由发布脚本注入真实地址 | 完整云功能：云上mod 目录 + 在线更新 |

源码**零硬编码域名** —— 任何云服务地址都必须通过 `--dart-define` 注入，禁止写死 URL。

### 对外版构建

```bash
# build_public.bat（Windows）或手动：
flutter build windows --release --dart-define=APP_VERSION=x.y.z
# 产物: build/windows/x64/runner/Release/
```

对外版安装包 + 便携版由 `build_public.bat` 一键产出（NSIS `*_public_setup.exe` + v3 布局便携目录）。

### 内部版构建

发布脚本（`build_release.ps1`）注入云源地址与更新 manifest：

```bash
powershell -File build_release.ps1 -Version x.y.z -RegistryUrl https://你的云源地址
```

- `-RegistryUrl` → 注入 `REGISTRY_BASE_URL` + `UPDATE_MANIFEST_URL`（同域 `/app/manifest.json`）
- 更新验签密钥经 `--dart-define-from-file=update_secret.json` 注入（文件不入库）

---

## 编译验证

```bash
flutter pub get
flutter build windows --release
# 产物: build/windows/x64/runner/Release/scum_mod_manager_app.exe
```

## 架构

```
lib/
├── main.dart                     # 入口 → runApp + autoDetectPathsAndApply
├── theme/scum_theme.dart         # 军事暗色调色板
├── models/                       # 数据模型
│   ├── mod_entry.dart            # 本地模组条目
│   ├── remote_mod_entry.dart     # 远端 registry 条目
│   └── launch_options.dart       # 启动参数模型
├── services/                     # 业务逻辑
│   ├── mod_service.dart          # 核心: 扫描/部署/回收/路径检测
│   ├── launcher_service.dart     # MethodChannel → 游戏进程管理
│   ├── window_service.dart       # MethodChannel → 窗口控制/拖拽事件
│   ├── mod_registry_client.dart  # 云上 mod 目录 HTTP 只读客户端（地址编译期注入）
│   ├── update_service.dart       # 在线更新 manifest 拉取 + HMAC 验签（地址编译期注入）
│   ├── download_service.dart     # 更新文件下载 + sha256 校验
│   ├── app_logger.dart           # 统一日志（默认关，运行日志页开启）
│   ├── app_signals.dart          # 跨 widget 全局 ValueNotifier
│   └── app_version.dart          # 运行时版本唯一入口（dart-define 注入）
├── screens/                      # 页面
└── widgets/                      # 自绘组件（全自绘，无 Material 控件）
```

## 核心工作流

### 启动时 (`scanMods`)
1. `_rescueModsFromGame()` — 将游戏 `~mod` 中的 PAK **复制**到本地 `~mods/`（同名**覆盖**）
2. `reclaimMods()` — 清空游戏 `~mod`（回收上次部署）
3. 只扫描本地 `~mods/` 作为唯一真值源

### 启动游戏时 (`RightDock._launchClient/Server`)
1. `deployMods({isServer})` — 将**已启用**的 PAK 复制到游戏 `~mod/`
2. `launchGame()` — CreateProcessW 启动游戏
3. `Timer.periodic(2s)` → `isGameRunning()` 轮询检测
4. 进程退出 → `reclaimMods()` + 按钮恢复

---

## 代码约束

### 自绘原则
所有 UI 控件必须用 `Container` / `CustomPaint` 自绘，**禁止** Material 原生控件（`TextField`、`DropdownButton`、`InkWell`、`Checkbox` 等）。输入用 `EditableText` + `FocusNode` 自绘。

### 主题（铁律）
- 颜色 = 运行时通过 `ScumColors.of(context)` 取，**禁止**在 widget/screen 内联 `Color(0xFF...)`
- 颜色 token 在 `lib/theme/scum_colors.dart`；几何/动画/字号常量走 `ScumTheme.xxx`
- 白名单例外：`Colors.transparent`、启动按钮/Toast 的 `Colors.white`、token 工厂内部的字面量
- 验收：`rg -n 'Color\(0xFF' lib --type=dart` 只命中 scum_colors.dart 工厂行

### Overlay 弹窗
- `OverlayEntry` + 静态控制器；`_entry?.remove()` 必须 try-catch
- 离开 1 秒自动关闭（timer），hover 重置

### ReorderableListView
- `buildDefaultDragHandles: false` + 行内 `ReorderableDragStartListener`
- 最外层 widget 必须有 `key: ValueKey(...)`；筛选态用 `ListView.builder`（禁拖）

### 方法通道
- `com.scummod/launcher` — 游戏进程管理
- `com.scummod/window` — 窗口控制/文件对话框
- `com.scummod/drag` — C++ → Dart 拖拽事件推送

### 文件系统
- 配置: `{exe_dir}/config.json`（路径 + 启动选项 + 云源）
- 元数据: `{exe_dir}/mods_meta.json`（标签 + 备注）
- 本地 PAK: `{exe_dir}/~mods/`（永久存储）
- 游戏 PAK: `{scum_install}/SCUM/Content/Paks/~mod/`（临时部署）

## 常见陷阱

| 陷阱 | 说明 |
|------|------|
| `OverlayEntry.remove()` 重复调用 | OverlayEntry 内部 `_overlay` 为 null 时抛异常 → 必须 try-catch |
| `CreateProcessW` 工作目录 | `lpCurrentDirectory` 必须设为 exe 父目录，否则 DLL error 126 |
| `OleInitialize` 先于 `CoInitializeEx` | `RegisterDragDrop` 需要 OLE 初始化状态 |
| `RegisterDragDrop` 必须在 `ShowWindow` 之后 | 否则 OLE 因窗口不在 live table 而失败 |
| `.bat` 必须 CRLF | cmd.exe 按 GBK 解析；UTF-8 中文注释会断行 → 对外脚本用纯 ASCII 注释 |
| `git-bash` 与 `cmd` 路径差异 | backslash 在 bash 中被吞 → 用 forward slash |

## SCUM 路径约定

- 客户端安装: `X:\SteamLibrary\steamapps\common\SCUM`
- 服务端安装: `X:\SteamLibrary\steamapps\common\SCUM Server`
- 游戏 PAK 目录: `{install}/SCUM/Content/Paks/~mod/`
- Steam 注册表: `HKLM\SOFTWARE\WOW6432Node\Valve\Steam` → `InstallPath`
- 多 Steam 库: 读取 `{SteamPath}/steamapps/libraryfolders.vdf`
