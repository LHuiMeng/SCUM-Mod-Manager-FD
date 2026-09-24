# 更新架构统一规划 v3 —— 引导器 + 版本目录模型

> 背景：v2.6.x 期间更新链路反复出事故（自锁 error 32、用户数据被清、发布包缺件、manifest 半包窗口、老用户救不活）。
> 共同病灶 = **应用在运行中替换自身所在目录**（Windows 镜像锁）。本规划从根上换模型，一劳永逸。

---

## 一、设计原则（铁律）

1. **绝不替换运行中的文件** —— 一切更新写入新目录/新文件，永不与运行中镜像争锁 → error 32 一族问题物理不可能发生。
2. **用户数据与程序本体分离** —— 用户数据永远在安装根目录，程序本体在 `versions/<ver>/` → 更新零数据风险，删除整套「备份→回迁」易错逻辑。
3. **单一入口、单一职责** —— 引导器只做「读指针 → 启动应用」；应用自己做「下载 → 解压 → 校验 → 写指针」。删除 updater.exe 与 C++ 备份协议。
4. **发布原子性** —— 新版本先落 staging，验签通过才原子改名；manifest 由发布脚本显式生成上传，杜绝「zip 未就绪 manifest 已指向」的半包窗口。
5. **版本号强制自校验** —— 发布脚本 build 后自动在 app.so 里搜目标版本串（UTF-16LE），搜不到直接失败，禁止发布。

---

## 二、目录布局

```
{install}/
├── scum_mod_manager.exe          # 引导器（轻量 C++，永不自我替换，唯一稳定入口）
├── app.json                      # {"current":"v2.6.3","rollback":"v2.6.2"}
├── versions/
│   ├── v2.6.3/                   # 完整应用（scum_mod_manager_app.exe + flutter_windows.dll + data/）
│   └── v2.6.4/                   # 新版本：staging 校验后原子改名落位
├── ~mods/  ue4ss_runtime/  config.json  mods_meta.json   ← 用户数据永远在顶层
├── logs/  assets/  ~merged/  server_mods.db
```

## 三、启动链

```
双击 scum_mod_manager.exe（引导器）
  → 读 app.json.current
  → 校验 versions/<current>/scum_mod_manager_app.exe 存在（缺失 → 回退 rollback / 提示重装）
  → 设环境变量 SCUM_MM_ROOT=<install>
  → CreateProcessW 启动 versions/<current>/scum_mod_manager_app.exe
```

- Dart 侧新增 `AppPaths` 单例：`root = env[SCUM_MM_ROOT] ?? Platform.resolvedExecutable.parent`
- lib/ 现有 14 处 `File(Platform.resolvedExecutable).parent.path`（app_logger / conflict_service / mod_registry_client / mod_service / merge_service / ue4ss_framework_service / background_service / server_sftp_service）全部改走 `AppPaths.instance.root` —— 用户数据路径语义与现状完全一致，仅取根方式统一。

## 四、更新链（全部在 Dart 内完成）

1. manifest 拉取 + HMAC 验签（沿用现有 `update_service.dart`）
2. 下载 zip → `{root}/versions/.staging/v2.6.4.zip`（part→rename 两阶段，沿用 download_service）
3. sha256 校验（对 manifest.exe_sha256）
4. 解压 → `{root}/versions/.staging/v2.6.4/`
5. 完整性校验：`data/app.so` 存在 **且** 版本串 == manifest.version（UTF-16LE 搜索）
6. **原子提交**：`.staging/v2.6.4` rename → `versions/v2.6.4`；改写 app.json（current=v2.6.4, rollback=旧 current）；清 .staging
7. 提示用户重启生效（运行中的仍是旧目录，不锁不冲突）
8. 清理：保留最近 2 个版本目录（可回滚），更旧的删除

**不关闭应用也能完成更新** —— 这是本模型与旧模型的本质区别。

## 五、回滚

- 引导器检测 `versions/<current>/` 关键文件缺失 → 自动读 rollback 启动旧版并提示
- 手动回滚 = 改 app.json 一个字段（零风险）
- （可选后续）应用内「回滚到上一版本」按钮

## 六、发布流程改造（build_release.ps1）

