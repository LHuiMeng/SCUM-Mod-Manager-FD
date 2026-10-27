# AGENTS.md - SCUM Mod Desk v3

## 项目

《SCUM》模组管理器，Windows x64 桌面应用。前端为 React 19 + TypeScript + Vite，
桌面后端为 Rust + Tauri 2。

- 分支：`main`
- 入口：`src/main.tsx`、`src/App.tsx`
- Tauri 入口：`src-tauri/src/main.rs`、`src-tauri/src/lib.rs`

## 工作流程

每次改动代码后按顺序执行，不得以“等待视觉确认”为理由跳过构建：

```powershell
npm run typecheck
npm run test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml
npm run tauri build
```

发布构建通过后再提交并推送：

```powershell
git add -A
git commit -m "feat: 中文改动说明"
git push origin main
git log --oneline -1
```

不要 amend，不要重置或覆盖用户已有改动。

## 安全边界

- 敏感信息只能放在根目录 `secrets/`。仓库只允许跟踪 `README.md` 与
  `example.toml`，其余内容必须被 `.gitignore` 排除。
- 禁止把令牌、密码、私钥、Cloudflare 账户/Zone/Tunnel/DNS 标识写入
  `src/`、`src-tauri/`、文档、测试或提交信息。
- 前端不得读取或保存云鉴权令牌、SFTP 密码。密码由 Rust 使用 Windows DPAPI
  加密，React 只能收到 `hasPassword`。
- 提交前执行 `npm run secrets:check`，并用
  `git check-ignore -v secrets/runtime.toml` 验证隔离规则。
- 不得在终端输出、聊天回复或文档中展示 remote URL 内嵌的 OAuth token。

## 前后端契约

- 前后端命令名以 `src/api/tauri.ts` 为准。
- 新增或改名命令时，同步更新：
  1. `src-tauri/src/commands.rs`
  2. `src-tauri/src/lib.rs` 的 `generate_handler!`
  3. `src/api/tauri.ts`
  4. `src/api/mock.ts`，保证浏览器预览可用
- Rust 结构体使用 `camelCase` 序列化以匹配 TypeScript。
- 文件系统、进程、网络、凭据操作必须留在 Rust，不放到前端。

## UI 规范

- 主色和表面颜色只通过 `src/styles/tokens.css` 的 CSS 变量使用，禁止在组件中
  内联主题色。新增颜色必须同时补齐亮色和暗色。
- 亮色为暖纸色，暗色为中性石墨色。暗色不得带绿色偏色。
- 每个页面只保留一个橙色主操作；其他操作使用描边或幽灵按钮。库页唯一主 CTA
  是“启动客户端”，检查器使用描边的“编辑标签与备注”。
- 文案以中文为主，避免无实际功能的英文微型标签、伪造仪表盘和装饰性数据。
- 动效服务层级与状态反馈，必须支持 `prefers-reduced-motion`。
- 同时检查约 `1440x900` 与 `1100x720`，不得出现横向溢出或遮挡。
- 保持当前纸张检查器风格，不要把页面改回霓虹、玻璃拟态或通用 SaaS 卡片。

## 主题

- 颜色 token：`src/styles/tokens.css`
- 全局布局与组件样式：`src/styles/global.css`
- 主题值：`data-theme="light" | "dark"`，由 `App.tsx` 切换并保存
- 暗色基准：`#151515` / `#1c1c1c` / `#232323` / `#0a0a0a`
- 强调色：亮色 `#d9653d`，暗色 `#e1724b`

## 测试与验证

- 前端单元测试：`npm run test`（Vitest）
- Rust 单元测试：`cargo test --manifest-path src-tauri/Cargo.toml`
- 前端产物：`npm run build`
- 桌面安装器：`npm run tauri build`
- 浏览器视觉检查：`npm run dev` 后检查亮色、暗色和两种窗口尺寸

## 数据路径

- 应用数据根目录：`{程序目录}/app-data`；仅测试或开发可通过
  `SCUM_MM_ROOT` 覆盖
- 配置：`{root}/config.json`
- 元数据：`{root}/mods_meta.json`
- 本地 PAK：`{root}/~mods/`
- UE4SS：`{root}/ue4ss_runtime/`
- 部署清单：`{root}/deployment_manifest.json`
- 日志：`{root}/logs/runtime.jsonl`
- 凭据：`{root}/secrets/`，SFTP 密码使用 Windows DPAPI 加密保存为 `*.bin`
- Tauri、WebView2 的缓存也通过 `appDirectoriesOverride` 指向该目录

程序必须安装在用户可写的非 C 盘目录，例如 `R:\SCUM Mod Desk`。不要把
需要写入运行数据的版本安装到 `Program Files`。

## 常见约束

- 游戏运行期间禁止修改启用状态；部署后必须可通过清单回收。
- 所有游戏路径操作必须校验目标在预期根目录内。
- ZIP 解包必须继续使用 `enclosed_name` 并拒绝绝对路径/父目录穿越。
- 云下载必须校验服务器提供的 SHA-256（若有）。
- 不要把 `node_modules/`、`dist/`、`src-tauri/target/` 或真实 secrets 提交。
- 不要把程序生成的数据写回 C 盘用户配置目录；统一使用 `app-data`。
