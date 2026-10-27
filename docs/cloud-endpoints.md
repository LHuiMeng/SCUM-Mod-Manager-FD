# 云源多线路（镜像域名）说明

> 仓库内文档只保留脱敏后的运维流程。真实账户、隧道、Zone、DNS 记录标识与生产
> 域名保存在本机被 Git 忽略的 `secrets/cloud-infrastructure.private.md`。

## 背景

部分玩家（尤其大陆部分 ISP / 被安全软件与家庭路由器黑名单误拦的网络）
无法访问云库主域名（Cloudflare 前置）。客户端原先只有单个 `base_url`，
请求失败即静默返回空列表 —— 玩家只看到「云上暂无可用 mod」，无法自查、
也无法自动恢复。

## 客户端行为（方案 A：多端点自动切换）

- `config.json` 的 `cloud_sources.base_urls` 是**有序候选线路**；启动时
  `RegistryClient.ensureCloudSourceConfigured` 会把打包默认线路并入
  （仅当用户仍在使用官方云源时；自建源保持用户自己的线路不变）。
- 刷新云目录 [`fetchModList`]：
  1. 先单独请求首选线路（30s 超时，成功即返回，正常路径零额外开销）；
  2. 首选失败 → 其余线路**并行**探测（各 8s），取最先成功者；
  3. 胜出线路写入 `cloud_sources.active_base_url`，下次直连它。
- 下载 [`downloadMod`]：按 `自定义地址 → 清单直达地址（R2/CDN）→ 各候选线路
  默认拼接地址` 依次尝试，任一条成功即止；走通 registry 线路时记为活跃线路。
- 全部线路失败：返回空列表，并写入 `AppLogger`（含各线路失败详情），
  面板空态显示「无法连接云服务器」。

## config.json 相关字段

```json
{
  "cloud_sources": {
    "base_url": "https://<primary_domain>",
    "base_urls": [
      "https://<primary_domain>",
      "https://<mirror_domain>"
    ],
    "active_base_url": "https://<mirror_domain>",
    "mods": {}
  }
}
```

- `base_url`：旧版单地址，仍兼容（无 `base_urls` 时视为单元素列表）。
- `base_urls`：候选线路（自动切换依据）。用户手改后以此为准。
- `active_base_url`：**自动写入**的最近成功线路，无需手工维护。

## 新增镜像线路（方案 B 第一条）

要点：换一个与主域名**不同后缀/注册商**的域名，规避域名级拦截与
「免费 DDNS 后缀被整段拉黑」，但仍指向**同一个 Cloudflare Tunnel**。

1. Cloudflare Zero Trust → Networks → Tunnels → 选中隧道 → **Public Hostnames**
   → Add a public hostname：hostname 填 `<mirror_domain>`，Service 指向与主域名
   完全相同的 origin（同一隧道可挂多个 hostname）。保存后 Cloudflare 会自动
   创建 DNS 记录（`CNAME <tunnel-id>.cfargotunnel.com`）。
2. 若隧道由本地 `config.yml` 管理：在 `ingress` 增加一条
   `- hostname: <mirror_domain>` + `service: ...`，并保留末尾
   `- service: http_status:404` 兜底，然后重启 cloudflared。
3. 纯 API 等价操作（本例实际走的路；Token 需带 `Cloudflare Tunnel:Edit`）：

   ```bash
   ACCT=<account_id>; TOKEN=<api_token>
   TID=<tunnel_id>                                 # scum-mods-tunnel
   ZID=<zone_id>                                   # 镜像域名所在 Zone

   # 先读现有 ingress —— 写入是整体覆盖，必须带上原有规则
   curl -s -H "Authorization: Bearer $TOKEN" \
     "https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel/$TID/configurations"

   # 追加 hostname（末尾 http_status:404 兜底不可省）
   curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     "https://api.cloudflare.com/client/v4/accounts/$ACCT/cfd_tunnel/$TID/configurations" \
     --data '{"config":{"ingress":[{"hostname":"<primary_domain>","service":"http://127.0.0.1:6000"},{"hostname":"<mirror_domain>","service":"http://127.0.0.1:6000"},{"service":"http_status:404"}],"warp-routing":{"enabled":false}}}'

   # 建 DNS（apex 走 CNAME 展平，必须 proxied=true）
   curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records" \
     --data '{"type":"CNAME","name":"<mirror_domain>","content":"<tunnel_id>.cfargotunnel.com","proxied":true,"ttl":1}'
   ```