1. `flutter build windows --release` 注入 `APP_VERSION` + `update_secret.json`（现有）
2. **新增自校验**：build 后搜 `data/app.so` 的 UTF-16LE 版本串 == 目标版本，不匹配 → 失败退出
3. 打包 zip 布局 = `versions/<ver>/` 内容（app 本体），不含引导器与用户数据
4. **manifest 显式生成**：复用 make_manifest.js（canonical + HMAC），**先传 zip → 再传 manifest**（保证客户端命中新版本时 zip 必已就绪）
5. 上传走 staging 目录 → 原子改名

## 七、老用户迁移（2.6.1 / 2.6.2 → 新架构）

死锁本质：旧 updater(48640) 无自我放逐、旧管理器不复制 updater 到 TEMP —— **已分发的二进制无法自动救活**。
迁移包设计为「兼容旧 updater 解压流程」，让老用户只需一次手动动作即可闭环：

1. **迁移包 zip 布局**（zip 根 = 安装根，满足旧 updater 的 exe 信标检查）：
   ```
   scum_mod_manager.exe            # 新引导器（信标，必须存在）
   app.json                        # {"current":"v2.6.3"}
   versions/v2.6.3/…               # 完整应用（app exe + DLL + data/）
   scum_mod_manager_updater.exe    # 新 updater(55296) 兼容壳 —— 新架构不用，但迁移后
   ```
   旧 updater 流程可完整走通：整目录备份 → 解压迁移包 → 回迁用户数据（~mods/ue4ss_runtime/config.json…）到新根 → 启动新引导器。
2. **老用户触发路径**（唯一一次手动动作）：
   - 云端发布独立文件 `updater_fix.exe`（= 新 updater 单文件）
   - 指引：下载 → 关闭管理器 → 覆盖安装目录 updater.exe → 启动管理器点更新
   - 新 updater 自愈放逐到 %TEMP% → 不再锁目录 → 解压迁移包 → 迁移完成
3. 迁移后：用户数据零丢失（旧 updater 回迁逻辑已验证），此后升级走新链路。
4. 兜底：老用户也可直接下载完整安装包手动覆盖（关管理器 → 解压覆盖 → 启动引导器），zip 不含用户数据目录故不受影响。

## 八、代码改造清单

| 模块 | 改动 |
|---|---|
| `windows/launcher/launcher_main.cpp`（新） | 引导器：读 app.json → 校验 → 传 SCUM_MM_ROOT → 启动 app |
| `windows/CMakeLists.txt` | 新 target（launcher）；原 runner 产物改名 `scum_mod_manager_app.exe` |
| `lib/services/app_paths.dart`（新） | root 单例：env SCUM_MM_ROOT ?? resolvedExecutable.parent |
| lib/ 8 文件 14 处 resolvedExecutable | 全改 `AppPaths.instance.root` |
| `lib/services/update_service.dart` | 下载路径 → versions/.staging/；新增解压 + 完整性校验 + 原子提交 + app.json 写入 |
| `lib/services/download_service.dart` | 复用（zip 下载 + sha256） |
| `lib/widgets/update_button.dart` | 更新完成 → 「重启生效」提示 |
| `windows/runner/window_service_channel.cpp` | 删除 launchUpdater 通道；其余保留 |
| `windows/runner/updater_main.cpp` | 源码保留（供迁移包兼容壳与手动救援），不再进新架构主流程 |
| `build_release.ps1` + `package_zip.ps1` + `make_manifest.js` | 布局改造 + 版本自校验 + manifest 显式生成 + 迁移包产出 |

## 九、风险与对策

| 风险 | 对策 |
|---|---|
| 用户绕过引导器直接双击 app exe → root 回落自身目录，数据落 versions/ 下 | 发布物只给引导器入口；引导器极小（<50KB、无网络、无注入），被安全软件拦截概率低 |
| 解压/提交中途断电 → .staging 残留 | 启动时清理 .staging；app.json 写入前崩溃 → current 未变仍旧版，天然安全 |
| 旧 updater 回迁逻辑对迁移包漏项 | 迁移包含顶层全部用户数据占位逻辑（沿用 v2.6.3 已验证的 kUserData 列表） |

---

## 十、v3.1 轻量化更新：完整包 / 增量包双形态（主人 2026-09-22 定规则）

> 规则：① 更新包可携带完整更新包，也可携带**部分替换文件**（增量）更新，追求轻量化；
> ② 按指定规范生成更新包，由**一键脚本**产出。

### 10.1 双形态

