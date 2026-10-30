# 内置工具集合（desire://tools）

地址栏输入 `desire://tools` 打开全部工具；`desire://tools/<id>` 直达某个工具；
菜单 **Tools ▸ Utility Toolbox** 也可打开。左侧按分类分组（收藏 / 最近使用 /
计算器 / 时间与换算 / 编码转换 / 开发工具 / 文本处理 / 生成与图形），
支持搜索；首页是卡片网格。全部端上计算，无网络请求。

## 计算器
| id | 工具 | 说明 |
|---|---|---|
| mortgage | 房贷计算器 | 等额本息 / 等额本金：月供、总利息、还款总额、完整还款计划表 |
| savings | 存款计算器 | 复利（年/季/月/日）或单利，可选每月定投；到期金额与有效年利率 |
| percent | 百分比计算 | 百分比取值、占比、变化率 |
| scientific | 科学计算器 | 表达式求值（+ - * / % ^、括号、sqrt/sin/cos/ln/log…、pi/e），带历史 |
| bmi | BMI 计算 | 身高体重 → BMI 与中国成人分级 |

## 时间与换算
| id | 工具 | 说明 |
|---|---|---|
| timestamp | 时间戳 | Unix 秒/毫秒自动识别 → 本地/UTC/ISO/相对；日期 → 秒/毫秒 |
| date | 日期计算器 | 两个日期相差天数/周/工作日/年月日；日期加减 |
| units | 单位换算 | 长度/重量/温度/面积/体积/速度/数据（1024 进制）/时间 |
| number | 进制 | 十/十六/二/八进制互转（自动识别 0x/0b/0o） |
| color | 颜色 | HEX ↔ RGB/RGBA，取色器联动 |

## 编码转换
| id | 工具 | 说明 |
|---|---|---|
| base64 | Base64 | 编码/解码，可选 URL-safe |
| url | URL 编码 | 百分号编码/解码 |
| html | HTML 实体 | `&amp;` 等命名实体与数字实体转义/反转义 |
| unicode | Unicode 转义 | 文本 ↔ `\uXXXX`（含 emoji 代理对） |
| hex | Hex 编解码 | 文本 ↔ 十六进制字节 |

## 开发工具
| id | 工具 | 说明 |
|---|---|---|
| hash | 摘要 | MD5 / SHA-1 / SHA-256 / SHA-512 |
| json | JSON | 格式化/压缩/键排序/校验/转 CSV（错误给行列） |
| regex | 正则测试 | 匹配列表与捕获组，忽略大小写/多行 |
| jwt | JWT | 解码 header/payload（**不验签**），显示过期时间 |
| uuid | UUID | 批量生成 UUID v4 |

## 文本与生成
| id | 工具 | 说明 |
|---|---|---|
| text | 文本 | 大小写/标题/蛇形/短横线、行排序/去重/反转/编号、统计 |
| qr | 二维码 | 文本/URL → 二维码图片，可复制或存 PNG |
| password | 密码 | 长度/字符集/避免易混字符、强度分档 |

实现：`Features/Tools/`（纯逻辑 *Core 文件进 tests/run.sh；页面拆为
ToolsPageView / ToolsCalcViews / ToolsCodecViews / ToolsDevViews /
ToolboxComponents；目录与元数据在 ToolboxCatalog）。

## 外部深链

`desire://` 已在 Info.plist 注册（`CFBundleURLTypes`），`application(_:open:)`
会把 `desire://tools[/<tool>]` 路由成新的工具标签页（冷启动有窗口就绪重试）。
**只有安装了注册该 scheme 的版本后**，从 Finder / 其他应用点开深链才会生效；
旧版本会弹 macOS「未设定用来打开 URL 的应用程序」。自动化可用桥
`POST /open-url {"url":"desire://tools/mortgage"}`。
