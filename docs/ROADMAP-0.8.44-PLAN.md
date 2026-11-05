# v0.8.44 规划稿（2026-11-05）—— PDF 上书架：阅读生态收官 + Agent 成本自觉

> v0.8.34–43 把阅读做成了生态（书架/进度/书签/同步/摘录/朗读/翻译/搜索），但
> **PDF 一直不是书架公民**——只有标签页内的临时查看器和页面工作台。本版把 PDF
> 接进整套阅读体验，阅读格式至此收官；同时补上 Agent 架构盘点明确剩下的
> **旁路调用记账**（标题/记忆/自评等旁路回合不计入统计的已知缺口）与
> 0.8.38 留下的 **C7 admin CLI 扩展 + A3 评估集扩充**，外加遗留可靠性项
> **崩溃后首启无窗**。

## 一、现状核实

- **书架格式**：EPUB/TXT/CBZ/MOBI/AZW3/FB2/HTML/MD（`EbookImporter` 不收 .pdf）。
- **PDF 现状**：标签页内 PDFKit 查看器（含双页，v0.8.17）+ `PDFWorkbenchModel`
  页面工作台 + Agent PDF 工具（`PDFPageSpec` 等）+ 摘录库已含 `pdfAnnotation`
  来源（第十三同步域）。缺：进度/书签/目录/朗读/翻译/搜索与统计全部挂在
  临时查看器上，关标签即忘。
- **Agent 旁路调用**：划词卡/心跳/标题/记忆整理/自评 critic 走 `bypassPreferences`
  （旁路档案），**用量从不记账**（`UsageStats` 缺口，架构盘点 2026-09-23 起
  挂账）；旁路档案没配置时静默回落主档案，用户不知道贵调用烧在主模型上。
- **0.8.38 明确留下**：C7（admin CLI device/remote/quota 子命令）、
  A3（评估集 +4~6 fixtures）。
- **可靠性遗留**：强杀（pkill -9）后首启可能没有主窗（session-index 采纳
  断链，AGENTS.md v0.7.26 可靠性条目，自动化探针已在受此困扰）。

## 二、目标

1. PDF 成为书架一等公民：进度/书签/目录/继续阅读/统计与 EPUB 同待遇。
2. 阅读三大件（逐段朗读/翻译对照/书内搜索）接上 PDF 文本层。
3. Agent 旁路调用记账 + 成本感知引导（配了旁路档案自动用、没配了告诉你）。
4. 服务端运维补全（C7）+ 评估集扩充（A3）+ 崩溃首启无窗修复（可靠性）。

## 三、四主题

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | PDF 书籍化阅读（书架/进度/书签/目录/双页）+ 文本层三大件 |
| ② Agent 基础 | 旁路调用记账 + 成本感知引导；A3 评估集扩充 |
| ③ 融合 | PDF 批注/书签/进度进同步（ebooks 域 payload 扩展 format=pdf）；阅读统计计入 PDF |
| ④ 替人干活 | PDF 批量处理进 Jobs（workbench 能力批量封装：合并/拆分/提取） |

**贯穿**：可靠性 = 崩溃后首启无窗修复；可发现性 = 书架格式徽标/空态更新 +
服务端 C7 运维面。

## 四、Track A：PDF 上书架

### A1. 导入与书架

- `EbookImporter` 接受 `.pdf`：文件名 → 书名、PDFKit 取首页缩略做封面、
  `PDFDocument.pageCount` → 章节数（页）。
- 书架卡片沿用（格式徽标 PDF）；"继续阅读"大卡、最近笔记直接生效。
- 网页 → PDF 存书架（savePage 的 PDF 产物一键入架，复用现有 createPDF 路径）。

### A2. 阅读器

- `EbookReaderView` 新 PDF 后端：PDFKit 分页视图（单/双页沿用既有布局），
  进度 = 页码/总页数（`chapterProgress` 语义映射页码比例），滚动/翻页两模式。
- 目录 = PDF outline（无 outline 退化页码跳转）；书签 = 页码 + 视口比例。
- 阅读统计（时长/页数/连续天数）照常计入。

### A3. 文本层三大件

- 文本提取管线：`PDFPage.string` 按页提取 → 段落切分（空行/缩进启发），
  **带页码锚点**（段落 → 页索引），缓存随书 hash。
