# v0.8.33 规划稿（2026-11-01，待过目）—— 工具箱 2.0：从 59 到 81 + 可编程能力层

> 主题落在「替人干活」与「可发现性」。媒体主线（0.8.27→30）与自动播放专项
> （0.8.32）之后，本版回到**工具箱**：补齐最常被外部工具抢走的三类活（PDF、
> OCR、字幕），再把工具箱从"一个页面"升级为**可被 Agent / 浏览器右键 / 深链
> 调用**的能力层。

## 一、现状核实（规划前，避免重复）

- 已有 59 项：计算/时间/编码/开发/文本/生成/安全/媒体 8 类；收藏、最近使用、
  搜索、`desire://tools/<id>` 深链、拖文件进媒体工具（ToolboxHandoff）都已存在。
- **没有**的：PDF 合并/拆分/旋转/导出图片、图片与 PDF 的 OCR、字幕格式转换、
  TOTP、Base32、JSONPath、简繁/拼音、时区换算、颜色对比度、批量重命名、压缩解压。
- 已存在可复用但**未进工具箱**的能力：
  - PDFKit 工作台（`PDFWorkbenchModel`：页面旋转/删除/重排/提取、加密解锁）
  - 端上 OCR（`VisionOCRService`，中文+英文，精确档）
  - 字幕解析（`SubtitleCore`：SRT/VTT/ASS，暂无编码器）
  - 图片编辑器（v0.8.12）、媒体剪辑（v0.8.27）、图片转换（imageConvert）
- 工具箱目前**不可编程**：Agent 工具清单里没有入口，桥也没有端点；深链只能
  选工具，不能带输入。

## 二、目标

1. **数量与覆盖面**：59 → 81 项，新增「文档」分类（PDF / OCR / 文件重活）。
2. **少切应用**：PDF、OCR、字幕、批量重命名、压缩解压都在浏览器里完成。
3. **能力层**：新增 `runToolboxTool` Agent 工具 + 桥 `POST /toolbox/run`，
   纯文本类工具可被 Agent、工作流、外部脚本直接调用；工具索引从注册表生成。
4. **入口打通**：`desire://tools/<id>?text=…` 预填输入；选中文本右键「用工具
   处理」；剪贴板面板「发送到工具」；工具结果「发送到…」接力。
5. **不破坏现有承诺**：全部端上计算、无网络请求；文件类工具默认不覆盖、
   先预览后执行；OCR 仍走显式 Vision 调用（与已关闭的 Live Text 无关）。

## 三、批次

### 批次一：文档重活（7 项，PDFKit + Vision + SubtitleCore）

| id | 工具 | 说明 |
|---|---|---|
| pdfMerge | PDF 合并 | 多选 PDF，拖拽排序；加密文件逐个要密码；合并后保留书签大纲（PDFKit 尽力） |
| pdfSplit | PDF 拆分 / 提取 | 页码范围语法 `1-3,5,8-`（1 基、去重、越界钳制）；每页单独导出或合并成一份 |
| pdfRotate | PDF 旋转 | 按页/全部 90° 步进，预览缩略图后另存 |
| pdfToImages | PDF → 图片 | 选 DPI（72/144/300）与 PNG/JPEG，批量落文件夹 |
| imagesToPDF | 图片 → PDF | 多图排序，按原尺寸或 A4 适配，可设页边距 |
| imageOCR | 文字识别 | 图片/PDF/剪贴板图像 → 文本；复用 VisionOCRService（zh-Hans+en-US）；可复制/存 .txt；大图后台执行 |
| subtitle | 字幕转换 | SRT ↔ VTT ↔ ASS 互转 + 整体时间偏移（±ms）+ 合并双语；复用并扩展 SubtitleCore |

**引擎**：PDFKit（页面操作、`PDFPage(image:)`）；加密 PDF 走 `PDFDocument.unlock`；
OCR 不占主线程；字幕编码器新增 `SubtitleCore.encode(format:)`、`shift(seconds:)`。
**纯逻辑**：`PDFToolCore`（页码范围解析、输出命名、页码钳制）进 harness。

### 批次二：开发与数据（7 项）

