# 模组展示模板

把下面两类文件与模组放在一起，SCUM Mod Desk 会在模组库和检查器中显示
封面、作者和展示说明。图片不是运行模组所必需的；缺失、格式不符或加载失败
时会自动回退到名称字母块，不影响扫描、启用或部署。

## PAK 模组

`Foo.pak` 与展示文件放在同一个目录：

```text
~mods/
├─ WeaponPack.pak
├─ WeaponPack.mod.json
└─ WeaponPack.cover.png
```

`WeaponPack.mod.json`：

```json
{
  "author": "IslandWorks",
  "description": "替换武器外观，保持原有数值与掉落表不变。",
  "cover": "WeaponPack.cover.png"
}
```

- `cover` 可省略；省略时依次查找 `WeaponPack.cover.png`、`.jpg`、`.jpeg`、
  `.webp`。
- 也可以完全省略 JSON，只放同名 `WeaponPack.cover.png` 等图片。
- `author`、`description` 均为可选字段。description 最多展示 1200 个字符。
- 兼容旧命名 `WeaponPack.presentation.json`。
- 打成 ZIP 时，`*.pak`、`*.mod.json`（或 `*.presentation.json`）和
  `*.cover.*` 会一起导入；无关文件不会解出。

## UE4SS 模组

把 `mod.json` 和封面放在模组目录根部：

```text
ue4ss_runtime/ue4ss/Mods/
└─ BetterAI/
   ├─ Scripts/
   ├─ mod.json
   └─ cover.png
```

```json
{
  "author": "Northstar",
  "description": "改进 AI 感知范围与巡逻行为，兼容当前服务器配置。",
  "cover": "cover.png"
}
```

未声明 `cover` 时，先查找 `cover.png` / `cover.jpg` / `cover.jpeg` /
`cover.webp`，再查找 `preview.*` 同名格式。兼容旧命名
`presentation.json`。

## 云端目录

在目录 JSON 的每个模组上增加以下任一字段，客户端会把它作为卡片封面：

```json
{
  "coverUrl": "images/weapon-pack.webp"
}
```

兼容 `cover_url`、`imageUrl`、`image_url`、`cover`、`image`。相对地址按当前
云源地址解析，也可使用完整 HTTPS 地址。只接受 HTTPS；本机回环地址可在开发
环境使用 HTTP。`javascript:`、`data:` 等协议会被忽略并回退字母块。

## 图片要求

- 推荐尺寸：`640 × 360`（16:9），最小 `320 × 180`。
- 支持格式：PNG、JPEG、WebP。
- 单张图片最大 2 MiB；建议压缩到 500 KiB 以内。
- 图片必须是真实文件内容，仅改扩展名而不转换格式会被拒绝。
- 为浅色和深色主题选择对比度稳定的画面，重要内容放在中央安全区。
- 本地文件只读取模组目录内的图片；不会把绝对路径传给前端。

## 回退规则

1. 读取展示 JSON 中显式声明的封面。
2. 按约定文件名查找同目录封面。
3. 都没有或图片校验失败时，使用模组名称字母块。

模板目录内附有最小 PNG 占位图，可直接替换成自己的封面。
