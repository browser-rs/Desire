# v0.8.35 规划稿（2026-11-01，已发布）—— 读有所得：笔记本、朗读与网页成书

> 0.8.34 给了阅读器一副身体（书架、EPUB/TXT/CBZ、分页翻页、搜索书签、划词收录），
> 本版补上**记忆**和**来路**：高亮与笔记留在书上、能带走；整章能听、选词能译；
> 任意网页能变成书架里的一本离线书。旗舰 = **书内笔记闭环** + **网页存成书**，
> 其余三主题围绕阅读日常展开。

## 一、现状核实（规划前，2026-11-01）

- **0.8.34 计划内未交付项**：笔记侧栏、Markdown 导出、Markdown/HTML 原生导入、
  按书排版覆盖（`EbookReaderView` 只有划词条：高亮/笔记/复制/朗读/问 Agent；
  `grep -n "export|notes" Features/Ebooks` 无实现）。
- **高亮不落在书里**：只写 `ExcerptStore`；`Ebook`/`EbookReaderModel` 没有 highlight
  模型，正文只有搜索命中高亮（`highlightSearchIfNeeded`），重开书看不到自己划过的内容。
- **朗读只有选中段**：`ReaderSpeechService.shared.speak(selection.text)`；无整章/续读。
  服务已接 `AVSpeechSynthesizerDelegate`，可加完成/区间回调。
- **无书内翻译**：`TranslationService` 是整页 Google widget；SDK 里
  `Translation.framework` 可用（macOS 15+），能做端上文本翻译。
- **无阅读统计、无书架整理**：`EbookLibraryView` 只有搜索/导入/删除；
  `Ebook` 无 collection/favorite 字段；无改名/排序菜单。
- **网页→书架不存在**：阅读模式已有干净正文（`ReaderView.contentHTML` + `baseURL`）
  与 `saveOffline()`（只进阅读列表缓存），没有进书库的路径。
- **`.md/.html` 打不开**：`EbookFormat` 有 markdown/html 枚举，但
  `EbookImporter.importBook` 的 guard 只放行 epub/txt/cbz；本地文件路由也未接。
- **Agent 只认"最近打开的书"**：`listBooks/readBook/searchBook/getBookOutline` 四个工具
  已有，无当前书上下文、无 `openBook`。
- **可直接复用**：`EbookCore.sanitizeHTML/txtHTML`、`EbookContentLoader`、
  `EbookSearchCore`、`ReaderHighlightStore/ReaderHighlightJS`（锚点算法）、
  `ReadingListCache.saveReaderHTML`、`MarkdownHTMLCore`、`ExcerptStore`、
  `ReaderSpeechService`、`Translation.framework`。

## 二、目标

1. **笔记闭环**：高亮/笔记在正文可见、侧栏可管理、重启不丢；一键导出 Markdown。
2. **听与译**：整章/整书朗读，读完自动翻页/切章；划词端上翻译。
3. **网页成书**：阅读模式/阅读列表一键存入书架，正文与图片离线可读，重复存入去重。
4. **格式补齐**：Markdown/HTML 原生入架与打开；书库可收藏分组、改名、排序。
5. **Agent 懂当前书**：当前书/章节进上下文，能开书到指定章、读笔记、把网页存成书。

## 三、四主题覆盖

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | 阅读模式/阅读列表 → 书架；`.md/.html` 本地文件路由；`desire://books/<id>?chapter=N` 深链 |
| ② Agent 基础 | 当前书上下文；`openBook`、`listBookHighlights`、`saveWebPageToLibrary`；章节摘要存摘录 |
| ③ 融合 | 划词翻译卡；高亮/笔记同步进摘录库；问 Agent 自动带当前书与章节 |
| ④ 替人干活 | 笔记侧栏与导出、整章朗读、阅读统计、书架收藏分组/改名/排序 |

## 四、功能设计（10 件）

### 1. 书内高亮与笔记（旗舰 A）