| id | 工具 | 说明 |
|---|---|---|
| base32 | Base32 | RFC 4648 编解码（TOTP 依赖），忽略空白与大小写 |
| totp | 动态验证码 | Base32 secret + HMAC-SHA1/256/512，30s 窗口，6/8 位，倒计时；**不持久化、不日志** |
| jsonPath | JSON 查询 | 子集 `$.a.b[0]`、`[*]`、`..` 简版；结果格式化/复制；语法错误给位置 |
| structuredData | JSON ↔ plist | JSON ↔ XML/binary plist（`PropertyListSerialization`）；YAML→JSON 仅常见子集，解析失败明确报错（不做"猜"） |
| chmod | 权限计算 | rwx 勾选 ↔ 八进制（755）、符号式（u+x）互转；含 setuid/setgid/sticky |
| floatBits | IEEE 754 | float32/64 ↔ 十进制/十六进制，大小端切换；NaN/Inf 显示 |
| ulid | ULID | 时间序 + 随机，同毫秒单调；与现有 UUID v7 并列（UUID 工具不动） |

**纯逻辑**：`Base32Core`、`TOTPCore`（RFC 6238 测试向量）、`JSONPathCore`、
`StructuredDataCore`、`ChmodCore`、`FloatBitsCore`、`ULIDCore` —— 全部 Foundation-only
进 harness。

### 批次三：中文、时间与设计（6 项）

| id | 工具 | 说明 |
|---|---|---|
| timezone | 世界时钟 | 源/目标时区 + 时间 → 换算；显示 DST 与 UTC 偏移；"现在"一键 |
| zhConvert | 简繁转换 | 简→繁 / 繁→简（ICU `Simplified-Traditional`）；标注一简对多繁的已知限制 |
| pinyin | 拼音 | 带声调 / 不带声调 / 首字母三档；`mandarinToLatin` + `stripDiacritics` |
| zhTypography | 中文排版 | 中英文间加空格、全角标点归一、去行尾空白、合并空行；实时预览 |
| contrast | 对比度 | 前景/背景 → WCAG 比值与 AA/AAA 评级；含互补/类似色板 |
| qrDecode | 二维码识别 | 图片/剪贴板 → QR/Code128/EAN（Vision `VNDetectBarcodesRequest`）；链接可直接打开；与 QR 生成工具互链 |

**纯逻辑**：`ZhTextCore`（转换/排版/拼音）、`ContrastCore`（相对亮度与比值）进 harness。

### 批次四：文件重活 + 工具箱 2.0（2 工具 + 4 整合）

**工具**

| id | 工具 | 说明 |
|---|---|---|
| batchRename | 批量重命名 | 规则：查找替换（含正则捕获）、前缀/后缀、序号（补零）、日期、扩展名；**先预览表格 + 冲突检测（APFS 大小写不敏感）+ 两阶段改名**；默认不覆盖，执行前确认 |
| archive | 压缩 / 解压 | 建 zip / tar.gz（ditto/tar）；解压前列清单，**zip-slip 路径穿越防护**，只允许落到所选目录 |

**整合（工具箱 2.0）**

1. **`runToolboxTool` Agent 工具 + 桥 `POST /toolbox/run`**：注册表把纯文本类
   工具暴露为 `{tool, args}` → 文本/JSON 结果（base64/url/hash/hmac/json/csv/
   regex/timestamp/units/color/jwt/cron/uuid/random/password/morse/roman/
   excelColumn/dataURI/width/crc32/sha3/base58/markdown/lorem/chmod/base32/totp/
   floatBits/ulid/jsonPath/zhConvert/pinyin/zhTypography/contrast/text）。
   工具定义从注册表生成（沿用 `promptInventory`，不手写清单）。
2. **深链载荷**：`desire://tools/base64?text=…`（URL 编码）→ `ToolboxHandoff`
   带文本，目标工具预填；`desire://tools/pdfSplit?file=/…` 可选（仅本地路径，
   显式用户动作才用）。
3. **右键 / 剪贴板入口**：选中文本右键「用工具处理 →」子菜单（Base64/URL/
   JSON/简繁/拼音/哈希/字数/摩斯）；剪贴板面板每条加「发送到工具」。
4. **结果接力 + ⌘K 快切**：每个工具输出区加「发送到…」菜单（文本 handoff 到
   另一工具）；工具箱内 ⌘K 打开快切浮层（搜索 + ↑↓ + 回车，收藏/最近优先）。

## 四、分类调整

- 新增 `document`「文档」：pdfMerge / pdfSplit / pdfRotate / pdfToImages /
  imagesToPDF / imageOCR / batchRename / archive。
- `fileInfo` 从「安全」移到「文档」（语义归位；收藏/最近使用记录不受影响）。
- `subtitle` 进「媒体」；base32/totp/jsonPath/structuredData/chmod/floatBits/ulid
  进「开发」；timezone 进「时间」；zhConvert/pinyin/zhTypography 进「文本」；
  contrast/qrDecode 进「生成与图形」。