| 形态 | 内容 | 体积 | 使用条件 |
|---|---|---|---|
| **完整包** `scum_mod_manager.zip` | 整个新版本目录内容 | 全量（~20MB） | 无旧版本 / 增量包不可用 / 增量安装失败兜底 |
| **增量包** `delta_<from>_to_<to>.zip` | 仅变更文件（`files/`）+ 删除清单 | 变更量（小更新仅数百 KB） | 客户端当前版本 == 增量包 `base` |

### 10.2 增量包格式（规范）

```
delta_2.6.4_to_2.6.5.zip
├── manifest.json        # {"from":"2.6.4","to":"2.6.5",
│                        #  "delete":["data/old.bin", ...],  相对 versions/<to>/ 的删除清单
│                        #  "files":["data/app.so", ...]}    相对路径清单（供校验）
└── files/
    ├── data/app.so      # 新增/变更文件，路径 = 相对 versions/<to>/
    └── ...
```

### 10.3 云端配套文件（v<Version>/ 目录）

```
v2.6.5/
├── scum_mod_manager.zip                     # 完整包（现有）
├── delta_2.6.4_to_2.6.5.zip                 # 增量包（可选）
└── delta_manifest.json                      # 增量清单（HMAC 签名，客户端可信入口）
```

`delta_manifest.json`（由一键脚本用 UPDATE_VERIFY_KEY 签名，canonical 同主 manifest 风格）：
```json
{
  "to": "2.6.5",
  "base": "2.6.4",
  "delta_url": "/app/v2.6.5/delta_2.6.4_to_2.6.5.zip",
  "delta_sha256": "<hex>",
  "delta_size_bytes": 123456,
  "signature": "<HMAC-SHA256 base64>"
}
```

### 10.4 客户端流程（update_service.dart）

1. 主 manifest 检测到新版本 → 点「下载」时**先探增量**：GET `{exe_url 目录}/delta_manifest.json`
   - 200 + 验签通过 + `base == 当前版本` → **下载增量包**（轻量）→ sha256 校验 → 标记「增量安装」
   - 否则（404 / 验签失败 / base 不匹配）→ 回退下载完整包
2. **增量安装** `installDelta`：
   1. 复制 `versions/<base>/` → `versions/.staging/<to>/`（同卷快）
   2. 解压增量包 `files/` 覆盖对应路径；按 `delete` 清单删除
   3. 校验 `data/app.so` 版本串 == `to`（与完整包同一道关口）
   4. 原子改名 `.staging/<to>` → `versions/<to>`；写 app.json（current=to, rollback=base）
   5. 清理 .staging 与保留数之外旧目录
3. 增量安装失败（base 缺失 / 校验不过 / 中途异常）→ **自动回退完整包路径**，不中断用户体验

### 10.5 一键生成脚本 `make_update_pkg.ps1`

```powershell
# 用法（build_release.ps1 自动调用，也可独立跑）：
powershell -File make_update_pkg.ps1 -To 2.6.5 -From 2.6.4
# -From 省略 → 只产完整包；-From 提供 → 自动从云端拉 v<From> 完整包做对比，产出增量包
```

流程：
1. 读 Release 产物（新版本本体）→ 打**完整包** `scum_mod_manager.zip`
2. `-From` 提供时：从云端下载 v<From> 完整包 → 解压 → **逐文件对比**（存在性 + sha256）
   - 同 → 跳过；新/异 → `files/`；仅旧有 → `delete` 清单
   - 差异为 0 → 不产增量包（提示）
3. 打**增量包** `delta_<from>_to_<to>.zip`（含 zip 内 manifest.json）
4. 生成并签名 `delta_manifest.json`
5. 全部产物放 `build/dist/`，供 build_release.ps1 原子上传

### 10.6 关键设计决策

- **轻量化收益**：小版本（仅改 app.so / 若干资产）增量包可小至几百 KB～数 MB，慢网络用户体验质变；完整包始终在云端兜底，增量不可用时零损失。
- **安全链**：`delta_manifest.json` 用与主 manifest 相同的 HMAC key 签名（canonical 字段含 base/to/url/sha/size）→ 客户端验签后按声明的 sha 下载增量 zip → zip 内 manifest.json 再自校验 from/to → 全链防篡改。
- **增量包的基准**：`base` 必须等于客户端当前版本，否则客户端**拒绝增量、走完整包**——服务端无需为不同旧版本生成多份增量（每版只对上一版出一份，跨版用户自然走完整包）。
- **不侵入主 manifest**：增量信息独立放 `delta_manifest.json`（服务端主 manifest 动态生成逻辑零改动，增量文件按静态文件上传即可）。