- **现状**：划词只能"存摘录"，正文不显示；重开书看不到自己划过的内容。
- **增量**：
  - `EbookHighlight`（id / chapterIndex / quote / startOffset / endOffset / color /
    note / createdAt）+ `EbookHighlightStore`，按书存
    `ebook.highlights.<bookID>`（同现有书签的 DiskStore 模式）。
  - **锚点用章节内文本偏移**（书内容固定，分页重建不改变文本顺序），quote 作为兜底；
    选区的 WebKit 消息补 `startOffset/endOffset`。渲染走 `EbookHighlightJS`，
    每次分页重建后按 generation 重绘，与搜索高亮用不同 `data-` 属性互不干扰。
  - 交互：点正文高亮 → 笔记侧栏定位该条；侧栏按章节分组，支持改备注、换色、删除、跳转。
  - 摘录库：新增/改笔记同步 `ExcerptStore`（kind=readerHighlight）；删除高亮默认保留摘录，
    侧栏标注"已存摘录"。
- **验收**：fixture 书加 3 条高亮（含重复文本与跨段落）→ 重启后正文仍标 3 处；
  侧栏跳转落点正确；改备注后摘录同步；删除后正文标记消失。

### 2. 笔记与高亮导出 Markdown

- **现状**：无导出。
- **增量**：`EbookNotesExportCore`（Foundation-only，进 harness）按书生成 Markdown：
  书名/作者/进度 + 章节标题 + `> 原文` + 备注 + 日期；菜单"导出本书/导出全部"
  （NSSavePanel，文件名安全化），另给"复制到剪贴板"。
- **验收**：导出文件含全部高亮与备注，按章节/时间排序；无高亮时按钮禁用；
  文件名无非法字符；全部导出按书分节。

### 3. 整章朗读与自动翻页

- **现状**：只能读选中段。
- **增量**：
  - `EbookReaderModel` 取当前章纯文本（EPUB 走 `EbookContentLoader`/TXT 用章节文本），
    工具条给"朗读本章 / 暂停 / 停止"。
  - `ReaderSpeechService` 增加可选 `onFinish` 与 `onSpeakRange` 回调（阅读模式不设即无影响）；
    朗读时按 `willSpeakRange` 比例驱动 `seek(to:)` 翻页，章末自动进下一章续读（可关）。
  - 退出阅读器/停止朗读时清回调，避免影响网页阅读模式。
- **验收**：整章朗读时页码随语音推进；章末自动切章；停止后不再翻页；
  网页阅读模式朗读行为不变。

### 4. 划词翻译

- **现状**：无。
- **增量**：划词条加 Translate；用 `Translation.framework`（`translationTask` +
  `NLLanguageRecognizer` 检测源语言，目标=系统语言）端上翻译；结果卡片显示译文，
  可复制、存摘录（note 记译文）。
- **边界**：语言包未下载时由系统提示；不可用/失败给明确错误，不阻塞划词条其他动作。
- **验收**：中→英、英→中 fixture 文本出译文；语言包已装时离线可用；复制内容正确。

### 5. 网页存成书（旗舰 B）

- **现状**：阅读模式只能存阅读列表离线 HTML，不进书架。
- **增量**：
  - `EbookWebBookImporter`：输入 title / contentHTML / baseURL / sourceURL →
    容器目录（hash = sha256(sourceURL)）→ **图片本地化**（解析 `<img src>`，
    http(s) 用 URLSession 下载，带 WK cookie + Referer；单图 ≤8MB、最多 40 张，
    失败移除占位）→ 写 `index.html`（charset + 清洗）→ 注册 `.html` 书
    （chapterCount=1，封面=首图）。
  - 入口：阅读模式工具栏"存入书架"；阅读列表右键"存入书架"；
    Agent `saveWebPageToLibrary`。
  - 去重：同 URL 已在书架 → 直接打开/提示"已在书架"，不新增副本。
  - 打开：阅读器 `loadHTML` 单章，TOC = 文章标题；CSP 只允许本地/data，真离线。
- **验收**：本地文章 fixture（2 张图 + 相对链接）→ 存入书架 → 停掉 fixture 后仍能打开
  且图片显示；重复存入不新增；书目格式显示 HTML；含 `../` 路径的资源请求被拒绝。

### 6. Markdown / HTML 原生导入

- **现状**：枚举有、导入不支持。
- **增量**：
  - Markdown：`EbookCore.splitMarkdown` 按 `#/##/###` 分章；`MarkdownHTMLCore`
    补图片/引用/有序列表（工具箱同步受益）；相对图片复制到 `assets/` 并改写，
    缺图留占位；远程图片按 CSP 不加载。
  - HTML：v1 单章（`EbookCore.sanitizeHTML` 清洗），`data:` 图片保留。
  - 路由：`routeLocalFile` / `isOpenableFile` 放行 `.md/.markdown/.html/.htm/.xhtml`；
    导入面板允许这些类型；`EbookContentLoader` 支持 markdown/html（Agent 可读）。
