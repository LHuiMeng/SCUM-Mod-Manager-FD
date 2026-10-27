# 云源接口与安全约定

本文描述 SCUM Mod Desk v3 当前的 React + Rust 云源实现。发布构建可从被 Git
忽略的 `secrets/runtime.toml` 的 `[cloud].base_urls` 注入默认线路；地址不出现
在 React、Rust 源码或测试中。首次启动会把默认线路写入本机配置，之后用户配置
优先。服务器版共享密钥只由 Rust 后端从 `secrets/runtime.toml` 或安装包内的
`runtime-secrets/runtime.toml` 读取。

## 本机配置

配置保存在 `{程序目录}/app-data/config.json`：

```json
{
  "cloud": {
    "baseUrls": [
      "https://mods.example.test",
      "https://mirror.example.test"
    ],
    "activeBaseUrl": "https://mods.example.test"
  }
}
```

- `baseUrls` 是有序候选线路；读取配置时会去重并从前到后尝试。
- `activeBaseUrl` 是最近成功线路；刷新时会优先尝试，成功后再写回配置。
- `config.json` 当前没有线路时，Rust 会写入构建时注入的默认线路；已有线路
  不会被覆盖。
- 云源只接受 HTTPS。仅 `localhost`、`127.0.0.1` 和 `::1` 允许使用 HTTP，
  用于本机开发。
- 带用户名或密码的 URL 会被拒绝。配置中不得写入访问令牌。

## 目录接口

客户端请求：

```http
GET {baseUrl}/mods
Accept: application/json
```

服务器版在请求目标与已配置云源同源时，额外发送：

```http
Authorization: Bearer <shared-key>
X-Scum-Gate: <shared-key>
```

公开版不加载也不发送共享密钥。服务器版凭据不会发送给 CDN、第三方域名或
任何未在 `baseUrls` / `activeBaseUrl` 中配置的来源。HTTP 客户端只跟随同源
重定向，跨源重定向会停止并作为失败处理。

响应可以是数组，也可以使用 `mods`、`items` 或 `catalog` 字段包裹：

```json
{
  "mods": [
    {
      "id": "example-mod",
      "name": "示例模组",
      "author": "Example",
      "version": "1.0.0",
      "description": "目录说明",
      "fileSize": 1048576,
      "downloadUrl": "https://cdn.example.test/example-mod.pak",
      "sha256": "64-character-lowercase-hex",
      "tags": ["client"],
      "updatedAt": "2026-10-27T00:00:00Z",
      "type": "clientPak"
    }
  ]
}
```

字段兼容 `download_url`、`fileSize`/`file_size`/`size`、`updated_at` 和
`mod_type` 等旧写法。`id` 缺失时使用 `slug`，再回退到安全化后的名称。

## 下载与校验

下载地址按以下顺序尝试：

1. 清单中的 `downloadUrl` / `download_url`
2. `{baseUrl}/mods/{id}/download`

客户端执行以下约束：

- 下载地址必须使用 HTTPS；仅本机回环地址允许 HTTP。
- 清单提供 `sha256` 时，下载完成后必须匹配，否则删除临时文件并继续尝试
  下一候选地址。
- 清单未提供 `sha256` 时，只允许从已配置云源的同源地址下载；跨源 CDN
  下载会被跳过。
- 未提供校验值时下载结果会明确提示“未执行完整性校验”，不会显示为已通过
  校验。
- 云目录响应与下载文件使用独立的超时；临时文件名包含进程 ID 和原子序号，
  同一模组 ID 的并发下载会被 Rust 后端拒绝。
- 下载完成后 PAK 放入本地 `~mods/`，UE4SS ZIP 使用安全解包并放入
  `ue4ss_runtime/ue4ss/Mods/<模组名>/`。

生产云目录应始终提供 SHA-256。它是跨源 CDN 下载和完整性问题定位的必要
校验值。

## 错误处理

候选线路、目录请求或下载全部失败时，错误信息会汇总各线路的 HTTP 状态或
校验失败原因。日志和错误信息不得包含共享密钥、Cookie、Authorization 头或
带凭据的 URL。
