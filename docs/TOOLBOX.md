# 内置工具集合（desire://tools）

地址栏输入 `desire://tools` 打开全部工具；`desire://tools/<id>` 直达某个工具；
菜单 **Tools ▸ Utility Toolbox** 也可打开。左侧按分类分组（收藏 / 最近使用 /
计算器 / 时间与换算 / 编码转换 / 开发工具 / 文本处理 / 生成与图形 / 媒体 /
文档 / 安全与校验），支持搜索；首页是卡片网格。左侧栏可拖动（原生 NSSplitView
分隔条，180–380pt，宽度跨次记住）。悬浮球的「全部能力」里新增「工具箱」，
一键进入本页。全部端上计算，无网络请求。

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

## 扩展批（43 项，2026-10-30）
### 计算器 / 时间
（原有：房贷、存款、百分比、科学计算器、BMI、时间戳、日期、单位、进制、颜色）

### 编码转换（新增）
| id | 工具 | 说明 |
|---|---|---|
| morse | 摩斯电码 | 文本 ↔ Morse（字母/数字/常用标点） |
| dataURI | Data URI | 文本或文件 → data URI；URI → 文本/二进制大小 |
| width | 全角/半角 | ASCII ↔ 全角字符互转 |
| csvJSON | CSV ↔ JSON | RFC4180 解析；JSON 表格化导出 CSV |

### 开发工具（新增）
| id | 工具 | 说明 |
|---|---|---|
| diff | 文本对比 | 行级 LCS diff，+/- 统计 |
| xml | XML | 格式化 / 压缩 / 校验 |
| sql | SQL 美化 | 关键字大写 + 子句换行 + AND/OR 缩进 |
| urlParse | URL 解析 | scheme/host/port/path/query/fragment |
| cidr | IP / CIDR | 网络/广播/掩码/主机范围/私网判断 |
| httpStatus | HTTP 状态码 | 常见状态码查询 |
| mime | MIME 类型 | 扩展名 ↔ MIME |
| userAgent | User-Agent | 浏览器/系统/内核识别 |
| cron | Cron | 5 段表达式 + 接下来 5 次运行 |

### 安全与校验（新增）
| id | 工具 | 说明 |
|---|---|---|
| aes | AES 加解密 | AES-GCM + PBKDF2-SHA256（6 万轮） |
| hmac | HMAC-SHA256 | 文本 + 密钥签名 |
| fileHash | 文件摘要 | 流式 MD5/SHA-1/256/512 |
| idCard | 身份证校验 | 18 位校验位/生日/性别（本机） |
| luhn | 银行卡 Luhn | 卡号校验 / 计算校验位 |

### 生成与图形（新增）
| id | 工具 | 说明 |
|---|---|---|
| random | 随机生成 | 随机字符串/整数（可去重） |
| imageConvert | 图片转换 | PNG/JPEG/HEIC/TIFF + 长边缩放 |

## 第三批（58 项，2026-10-31）
### 编码转换（新增）
| id | 工具 | 说明 |
|---|---|---|
| roman | 罗马数字 | 罗马数字 ↔ 阿拉伯数字（1–3999，双向校验） |
| excelColumn | Excel 列号 | 列字母 ↔ 序号（A=1，ZZ=702） |
| base58 | Base58 | Bitcoin 字母表编解码 |
| width | 全角/半角 | ASCII ↔ 全角字符互转 |

### 开发工具（新增）
| id | 工具 | 说明 |
|---|---|---|
| regexReplace | 正则替换 | 模式 + 模板（$1/$2 捕获组），实时预览 |
| markdown | Markdown → HTML | 标题/列表/粗斜体/代码/链接 |
| ascii | ASCII 码表 | 码位 ↔ 字符 ↔ 控制符名称 |
| httpHeaders | HTTP 头速查 | 常见请求/响应头说明 |
| crc32 | CRC-32 | 文本 CRC-32 校验 |
| sha3 | SHA-3 | SHA3-256 / SHA3-512 哈希 |

### 安全与校验（新增）
| id | 工具 | 说明 |
|---|---|---|
| idCard | 身份证校验 | 18 位校验位/生日/性别（本机） |
| luhn | 银行卡 Luhn | 卡号校验 / 计算校验位 |

### 计算器（新增）
| id | 工具 | 说明 |
|---|---|---|
| discount | 折扣计算 | 原价 × 折扣百分比 → 折后价 |
| billSplit | AA 分账 | 总额 + 人数 + 小费 → 每人应付 |

### 生成与图形（新增）
| id | 工具 | 说明 |
|---|---|---|
| barcode | 条码 | Code128-B 条码图片 |
| lorem | 占位文本 | 中/英段落生成 |
| random | 随机生成 | 字符串/整数（可去重） |
| fileInfo | 文件信息 | 大小/类型/日期/图片尺寸+EXIF |

### 媒体（v0.8.27 媒体批）
| id | 工具 | 说明 |
|---|---|---|
| videoEditor | 视频剪辑 | 入/出点剪切（快速流复制/精确重编码）+ 多段拼接；AVFoundation 主引擎，异形容器（mkv/webm…）自动回退 ffmpeg |
| audioEditor | 音频剪辑 | 剪切 / 拼接 / 从视频提取音轨（统一 m4a·AAC） |

媒体批附带：