- **验收**：md/html fixture 入架、目录正确、重启可读；Agent `readBook` 能读到这两类书；
  相对图片显示。

### 7. 书架整理

- **现状**：只有搜索/导入/删除。
- **增量**：`Ebook` 加 optional `collection`/`isFavorite`（旧数据缺键不炸）；收藏置顶；
  分组筛选（全部/收藏/未分组/自定义）；重命名标题/作者；排序（最近阅读/添加时间/
  标题/作者/进度）；保留"仅移出/连文件删除"既有二选一。
- **验收**：改名持久化；分组筛选计数正确；旧版 library JSON 正常加载。

### 8. 阅读统计

- **现状**：无。
- **增量**：`ReadingStatsStore`（DiskStore）按天记秒数与翻页数；阅读器 30s 心跳 +
  退出结算；书架顶栏显示"本周 X 分钟 / 连续 N 天"；统计面板给总时长、完成书数、
  近 14 天柱状、每本书时长 Top 10；清空需二次确认。
- **边界**：只统计阅读器打开时间（标注"阅读时长"），不跨设备。
- **验收**：模拟 3 天数据聚合正确；完成书 = 进度 ≥ 0.99；清空后归零。

### 9. Agent 读书 2.0

- **现状**：四个工具默认"最近打开的书"；无当前书上下文。
- **增量**：
  - `EbookReaderSession`（单例）记录当前书/章节/进度，阅读器 appear/disappear/切章更新；
    `AgentPromptBuilder` 增加 `currentBook` 输入（`<current_book>` 段：书名/作者/章节/进度）。
  - `openBook`：按 id/标题打开 `desire://books/<id>?chapter=N`（同时支持 N 深链）。
  - `listBookHighlights`：返回当前书（或指定书）的高亮/笔记（章节 + 原文 + 备注）。
  - `saveWebPageToLibrary`：把当前标签页/指定 URL 的阅读正文存成书（复用 #5）。
  - 阅读器"总结本章"：预填 Agent 草稿（书名 + 章节文本），结果可存为摘录
    （kind=readerHighlight，备注标记 AI 摘要）。
- **验收**：假端点抓请求体见 `<current_book>`；桥驱动 `openBook` 能开书到指定章；
  `listBookHighlights` 返回笔记；`saveWebPageToLibrary` 产物可读；工具索引自动生成。

### 10. 收口与验证

- `desire://` 启动自愈（已提交 `adc45cd`）保留为 Fixed。
- 阅读器键盘：←/→ 翻页（章末切章）、空格下一页、⌘F 搜索、⌘+/− 字号、Esc 关面板。
- 按书排版覆盖（P2）：布局/字号/主题可按书覆写（`ebook.settings.<id>`），默认跟随全局。
- i18n 三语补全；CHANGELOG 用 `scripts/changelog.py add`；WhatsNew 三亮点；
  产品页版本号与"电子书"特性行同步。
- harness 新核心全绿；E2E fixture；clean build 零警告；smoke 24/24。

## 五、批次

- **批一（记忆）**：1 + 2 —— `EbookHighlightStore`/`EbookHighlightJS`/笔记侧栏/导出。
- **批二（来路）**：5 + 6 —— `EbookWebBookImporter`、md/html 导入、本地路由、
  `EbookContentLoader` 扩展。
- **批三（用得顺）**：3 + 4 + 7 + 8 + 10 的键盘/按书覆盖。
- **批四（Agent 与收口）**：9 + 10 —— 当前书上下文、三个新工具、i18n/WhatsNew/发版。

## 六、技术地图

**新增 `Features/Ebooks/`**

- `EbookHighlight.swift`（Model）
- `EbookHighlightStore.swift`（Store，按书 DiskStore）
- `EbookHighlightJS.swift`（偏移锚点 + 点击派发；可复用 `ReaderHighlightJS` 的文本节点遍历）
- `EbookNotesPanel.swift`（侧栏）
- `EbookNotesExportCore.swift`（Foundation-only，进 harness）
- `EbookWebBookImporter.swift`（网页 → 离线 HTML 书）
- `EbookReaderSession.swift`（当前书单例）
- `ReadingStatsStore.swift`