## 五、文件与实现地图

- 新增 Core（进 tests/run.sh）：`PDFToolCore`、`Base32Core`、`TOTPCore`、
  `JSONPathCore`、`StructuredDataCore`、`ChmodCore`、`FloatBitsCore`、`ULIDCore`、
  `ZhTextCore`、`ContrastCore`、`BatchRenameCore`、`ArchiveCore`、
  `ToolboxRuntimeCore`。
- 新增 View（按类分文件，避免 ToolsExtraViews 继续膨胀）：
  `ToolsDocumentViews.swift`、`ToolsDataViews.swift`、`ToolsTextZhViews.swift`、
  `ToolsFileViews.swift`、`ToolsDesignViews.swift`。
- 扩展：`SubtitleCore`（编码/偏移，加入 harness）、`ToolboxCatalog`（新 case +
  分类 + 搜索关键词）、`ToolboxHandoff`（文本载荷）、`ToolsPageView`（载荷接线）、
  `ToolboxQuickSwitcher.swift`（⌘K）、`AutomationServer`（`/toolbox/catalog`、
  `/toolbox/run`）、`BrowserToolProvider`（`runToolboxTool`）、
  `PageContextMenu` + `context-menu.js`（选中文本子菜单）、剪贴板面板（发送）。

## 六、验证门

1. **harness**：新增 Core 全绿，重点断言——
   - PDF 页码范围（`1-3,5,8-`、越界、重复、逆序）
   - 字幕编码往返 + 偏移；RFC 6238 TOTP 三算法向量；RFC 4648 Base32 向量
   - JSONPath 命中/未命中；chmod 符号 ↔ 八进制；FloatBits 往返；ULID 单调
   - 简繁/拼音/中英间距；对比度黑白 = 21:1
   - 批量重命名冲突检测（大小写不敏感、两阶段改名顺序）
   - 解压路径穿越拒绝；`ToolboxRuntimeCore` 每个工具至少一条用例
2. **构建**：clean build + `grep -E "warning:"` 为零（本机与 CI 同版本）。
3. **i18n**：新工具标题/副标题/报错三语齐全，全目录扫 null。
4. **桥 E2E**：`POST /open-url desire://tools/<id>` 选中正确工具；
   `desire://tools/base64?text=…` 预填；`POST /toolbox/run` 对 10+ 工具抽样；
   `GET /toolbox/catalog` 计数 = 81。
5. **文件 fixture**（/tmp，测完清理）：PDF 合并/拆分页数核对；OCR 用现造图片；
   批量重命名两阶段 + 回滚；zip 解压 `../` 拒绝。
6. **手测**（用户）：拖入 PDF 全流程、OCR 中文、字幕转换、批量重命名预览。

## 七、不做（本版明确）

- **网络类工具**（DNS/HTTP 请求/汇率/在线查重）：工具箱定位端上、无网络；
  需要网络的走 Agent 的 `runCommand` 或浏览器本身。
- **个税/社保计算器**：政策参数易过期，等有明确口径再做。
- **视频转码/视频→GIF**：媒体批已有剪辑与导出，转码属下一版；本版只做字幕。
- **完整 YAML/TOML 支持**：不做半吊子解析器；本版只做 plist + YAML 常见子集。
- **TOTP 密钥持久化/二维码扫描入密钥**：本版只做手动输入 + 本地计算，
  不落盘、不进日志。
- **独立窗口/菜单栏常驻工具**：工具箱仍是标签内页。

## 八、风险与默认取舍

| 风险 | 取舍 |
|---|---|
| 批量重命名误操作 | 预览 + 冲突检测 + 两阶段改名 + 执行前确认；不自动覆盖 |
| 解压路径穿越 | 逐条校验规范化路径必须在目标目录内；拒绝绝对路径与 `..` |
| 加密 PDF | 逐个提示密码；取消则跳过并汇总，不静默失败 |
| OCR 大图/长 PDF | 后台执行 + 进度（分页），可取消 |
| 简繁一简对多繁 | 结果页注明"字符级转换，专名请人工核对" |
| YAML 子集 | 只接受常见块结构；解析失败报行号并建议改用 JSON/plist |
| 工具数量膨胀（81） | 首页按分类折叠 + ⌘K 快切；搜索关键词补中文别名 |

## 九、发版口径

按既有规矩：CHANGELOG 只用 `scripts/changelog.py add`；WhatsNew 刷三亮点
（PDF/OCR 进浏览器、工具箱可被 Agent 调用、批量重命名）；产品页工具计数与
分类同步；用户说「发」才发版。
