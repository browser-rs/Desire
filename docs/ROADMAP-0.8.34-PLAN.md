# v0.8.34 规划稿（2026-11-01，待过目）—— 电子书：书架 + EPUB 阅读器 + 阅读生态

> 用户点名下一版做电子书。按四主题骨架落：①浏览器基础＝本地文件打开/下载/书架入口；
> ②Agent 基础＝读书工具与当前书上下文；③融合＝划词问 Agent/翻译/朗读/摘录；
> ④替人干活＝书架、阅读器、格式转换与笔记导出。电子书本身是旗舰，其余三主题围绕它长。

## 一、现状核实（规划前）

- **无电子书代码**：`grep --include=*.swift "EPUB|epub|电子书|ebook|mobi|azw3|cbz"` 只命中
  `MediaURLDetector` 的下载扩展名列表；没有容器/OPF/阅读器实现。
- **有可复用底座**：
  - `DocumentViewerView`（v0.8.12）：textutil → HTML → WKWebView，含大纲/⌘F/打印/导出 PDF/
    「问 Agent」/加入阅读列表——电子书阅读器的直接模板。
  - `PDFWorkbenchModel`/`PDFViewerView`：本地文件查看器的状态与返回栈模式。
  - `ArchiveCore`：zip 安全解包（绝对路径/`..`/反斜杠/冒号校验）——EPUB 解包直接复用。
  - `ExcerptStore`、`ReaderSpeechService`、`TranslationService`、`AgentDraftInbox`：
    划词摘录/TTS/翻译/问 Agent 的链路都已存在。
  - `UTType.epub` 系统已声明；CBZ/MOBI 是动态类型。
- **本地文件路由白名单**（`SelectedTabContent.isOpenableFile` + `BrowsingActions.routeLocalFile`）
  目前只到 pdf/docx/zip/媒体等，**没有 epub**。
- **Calibre 未内置**：MOBI/AZW3 只能走可选外部 `ebook-convert`（同 ffmpeg 的探测模式），
  不随包分发；DRM 文件不做。

## 二、目标

1. **书架**：导入 EPUB/TXT/Markdown/HTML/CBZ，封面网格、搜索、排序、继续阅读、删除。
2. **阅读器**：EPUB 2/3 回流式排版；目录、章节前后、进度、字号/字体/行距/页边距、纸色/夜间、
   滚动/分页双模式、书签、上次位置恢复。
3. **阅读生态**：书内搜索、划词高亮/笔记、摘录库、导出 Markdown、朗读/翻译/问 Agent。
4. **Agent 能读**：`listBooks` / `readBook` / `searchBook` / `getBookOutline`，可总结本章、
   按书问答；当前阅读位置作为上下文。
5. **格式边界**：原生 EPUB/TXT/MD/HTML/CBZ；MOBI/AZW3 仅在装了 Calibre 时可转 EPUB；DRM 不支持。

## 三、四主题覆盖

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | 地址栏/拖拽/下载完成 → 打开电子书；`desire://books` 书架；文件关联 `.epub/.cbz/.txt/.md`；菜单入口 |
| ② Agent 基础 | 书库/读书/搜书/目录四个工具；当前书与章节上下文；章节总结预填 Agent |
| ③ 融合 | 划词条：高亮/笔记/复制/翻译/朗读/问 Agent；高亮进摘录库；章节朗读 |
| ④ 替人干活 | 书架、EPUB 阅读器、书内搜索、笔记导出、格式转换（Calibre 可选） |

## 四、功能设计

### 1. 书架（Library）
- 网格卡片：封面、标题、作者、进度条、最近阅读角标；空状态引导导入。
- 搜索（标题/作者/文件名）、排序（最近阅读/添加时间/标题/作者）、继续阅读区。
- 导入：按钮 / 拖入窗口 / 打开本地文件；一次多选。
- 删除：仅移出书架 or 同时删库内副本（二次确认）；显示占用空间。
- 元数据：标题、作者、语言、出版社、标识符、封面；缺封面用首图/生成色块占位。

### 2. EPUB 引擎（纯逻辑 + 导入）
- `container.xml` → rootfile OPF；OPF 的 metadata / manifest / spine / guide / cover。
- 目录：EPUB3 `nav.xhtml` 优先，EPUB2 `toc.ncx` 回退；嵌套层级、href → spine 映射。
- href 归一：相对 OPF 目录解析、百分号解码、`..` 越界拒绝。
- 导入：SHA-256 去重 → 复制到 `Application Support/Desire/Ebooks/<hash>/` →
  `unzip`/ditto 解包（`ArchiveCore.safeEntryPath` 逐条校验）→ 解析元数据/封面 → 落书架 JSON。