**改造**

- `Ebook.swift`：collection/favorite optional 字段（旧数据兼容）。
- `EbookImporter.swift`：markdown/html 导入、网页书注册、hash 去重。
- `EbookReaderModel.swift`：高亮重绘、整章朗读、章节偏移、`loadHTML`、深链章节参数。
- `EbookReaderView.swift`：笔记/朗读/翻译工具条、笔记侧栏入口、键盘、统计心跳。
- `EbookLibraryView.swift`：收藏分组、改名、排序、统计入口。
- `EbookContentLoader.swift`：markdown/html/web 书 → 纯文本章节。
- `EbookAgentTools.swift` + `BrowserToolProvider+Definitions/Execution.swift`：
  `openBook` / `listBookHighlights` / `saveWebPageToLibrary`。
- `AgentPromptBuilder.swift`：`<current_book>` 层。
- `ReaderView.swift` / `ReadingListPanel.swift`："存入书架"。
- `SelectedTabContent.swift` / `BrowsingActions.swift` / `InternalPages.swift`：
  `.md/.html` 路由、`books/<id>?chapter=N`。
- `ReaderSpeechService.swift`：`onFinish` / `onSpeakRange` 回调。
- 资源：`Localizable.xcstrings` 三语、`CHANGELOG.md`、`WhatsNewSheet.swift`、`website/index.html`。

## 七、验证门

1. **harness**：偏移锚点（唯一/重复/跨段落/找不到）、Markdown 导出、`splitMarkdown`、
   HTML 清洗与资源改写、统计聚合、去重键、进度换算。
2. **E2E**：EPUB fixture 加高亮 → 重启 → 断言 store 与渲染；本地文章 fixture（含图）
   → `saveWebPageToLibrary` → 停服后离线打开；md/html fixture 导入；桥 `openBook`；
   Agent 工具四项。
3. **构建**：`xcodebuild … clean build | grep -E "warning:"` 零命中。
4. **i18n**：新键三语零 null；`smoke 24/24`。
5. **手测（用户）**：真实 EPUB 划词高亮/侧栏/导出、整章朗读、划词翻译、
   网页存书后断网打开、书架分组改名。

## 八、不做（本版明确）

- CFI 精确锚点（本版用章节偏移 + quote 兜底；跨版本内容变化时降级为"位置可能不准"）。
- 阅读进度/笔记跨设备同步（服务端新域另开版本；本版本地优先）。
- DRM 解密、CBR/RAR/FB2、固定版式 EPUB 的完整排版。
- 网页 → EPUB 导出（本版先落离线 HTML 书；EPUB 打包后续再做）。
- PDF/CBZ 批注、内置书城/书源、随包分发任何书籍。
- 朗读的逐词高亮（本版只做页码跟随）。

## 九、风险与取舍

| 风险 | 取舍 |
|---|---|
| 偏移锚点在重排后失效 | 书内容固定、分页不改文本顺序；偏移 + quote 双锚，找不到时侧栏保留并标注 |
| 高亮与搜索高亮打架 | 不同 `data-` 属性、分两次注入；搜索只在查询时临时标 |
| 网页图片防盗链/需要登录 | 带 WK cookie + Referer；失败移除占位；不因单图失败中止整本书 |
| 网页存书体积/耗时 | 图片上限 40 张 × 8MB，后台执行 + 进度；失败可重试 |
| 朗读与翻页不同步 | 按 `willSpeakRange` 比例驱动，按页边界节流；v1 不做逐词高亮 |
| 端上翻译语言包缺失 | 明确提示"系统需下载语言包"，不静默失败；失败不阻塞划词条 |
| 统计口径被当成精确值 | 页面标注"阅读器打开时长"，心跳 + 退出结算 |
| 本版两件旗舰同时铺开 | 先批一记忆闭环，再批二网页成书；任一滑档则并入下版，不硬塞发版 |

## 十、发版口径

按既有规矩：CHANGELOG 只用 `scripts/changelog.py add`；WhatsNew 三亮点
（书内笔记与导出、整章朗读/划词翻译、网页存成书）；产品页同步版本号与特性行；
用户说「发」才发版。
