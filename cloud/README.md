# GitHub 云端目录

本目录是 SCUM Mod Desk 的公开云端目录，根地址为：

```text
https://raw.githubusercontent.com/LHuiMeng/SCUM-Mod-Desk-Cloud/main/cloud
```

客户端会请求 `{根地址}/mods`，因此 `mods` 是无扩展名的 JSON 目录文件。资产发布到
独立的公开仓库 `LHuiMeng/SCUM-Mod-Desk-Cloud`，源码仓库继续保持私有。

```text
cloud/
├─ mods          # 云端目录 JSON
└─ paks/         # 白名单中的客户端 PAK 文件
```

## 更新目录

先更新源目录中的 PAK，再在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-github-cloud.ps1
```

脚本使用固定 19 项白名单，不会自动发现或上传源目录中的其他文件。它会复制
PAK、清理 `cloud/paks` 中不再属于白名单的顶层文件、重新计算完整 SHA-256
与字节数，并生成 UTF-8、无 BOM 的 `cloud/mods`。

本目录中的 `mods` 与 `paks/*.pak` 是生成物，已由源码仓库忽略。生成后请将
`cloud/mods` 和整个 `cloud/paks/` 同步到公开仓库
`LHuiMeng/SCUM-Mod-Desk-Cloud` 的 `cloud/` 目录，再在该仓库提交并推送。

## 发布边界

以下三个 PAK 不属于发布范围，脚本不会复制或写入目录：

- `cat背包.pak`
- `1144服务器定制.pak`
- `美乐蒂背包.pak`

GitHub 对单个文件有 100 MiB 硬限制，并对超过 50 MiB 的文件给出警告。当前
最大文件约 85.6 MiB，低于硬限制。更新大文件后应先运行脚本检查大小，再提交
并推送；如后续超过限制，需改用 Git LFS 或 GitHub Release 资产。