- 固定版式（`rendition:layout=pre-paginated`）：检出后降级为"整页图片/滚动 + 提示"，
  不伪装成回流式。
- DRM/加密（`encryption.xml` 含内容加密）：明确报"受 DRM 保护，无法打开"。

### 3. 阅读器（Reader）
- 顶部栏：返回、书名/章节、目录、搜索、字体/主题、书签、朗读、问 Agent、更多。
- 正文：单章 HTML 写入库内临时文件，`loadFileURL(allowingReadAccessTo: bookRoot)`，
  保留图片/本地 CSS；**安全清洗**：移除 `<script>/<iframe>/<object>/<embed>`、行内 `on*`、
  `javascript:` URL；注入 CSP 阻断 http(s) 远程资源（书应离线可读，防跟踪）。
- 目录侧栏：嵌套章节；当前章节高亮；点击跳转。
- 进度：spine 序号 + 章内比例（滚动）或页序号（分页）；底部滑杆可拖动。
- 排版：字号 12–32、字体（系统/衬线/无衬线）、行距 1.2–2.0、页边距、两端对齐开关；
  主题：纸白/米黄/深灰/纯黑。设置全局记忆，可按书覆写。
- 模式：滚动 / 分页（CSS 多列 + 水平位移；页数由 `scrollWidth/clientWidth` 算）。
- 键盘：←/→ 翻章或翻页、空格下一页、⌘F 书内搜索、⌘+/- 字号、Esc 关目录。
- 位置恢复：退出/切章/重启后回到上次章节与比例；每本书独立。

### 4. 书内搜索与标注
- 搜索：逐章剥离标签建索引（纯逻辑），返回章节 + 前后 60 字片段；点击跳章并高亮首个命中。
- 书签：spine + 比例 + 片段；书签列表可跳转/删除。
- 高亮/笔记：划词浮条（高亮/笔记/复制/翻译/朗读/问 Agent）；高亮存 spine + 文本 +
  近似偏移；笔记侧栏；导出 Markdown（书名/作者/章节/原文/笔记）。
- 摘录库：高亮写入 `ExcerptStore`（source=书名+作者，kind=highlight），与现有摘录/白板回链打通。

### 5. 格式
| 格式 | 策略 |
|---|---|
| EPUB 2/3 | 原生（本版核心） |
| TXT | 原生：编码嗅探（UTF-8/UTF-16/GB18030 兜底），按字节上限分章 |
| Markdown | 原生：复用 MarkdownHTMLCore 渲染，按标题分章 |
| HTML | 原生：清洗后渲染 |
| CBZ | 原生：解包图片，整页翻页/适宽/适高；CBR 不做（无 unrar） |
| MOBI/AZW3 | 可选：检测 `/opt/homebrew/bin/ebook-convert` 等，转 EPUB 后入架；否则提示安装 Calibre |
| PDF | 已有 PDF 工作台，书架可"链接打开"，不重复实现 |
| DRM | 不支持，明确报错，不做破解 |

### 6. Agent 与融合
- 工具：
  - `listBooks`：书架列表（标题/作者/进度/最近阅读）。
  - `readBook`：按 spine 范围取章节纯文本（带 `[chN]` 引用），默认当前书/当前章。
  - `searchBook`：书内搜索（章节 + 片段）。
  - `getBookOutline`：目录树。
  - `openBook`：按 id/标题打开阅读器（可选）。
- 当前书上下文进系统备注（书名/作者/章节/进度），"总结本章""这本书讲了什么"直接可用。
- 划词条复用 `AgentDraftInbox` 预填；翻译走 `TranslationService`；朗读走 `ReaderSpeechService`。
- 章节总结/笔记可一键存回书签/摘录。

## 五、批次

### 批次一：书架 + EPUB 阅读器（旗舰，7 项）
1. `EbookCore`：container/OPF/NCX/nav 解析、href 归一、元数据/封面、清洗 HTML。
2. `EbookLibraryStore`：导入/去重/解包/封面/书架持久化。
3. `EbookReaderModel`：spine/章节加载、CSS 注入、进度、位置恢复。
4. `EbookReaderView`：顶部栏/正文 WebView/目录/前后章/进度/主题。
5. `EbookLibraryView`：网格/搜索/排序/导入/继续阅读/删除。
6. 路由与入口：`.epub` 本地文件、`desire://books`、下载打开、菜单/新标签入口。
7. 书架空状态/导入错误/DRM 提示。

### 批次二：阅读体验（6 项）
8. 滚动/分页双模式（CSS 多列 + 水平位移 + 页数）。
9. 排版设置：字号/字体/行距/页边距/对齐 + 四主题；按书覆写。
10. 目录嵌套与当前章节高亮；进度滑杆。
11. 书内搜索：索引/片段/跳转高亮。
12. 书签 + 上次位置；每本书独立进度。
13. 键盘/触控板手势。

