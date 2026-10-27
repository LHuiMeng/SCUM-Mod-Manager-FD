# SCUM Mods R2 门禁网关（Cloudflare Worker）

把 R2 桶 `scum-mods` 的**唯一**公网入口收敛到这个 Worker，并在入口校验一个
共享密钥。服务器版客户端会在目录请求和下载请求中同时发送旧的
`X-Scum-Gate` 头与 `Authorization: Bearer` 头，两者使用同一个值，因此可兼容
只识别其中一种头的旧服务。R2 桶自身不再挂任何公开自定义域
（`pub-*.r2.dev` 亦已关闭），桶只对本 Worker 的 R2 绑定可见。

## 拓扑

```
服务器版 ──Authorization + X-Scum-Gate──▶ <gate_domain>  (Worker: scum-mods-gate)
                                             │  R2 绑定 env.MODS
                                             ▼
                                       R2 桶 scum-mods  (无任何公开出口)

匿名 / 公开版 ──▶ <catalog_domain>/mods  (只返回公开目录)
                 └─▶ 公共下载入口，不携带任何私人密钥
```

## 部署 / 更新

```bash
export CLOUDFLARE_API_TOKEN="$CLOUDFLARE_USER_TOKEN"
export CLOUDFLARE_ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID"
wrangler deploy --config secrets/cloudflare-scum-mods-gate.wrangler.toml
# 首次或换令牌：
wrangler secret put GATE_TOKEN --config secrets/cloudflare-scum-mods-gate.wrangler.toml
```

`GATE_TOKEN` 与服务器安装包 `secrets/runtime.toml` 中的 `[cloud].auth_token`
同值。公开版安装包不包含该文件，也不读取该密钥。

## 自定义域（wrangler 的 routes 不生效时）

wrangler 4.120 实测不会为 `custom_domain` 路由建 DNS 记录，需用 API 显式挂：

```bash
# 挂载
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/$ACCT/workers/domains" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data '{"zone_id":"<zone>","hostname":"<gate_domain>",
           "service":"scum-mods-gate","environment":"production"}'
# 列出（拿到 domain id 后可 DELETE 回收）
curl "https://api.cloudflare.com/client/v4/accounts/$ACCT/workers/domains" \
  -H "Authorization: Bearer $TOKEN"
```

**同一主机名不能同时属于 R2 自定义域与 Worker 自定义域** —— 换域时必须先删
R2 侧：`DELETE /accounts/$ACCT/r2/buckets/scum-mods/domains/custom/<gate_domain>`。

## 令牌轮换

当前采用单共享密钥，以便仍在使用旧协议的客户端继续访问。轮换前必须先确认
服务器玩家已能同时获取新旧密钥的过渡包，否则旧客户端会立即失去私人目录和
下载权限。

## 验收

`gate_verify.py`（12 条断言：403/206/Range/sha256 逐字节/404/隧道回退）：

```bash
python -u gate_verify.py https://<gate_domain> https://<catalog_domain>
```

## 坑

- `*.workers.dev` 在大陆不可达 → 只能通过自定义域实测，别在全球加速域名上排查。
- Worker 响应的 `Content-Type` 取自对象 httpMetadata（历史上传多为
  `application/x-www-form-urlencoded`），客户端不依赖它，勿据此判定异常。
- 本 Worker 不再透传 Range 头给 R2，而是自己解析后向绑定请求区间 —— 保证
  越界返回 416 且 `Content-Range: bytes */<size>` 语义正确。
