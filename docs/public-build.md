# 对外版（无云）构建与交付说明

> 本文档说明「对外版」——即不连接任何私有云服务器的 SCUM Mod Manager 分发形态。
> 适用于：不属于特定服务器的普通玩家、公开渠道分发、需要零网络依赖的场景。

## 一、为什么有对外版

SCUM Mod Manager 原本内置「云上mod 目录」「在线更新」等能力，地址指向
服务器运营者私有设施。若把这种构建直接发给普通玩家：

1. 玩家会请求私有服务器（无权限/无意义，且暴露运营者基础设施地址）；
2. 玩家拿到的是面向特定服务器的 mod 源，与自己的游戏环境无关。

对外版在**同一份源码**上通过**不注入云源地址**实现：功能面板全部保留
（云上mod 面板、远程服务器面板照常显示），但没有任何默认连接目标，
不发起任何到私有服务器的网络请求。

## 二、实现原理

源码零硬编码域名。所有云服务地址均通过编译期 `--dart-define` 注入：

| dart-define | 用途 | 对外版（不注入） | 内部版（注入） |
|---|---|---|---|
| `REGISTRY_BASE_URL` | 云上mod 目录基础地址 | 空 → 面板空列表 | 真实地址 |
| `UPDATE_MANIFEST_URL` | 在线更新 manifest 地址 | 空 → 更新链路静默跳过 | 真实地址 |
| `UPDATE_VERIFY_KEY` | 更新签名验签密钥 | 不注入 | `update_secret.json` 注入 |

关键代码位置：

- `lib/services/mod_registry_client.dart` — `_defaultBaseUrl` 用
  `String.fromEnvironment('REGISTRY_BASE_URL', defaultValue: '')`；base 为空时
  `fetchModList` 直接返回空列表、`downloadMod` 直接返回「云源未配置」，零请求。
- `lib/services/update_service.dart` — `_manifestUrl` 用
  `String.fromEnvironment('UPDATE_MANIFEST_URL', defaultValue: '')`；
  `checkOnStartup` 在无更新源时静默跳过。
- `lib/widgets/update_button.dart` — 下载前复用 `UpdateService.manifestUrl`，
  空源直接返回 null。

## 三、构建对外版

### 方法 A：一键脚本（推荐）

```bash
build_public.bat
```

产出（在 `build/dist/`）：

| 产物 | 说明 |
|---|---|
| `scum_mod_manager_v2.6.5_public_setup.exe` | NSIS 安装器（v3 布局：引导器 + versions/） |
| `scum_mod_manager_v2.6.5_public_portable/` | 便携版（解压即用） |

### 方法 B：手动

```bash
flutter pub get
flutter build windows --release --dart-define=APP_VERSION=2.6.5
```

构建产物：`build/windows/x64/runner/Release/scum_mod_manager_app.exe`。

便携版需按 v3 安装根布局组装：

```
便携根/
├── scum_mod_manager.exe          # 引导器（launcher）
├── app.json                      # {"current":"2.6.5"}
└── versions/2.6.5/
    ├── scum_mod_manager_app.exe
    ├── flutter_windows.dll
    └── data/                     # app.so + flutter_assets + icudtl.dat
```

## 四、对外版行为差异

| 功能 | 对外版行为 |
|---|---|
| 云上mod 面板 | 面板可见，列表为空；用户可在 config.json 的 `cloud_sources.base_url` 自行配置第三方源 |
| 在线更新按钮 | 永不出现（无更新源，检查静默跳过） |
| 远程服务器面板 | 正常可用（SFTP 地址由用户自行填写，与管理器云服务无关） |
| 本地模组管理 / 游戏启动 / UE4SS | 与内部版完全一致 |

## 五、验证清单（对外版发布前）

1. `grep -r 'scum-mods\.' build/windows/x64/runner/Release/data/app.so` 无命中
   （对外版产物不得含任何私有域名字节）。
2. 便携版顶层含 `app.json` + `versions/<ver>/` 完整结构。
3. 启动后标题栏版本号正确、无更新按钮、云上mod 面板显示空态。
4. NSIS 安装器静默安装到临时目录验证（`/S /D=...`），卸载无残留。

## 六、内部版回归（改完对外版必须验证）

对外版与内部版同源码，改任何云相关代码后，内部版发布流程
（`build_release.ps1 -RegistryUrl ...`）必须回归：

```bash
powershell -File build_release.ps1 -Version 2.6.5 -RegistryUrl https://你的云源地址 -SkipUpload
```

验证 `data/app.so` 同时含版本号与注入的 verify key（脚本内置校验）。