### 批次三：标注与格式（6 项）
14. 划词浮条：高亮/笔记/复制。
15. 高亮进 ExcerptStore、笔记侧栏、Markdown 导出。
16. TXT/Markdown/HTML 阅读（编码嗅探、按标题/大小分章）。
17. CBZ 漫画阅读（解包图片、翻页、适宽/适高）。
18. MOBI/AZW3 → Calibre `ebook-convert` 可选导入；DRM 拒绝。
19. 书架管理：删除副本/空间统计/重扫元数据。

### 批次四：Agent 融合与收口（5 项）
20. Agent 工具 `listBooks/readBook/searchBook/getBookOutline`（+可选 openBook）。
21. 当前书上下文进提示词；「总结本章」预填 Agent。
22. 划词翻译/朗读/问 Agent 接线。
23. 书内搜索/引用 `[chN]` 与 Agent 结果互链。
24. E2E fixture、文档、i18n、发版收口。

## 六、技术地图

新增 `Features/Ebooks/`：
- `EbookCore.swift`（纯 Foundation，进 harness）：容器/OPF/NCX/nav 解析、href 归一、
  HTML 清洗、搜索片段、进度换算。
- `Ebook.swift`（Model，Codable）：书、章节、书签、高亮、阅读设置。
- `EbookLibraryStore.swift`：导入/去重/解包/封面/CRUD/持久化。
- `EbookImporter.swift`：EPUB/CBZ 解包、Calibre 转换、编码嗅探。
- `EbookReaderModel.swift`：章节加载、进度、位置、主题、搜索。
- `EbookReaderView.swift` / `EbookLibraryView.swift` / `EbookWebView.swift`。
- `EbookSelectionToolbar.swift`。

接线：
- `BrowserState` 加 `ebookReaderID`（或 URL）状态；`closeAllViewers` 清理。
- `SelectedTabContent` 增加阅读器分支；`BrowsingActions.routeLocalFile` 增加 epub/cbz/txt/md。
- `SelectedTabContent.isOpenableFile` 白名单。
- `InternalPageKind` 加 `books`（`desire://books[/<id>]`）。
- `BrowserToolProvider` 加 4 个工具定义与执行。
- `ExcerptStore` 增加电子书来源；`ReaderSpeechService`/`TranslationService`/`AgentDraftInbox` 复用。

## 七、验证门

1. **harness**：EPUB fixture（container/OPF/NCX/nav）解析、href 相对/越界、清洗
   （script/iframe/on*/javascript:）、搜索片段、进度换算、去重键、TXT 编码嗅探。
2. **E2E**：脚本生成最小 EPUB（`mimetype` 首条 store、container、OPF、nav、两章 HTML、
   一张图）→ 桥打开 → 断言阅读器状态/章节/目录/进度；重启恢复上次位置；CBZ 一页。
3. **安全**：zip-slip fixture 拒绝；CSP 阻断远程请求；EPUB 内 script 不执行。
4. **构建**：clean build 零警告；i18n 三语零骨架。
5. **性能**：20MB/500 章书，切章 <300ms；书架 100 本首屏 <500ms。
6. **手测**：真实 EPUB（中文/图文/嵌套目录）、TXT、CBZ、大屏阅读、夜间模式。

## 八、不做（本版明确）

- DRM 解密 / Kindle 云书库 / 账号同步。
- CBR/RAR（无内置 unrar）、FB2（可后续）、固定版式 EPUB 的完整排版（降级提示）。
- 阅读进度跨设备同步（服务端新域另开版本；本版本地优先）。
- 内置书城/下载源；不附带任何书籍。
- 重写 PDF 查看器（已有工作台，书架只做链接）。

## 九、风险与取舍

| 风险 | 取舍 |
|---|---|
| EPUB 规范庞杂 | 先回流式 EPUB2/3；固定版式/DRM 明确降级或拒绝 |
| 书内 CSS 破坏阅读器 | 阅读器样式后注入并提高优先级；允许"原书样式"开关 |
| 脚本/远程资源 | 清洗 + CSP + 禁网；书离线可读 |
| 大书内存 | 单章加载 + 章节缓存上限；封面缩略图 |
| MOBI/AZW3 | 只走可选 Calibre，不内置；没有就明确提示 |
| 标注锚点 | 首版用 spine+文本+近似偏移，CFI 留到后续 |
| 书架存储 | 复制入库内副本（避免原文件移动），删除可只移书架或连副本 |

## 十、发版口径

按既有规矩：CHANGELOG 用 `scripts/changelog.py add`；WhatsNew 三亮点（书架/阅读器/划词问
Agent）；产品页加"电子书"特性行与版本号；用户说「发」才发版。
