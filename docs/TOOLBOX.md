# 内置工具集合（desire://tools）

地址栏输入 `desire://tools` 打开；`desire://tools/<id>` 直达某个工具；
菜单 **Tools ▸ Utility Toolbox** 也可打开。全部端上计算，无网络请求。

| id | 工具 | 说明 |
|---|---|---|
| hash | 摘要 | MD5 / SHA-1 / SHA-256 / SHA-512（文本 UTF-8） |
| timestamp | 时间戳 | Unix 秒/毫秒自动识别 → 本地/UTC/ISO 8601/相对时间；日期 → 秒/毫秒 |
| base64 | Base64 | 编码/解码，可选 URL-safe |
| url | URL 编码 | 百分号编码/解码（保留 `&=?+` 语义） |
| json | JSON | 格式化/压缩/键排序/校验；错误给行列 |
| text | 文本 | 大小写/标题/蛇形/短横线、行排序/去重/反转/编号、字符/词/行统计 |
| number | 进制 | 十进制/十六进制/二进制/八进制互转（自动识别 0x/0b/0o） |
| uuid | UUID | 批量生成 UUID v4 |
| color | 颜色 | HEX ↔ RGB/RGBA，取色器同步 |
| qr | 二维码 | 文本/URL → 二维码图片，可复制或存 PNG |
| password | 密码 | 长度/字符集/避免易混字符，强度分档 |
| jwt | JWT | 解码 header/payload（**不验签**），显示过期时间 |

实现：纯逻辑 `Features/Tools/ToolboxCore.swift`（tests/run.sh 覆盖），摘要
`ToolsCrypto.swift`（CryptoKit），页面 `ToolsPageView.swift`。
