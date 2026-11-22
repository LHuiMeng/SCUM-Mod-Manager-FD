# 界面翻译覆盖

程序启动和切换语言时会读取应用数据目录中的翻译覆盖文件：

```text
app-data/locales/zh-CN.json
app-data/locales/en-US.json
```

首次启动会自动创建 `app-data/locales/`，并补齐本说明及两份示例文件（不会覆盖已有文件）。
用户文件中的 key 会覆盖内置翻译；
未填写的 key 自动回退到程序内置字典。修改后重新切换一次语言，或重启应用即可
生效，无需重新编译。

## 文件结构

文件必须是一个 JSON 对象，可以使用嵌套对象。下面两种 key 写法等价：

```json
{
  "library": {
    "title": "我的模组库",
    "scan": "重新扫描"
  }
}
```

```json
{
  "library.title": "我的模组库",
  "library.scan": "重新扫描"
}
```

只需写想覆盖的条目，不必复制全部 key。字符串中的 `{name}`、`{count}` 等占位符
由程序在运行时替换，请保留需要的占位符。

英文内置文案对 `{count}` 为 1 的情况提供了 `.one` 单数 key。例如
`common.conflictCount.one` 会用于替代 `common.conflictCount`；用户自定义的
基础 key 仍优先于内置单数文案，需要单独定制单数时再填写 `.one` key。

启动时会在同目录补齐以下文件：

- `zh-CN.example.json`：完整中文 key 模板
- `en-US.example.json`：完整英文 key 模板
- `override-example.json`：只覆盖少量条目的最小示例
- `README.md`：本说明

需要完整翻译时，把 `zh-CN.example.json` 或 `en-US.example.json` 复制为
`zh-CN.json` / `en-US.json` 后修改；只调整部分文本时，可参考
`override-example.json` 只保留要覆盖的 key。程序不会覆盖已存在的用户文件。

## 注意

- 单个文件最大 512 KiB，根节点必须是 JSON 对象；数组和 `null` 值会被忽略。
- 语言代码目前支持 `zh-CN` 与 `en-US`。
- 无效 JSON 不会阻止程序启动：程序会保留内置翻译并显示读取警告。
- 模组名称、作者、简介、标签和备注属于模组数据，不是界面翻译 key。