- **新增 `media` 分类**：图片格式转换（imageConvert）从"生成与图形"移入。
- **媒体播放器新增「剪辑」入口**（剪刀按钮）：当前文件直接递进对应剪辑工具
  （ToolboxHandoff 进程内交接 + `desire://tools/videoEditor|audioEditor` 深链）。
- **引擎约定**（MediaEditStore）：任务立即登记、后台执行、进度可观察、可取消；
  AVFoundation 用 `states(updateInterval:)` 进度流（`progress` 属性 macOS 27 已废弃），
  ffmpeg 解析 `-progress pipe:1`；同壳同编码同尺寸的拼接自动走 concat demuxer 流复制（秒级）。
- **深链匹配修复**：`desire://tools/<param>` 的 param 会被小写化，驼峰 rawValue
  （excelColumn/videoEditor）此前匹配不上——现按大小写不敏感匹配。
- **图片编辑器增强**：滤镜预设（鲜艳/黑白/铬黄/褪色/拍立得/炭黑/冲印/单色/复古，
  CIPhotoEffect 家族 + CIVibrance）+ 曝光/色温滑杆；点击即烙印、⌘Z 可撤销。

## 文档批（66 项，v0.8.33）
### 文档（新增分类）
| id | 工具 | 说明 |
|---|---|---|
| pdfMerge | PDF 合并 | 多选 PDF、拖拽排序；加密文件填一次密码；尽量保留书签大纲 |
| pdfSplit | PDF 拆分 | 页码范围 `1-3,5,8-`（1 基、逆序纠正、上界钳制）或每页一个文件 |
| pdfRotate | PDF 旋转 | 按页/全部 90°/180°/270°，另存为新文件并带首页预览 |
| pdfToImages | PDF 转图片 | 72/144/300 DPI → PNG/JPEG，按页码范围批量落盘 |
| imagesToPDF | 图片转 PDF | 多图排序；A4 适配（可设页边距）或按图片 DPI 原始尺寸 |
| imageOCR | 文字识别 | 图片/PDF/剪贴板 → 文本；端上 Vision（zh-Hans + en-US，精确档），PDF 分页渲染后逐页识别 |

### 媒体（新增）
| id | 工具 | 说明 |
|---|---|---|
| subtitle | 字幕转换 | SRT ↔ VTT ↔ ASS 互转、整体时间偏移（ms）、双语字幕合并 |

实现约定：

- **PDFKit 管页面结构，CoreGraphics 管渲染**（`PDFToolEngine` / `PDFRasterizer`）：
  合并/拆分/旋转保留矢量内容与页面属性；导图走 `CGPDFDocument`（可后台、不共享页面对象）。
  所有操作在 `Task.detached` 里跑，UI 只收进度回调。
- **不覆盖同名文件**：输出自动追加 ` 2`、` 3`…；加密 PDF 未给密码时明确报错，不静默跳过。
- **页码范围语义**：`N-M` 闭区间、`N-` 到末页、`-M` 从第 1 页；显式逆序自动纠正；
  显式上界越界钳制到末页，起点越界/空组判为非法（避免"以为拆了 8 页其实只拆了 6 页"）。
- **纯逻辑**：`PDFToolCore`（页码/命名/DPI 像素/适配矩形）与 `SubtitleCore` 编码器
  （SRT/VTT/ASS、时间平移、双语合并）都进 `tests/run.sh`。
- **OCR 与截图 OCR 同源**：复用 `VisionOCRService` 的中英识别配置；PDF 逐页渲染
  （默认 200 DPI）后识别，无文字的页不算失败。

## 开发批（73 项，v0.8.33）
| id | 工具 | 说明 |
|---|---|---|
| base32 | Base32 | RFC 4648 编解码；忽略空白/连字符/大小写，TOTP 密钥可直接粘贴 |
| totp | TOTP | Base32 密钥 + HMAC-SHA1/256/512，30/60 秒、6/8 位；密钥只在内存，不落盘不日志 |
| jsonPath | JSONPath | `$.a.b[0]`、`[*]`、`.*`、`..key`、`$['a.b']`；结果单条输出原值、多条输出数组 |
| structuredData | 结构化数据 | JSON → plist（XML/binary）、plist → JSON、YAML → JSON 常见子集 |
| chmod | 权限 | 八进制 ↔ rwx 勾选 ↔ 符号式；含 setuid/setgid/sticky |
| floatBits | IEEE 754 | float32/64 ↔ 十进制/十六进制、大小端、符号/指数/尾数 |
| ulid | ULID | 48 位毫秒 + 80 位随机，Crockford Base32 26 字符，同毫秒单调递增 |

实现约定：

- **TOTP 测试向量**：RFC 6238 的 SHA1/SHA256/SHA512 三条 8 位向量进 harness；
  `secondsRemaining` 用整秒取模（窗口边界返回整窗）。
- **YAML 只做常见子集**：块映射/序列、引号字符串、数字/布尔/null、行内数组；
  锚点、别名、标签、块标量、行内对象一律报行号错误——不做"猜"。
- **plist 的 JSON 不可表示类型**：Date → ISO8601 字符串、Data → base64；
  JSON 的 null 无法存进 plist，明确报错。
- **ULID 单调性**：同一毫秒内 80 位随机数递增（溢出回退为全零，实际不可达）；
  字典序即时间序。
- **纯逻辑**：Base32Core / TOTPCore / JSONPathCore / StructuredDataCore /
  ChmodCore / FloatBitsCore / ULIDCore 全部进 `tests/run.sh`。