4. 验证可达（应返回 200；断点续传应为 206）：

   ```bash
   curl -sS -o /dev/null -w "%{http_code}\n" https://<mirror_domain>/mods
   curl -sS -o /dev/null -w "%{http_code} %{size_download}\n" \
     https://<mirror_domain>/mods/chest-max-weight/download
   curl -sS -o /dev/null -w "%{http_code}\n" -r 0-1023 \
     https://<mirror_domain>/mods/chest-max-weight/download
   ```

### 上线记录（2026-10-18，已实测）

| 资源 | 值 |
|------|-----|
| 镜像域名 | `<mirror_domain>`（apex，非子域） |
| zone | `<zone_id>` |
| 隧道 | `scum-mods-tunnel` / `<tunnel_id>`（远端托管） |
| ingress | `<primary_domain>`、`<mirror_domain>` → `http://127.0.0.1:6000`，末尾 `http_status:404` |
| DNS | `CNAME <mirror_domain>` → `<tunnel_id>.cfargotunnel.com`（proxied） |
| 安全等级 | `essentially_off`（新域名默认是 `medium`，已主动对齐主域名） |

实测：`/mods` 返回 200，目录与主域名逐字段一致（仅 `generated_at` 时间戳不同）；
`/mods/chest-max-weight/download` 返回 200 / 43285 B；Range 请求返回 206；Dart 与
启动器 UA 均未被挑战。

### 回滚

```bash
# 1) 删 DNS 记录
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<zone_id>/dns_records/<dns_record_id>"
# 2) 把 ingress 改回只含主域名的那一份（PUT 同一 URL，body 里去掉镜像域名那条）
```

## 发布注入

旧版 `build_release.ps1` 默认带
`-RegistryMirrorUrls "https://<mirror_domain>"`，会注入
`--dart-define=REGISTRY_BASE_URLS=...`（仅当同时提供了 `-RegistryUrl`）。

- 想加更多镜像：`-RegistryMirrorUrls "https://a,https://b"`。
- 想临时关闭镜像：`-RegistryMirrorUrls ""`。
- 对外分发（`build_public.bat`）不注入任何域名 → 天然无云源，不受影响。

## 2026-10-20 架构变更：目录改由 Worker 直读 R2

原来的目录（`/mods`）由 `scum-mods-tunnel` 背后那台机器上的 Python registry
提供，写入口只有那台机器的 SSH。该机已不可用（且不属于本账号），因此：

| 层 | 旧 | 新 |
|---|---|---|
| 目录 | 隧道 → 源站 `python server.py` | Worker `scum-mods-catalog` → R2 桶 `scum-mods` |
| 文件 | CDN 网关（gate）← R2 | 不变（`mods-cdn` + `X-Scum-Gate`） |
| 回退下载 | 源站 `/mods/<id>/download` | Worker 直接从 R2 流式返回（支持 Range） |
| 发布 | SSH 进源站拷文件 | **往 R2 PUT `mods/<id>/pak` + `mods/<id>/manifest.json`** |

- Worker 源码：`<catalog_worker_directory>/{worker.js,wrangler.toml}`
- 目录在 isolate 内缓存 30 秒；manifest 里的 `download_url` 仍指向 CDN 网关
- 两个主机名（`<primary_domain>`、`<mirror_domain>`）都以
  Workers Custom Domain 形式绑到同一个 Worker
- 旧隧道 `scum-mods-tunnel` 已强制清连接并删除

发布脚本：`<catalog_worker_directory>/publish_mod.py <manifest.json> <pak>`
（自动补 size/sha256/download_url、上传、回读校验）。

回滚到隧道方案（若那台机恢复可控）：删掉两个 Workers Custom Domain，
再把 CNAME 指回 `<tunnel-id>.cfargotunnel.com` 并在隧道 ingress 里配
`http://127.0.0.1:6000`。
