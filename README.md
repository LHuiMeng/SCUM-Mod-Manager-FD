# SCUM Mod Desk v3

《SCUM》Windows 模组管理器的 Rust/Tauri 重写版本。前端使用 React + TypeScript，
桌面后端、文件系统操作、进程管理、云目录与 SFTP 全部由 Rust 执行。

## 功能

- 扫描、导入和启用本地 `~mods/*.pak`
- 部署到客户端/服务端 `Paks/~mod/`，退出后自动回收
- 管理 UE4SS 目录模组并同步 `mods.txt`
- 拖拽调整 PAK 加载顺序，编辑标签与本地备注
- 从 Steam 注册表和 `libraryfolders.vdf` 检测游戏路径
- 浏览云模组目录，SHA-256 校验后下载
- SFTP 浏览、连接测试与服务器模组上传
- 亮色纸张主题与中性石墨暗色主题

## 技术栈

| 层 | 技术 |
|---|---|
| UI | React 19、TypeScript、Vite |
| 桌面壳 | Tauri 2 |
| 后端 | Rust、Tokio、Reqwest、SSH2 |
| 平台集成 | Win32 / Windows DPAPI |
| 持久化 | JSON 配置、JSON 元数据、DPAPI 凭据文件 |

## 开发

前置环境：Node.js 20+、Rust stable、Visual Studio Build Tools（C++ 桌面开发）、
WebView2 Runtime。

```powershell
npm install
npm run dev          # 浏览器预览，使用内置 mock 数据
npm run tauri dev    # 启动真实 Tauri 窗口与 Rust 后端
```

常用检查：

```powershell
npm run typecheck
npm run test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
```

## 发布构建

```powershell
npm run tauri build
```

主要产物位于 `src-tauri/target/release/`，NSIS 安装器位于
`src-tauri/target/release/bundle/nsis/`。

### 便携目录包

```powershell
npm run package:portable -- -Edition public
```

便携包输出到 `release-output/portable/`。解压后将整个 `SCUM Mod Desk`
目录放到非 C 盘的可写位置，例如 `R:\SCUM Mod Desk`，再运行
`scum-mod-manager.exe`。不要放进 `Program Files`，普通用户无法在那里写入
运行数据。

### 公开发行版与服务器版

服务器版需要先复制 `secrets/example.toml` 为 `secrets/runtime.toml`，填写
`[cloud].auth_token`，然后构建：

```powershell
npm run build:editions -- -Edition public
npm run build:editions -- -Edition server
npm run build:editions -- -Edition both
```

安装器输出到 `release-output/public/` 与 `release-output/server/`。公开版不包含
`runtime.toml`，Rust 也会强制忽略共享密钥；服务器版把 `runtime.toml` 打入
`runtime-secrets/runtime.toml`，仅由 Rust 后端读取。

共享密钥会随服务器安装包分发，具备本机文件读取能力的人最终可以提取它。
它用于隔离普通公开客户端，不应被视为能够抵御逆向工程的绝对秘密。

## 目录

```text
src/                         React 界面
  api/                       Tauri invoke 与浏览器 mock
  components/                页面、检查器、弹窗与通用控件
  styles/tokens.css          亮色/暗色主题 token
src-tauri/                   Rust/Tauri 后端
  src/state.rs               应用状态与扫描/元数据
  src/mods/                  PAK 扫描、导入与部署
  src/cloud.rs               云目录与下载校验
  src/sftp.rs                SFTP 浏览与上传
  src/secrets.rs             DPAPI 凭据保护
  resources/                 repak.exe 与 UE4SS 框架
secrets/                     被 Git 隔离的本地敏感配置
```

## 运行数据

程序生成的数据统一保存在程序目录下的 `app-data/`：

```text
app-data/
  config.json
  mods_meta.json
  deployment_manifest.json
  ~mods/
  ue4ss_runtime/
  logs/
  secrets/
```

Tauri 与 WebView2 的缓存也保存在该目录。程序不会再回落到
`%APPDATA%` 或 `%LOCALAPPDATA%`。升级会保留 `app-data`；便携版可直接删除
整个程序目录完成清理。

从旧版迁移 C 盘数据：

```powershell
npm run migrate:data -- -Destination "R:\SCUM Mod Desk\app-data" -Edition public
```

脚本默认不覆盖目标已有文件，也不删除旧数据。确认迁移结果后，可再次执行并
添加 `-RemoveOld` 删除旧目录。

## 敏感信息

- 仓库只跟踪 `secrets/README.md` 与 `secrets/example.toml`。
- `secrets/runtime.toml`、构建密钥和其他私密文件由 `.gitignore` 排除。
- Rust 开发环境会在应用数据目录没有配置时回退读取仓库
  `secrets/runtime.toml`，前端无法直接读取该文件。
- SFTP 密码由 Windows DPAPI 加密，写入
  `app-data/secrets/sftp/*.bin`；React 只接收 `hasPassword`，不接收密码。
- 运行 `npm run secrets:check` 可检查敏感文件是否被 Git 跟踪。

## 第三方资源

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)：UE4/UE5 脚本注入框架，MIT
- [repak](https://github.com/trumank/repak)：Unreal PAK 工具，Apache-2.0 / MIT

## 许可

MIT