- 逐段朗读：段落队列跨页推进 + 页面跟随（复用 `ReaderSpeechService` 逐段机制
  的经验：段落索引 ↔ 页面锚点一一对应）。
- 翻译对照：PDF 文本层同样走 Translation.framework 批翻；显示为页内覆盖层
  （PDFKit 无 DOM，用 annotation/overlay 视图，按页渲染，缓存同页译）。
- 书内搜索：`PDFDocument` 原生 `findString` + 命中列表（页码 + 片段高亮），
  跳转精确到命中序号（对齐 v0.8.43 搜索升级语义）。

### A4. 批注与同步

- 划选 → 高亮/摘录（PDFKit annotation 落盘在书文件旁 `.annotations.pdf`，
  兼容外部阅读器）；摘录库 `pdfAnnotation` 来源打通书架路径。
- 同步：书签/进度复用 **ebooks 域** payload 扩展（`format: "pdf"`，老客户端
  忽略未知格式不崩）；批注走既有 excerpts 域（已支持）。

## 五、Track B：Agent 成本自觉

### B1. 旁路调用记账

- 旁路回合（标题/记忆整理/自评 critic/crew 已单独记账——补齐其余）统一写
  `UsageStats`：消息带 `bypassKind`（title/memory/critic/assist…），
  统计页新增"旁路调用"分模型小节。
- 口径沿用既有规矩：没定价只显示 token 不显示 $0；`AgentUsage.of` 单一入口。

### B2. 成本感知引导

- 旁路档案已配置 → 一切旁路调用强制走旁路档案（现状已是这样，核实收口）。
- **没配置** → 旁路调用回落主档案（现状），但：统计页与设置页各出一条
  "旁路调用正烧主模型"提示 + 一键去配（跳转服务编辑器新建便宜档案）。

### B3. A3 评估集扩充

- agent-eval 新增 4 条 fixtures：几何工具失败回执、逐段朗读状态、
  旁路记账断言、后台任务模板运行。

## 六、Track C：替人干活与服务端

### C1. PDF 批量进 Jobs

- workbench 单件能力（合并/拆分/页提取/旋转）封装成批量任务：输入文件夹
  → 任务参数 → JobStore 台账（进度/失败重试/产物目录），Agent 工具
  `batchProcessPDFs` 驱动。
- 工具箱 PDF 工具与 workbench 打通（同一引擎，入口不同）。

### C2. C7 admin CLI 扩展（服务端批次，需部署）

- `device list|revoke <username>`、`remote inbox <username> [--purge]`、
  `quota show|set <username>`（配额表已有则只读展示，没有则本版不加表）。
- `tools/api-remote-smoke.py` 补对应冒烟；**不改已应用迁移**。

### C3. 崩溃后首启无窗（可靠性）

- 症状：强杀后 session-index 是上次干净退出的、或采纳失败 → tabs=0 无主窗。
- 修法方向：启动采纳失败兜底强制开新窗（现有"一次性异常"路径收口）+
  `close:` 归档键校验；自动化探针 `--automation` 首启 tabs≥1 判据回归。
- 顺带：强杀前最后 30s 内有会话写盘的，index 采纳放宽到"任一无文件即
  取最近有文件的"（对齐既有"跳过无文件"语义的反向兜底）。

## 七、批次

- **批 1**：A1 导入/书架 + A2 阅读器（PDFKit 后端 + 进度/书签/目录 + 统计）。
- **批 2**：A3 文本层三大件 + A4 批注与同步。
- **批 3**：B1 记账 + B2 引导 + B3 评估集 + C3 崩溃首启修复。
- **批 4**：C1 批量 PDF + C2 服务端批次 + 文档/CHANGELOG/WhatsNew 收尾。
- 全程 harness 纯逻辑测试同步（PDF 文本切分/页锚点/进度映射进 harness）；
  每批 Debug/Release 零警告。

## 八、不做

- PDF 内容编辑（改文字/重排）、OCR 全文索引（工具箱已有单页 OCR）、
  DRM、PDF 表单填写、扫描件版面分析。
- 旁路调用独立计费报表（只记账+引导，不建新账本）。
- C7 的 web 管理界面（CLI 先行）。

## 九、发版口径

- 用户说「发」才发；CHANGELOG 只用 `scripts/changelog.py add`。
- 发版前：harness + Debug/Release clean 零警告；C2 若赶上发版窗口需先部署
  服务端（迁移纪律：只加新 NNNN）。
