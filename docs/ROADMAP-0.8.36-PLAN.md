# v0.8.36 规划稿（2026-11-02，已发布）—— 读得懂、听得见、找得到、带得走（阅读器 2.0）

> 0.8.34/0.8.35 已经把书架、分页、笔记、朗读、翻译、网页成书做出来了；本版不再铺新地基，
> 只做读者最常用的四件事：**外语书能对照读、听书能跟字、全库能搜、书能带走**。
> 跨设备阅读同步继续押后——它需要服务端白名单 + 用户部署，本版全部端上完成。

## 一、现状核实（规划前，2026-11-02）

- **翻译只有选段**：`EbookReaderView` 的 `translationTask` 只翻译划词结果，结果卡显示；
  没有整章/段落对照、没有目标语言选择、没有译文缓存。
- **朗读没有逐词高亮**：`ReaderSpeechService.onSpeakRange` 只把比例交给
  `model.speechProgress` 去翻页；正文没有当前词/句标记。`chapterPlainText` 是剥标签文本，
  与阅读 HTML 的文本节点不保证一一对应，不能直接拿偏移去包 DOM。
- **搜索只到单本**：`EbookSearchCore` 按书搜索；Agent `searchBook` 也只搜一本；
  书架搜索框只匹配标题/作者/文件名，不搜正文。
- **没有阅读摘要**：`ReadingStatsStore` 有每日秒数/翻页，`EbookHighlightStore` 有笔记，
  但没有"最近读了什么/划了什么"的聚合；统计页只有数字和柱状图。
- **没有 EPUB 导出**：网页书/导入书都只能在 Desire 内读；`ArchiveEngine.create` 用
  `zip -r`，mimetype 会被压缩且不在首位，不能直接当 EPUB。
- **没有 FB2 / 固定版式检测**：`EbookFormat` 无 fb2；`EbookCore.parseOPF` 不读
  `rendition:layout`，固定版式书会按回流式硬排。
- **没有"继续阅读"入口**：书架按最近阅读排序 + 统计摘要；没有大卡、没有最近笔记。
- **正文图片不能放大**：图片只按栏宽显示，点击无查看器。
- **朗读声音/语速不可调**：`ReaderSpeechService` 固定 `AVSpeechUtteranceDefaultSpeechRate`
  和按 CJK 占比选的 voice。

## 二、目标

1. **读得懂**：整章双语对照翻译，按段插入译文，可开关、可换目标语言、有缓存。
2. **听得见**：整章朗读时正文逐词/逐句高亮，自动滚动/翻页；声音与语速可调。
3. **找得到**：全库正文搜索（书架 UI + Agent `searchLibrary`），结果按书分组、可跳章。
4. **带得走**：把网页书/HTML 书导出成标准 EPUB；补 FB2 导入与固定版式检测/降级。
5. **读得顺**：书架"继续阅读"大卡、最近笔记、阅读摘要；正文图片可放大。

## 三、四主题覆盖

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | 网页书 → EPUB 导出；FB2 本地文件打开；书架"继续阅读"入口 |
| ② Agent 基础 | `searchLibrary` 全库搜索；`readingDigest` 阅读摘要；摘要预填 Agent |
| ③ 融合 | 整章双语翻译；逐词朗读高亮；正文图片查看器；笔记/摘要回流 |
| ④ 替人干活 | EPUB 导出、FB2、阅读摘要、继续阅读、朗读设置 |

## 四、功能设计（10 件）

### 1. 整章双语对照翻译（旗舰 A）

- **现状**：只有选段翻译结果卡。
- **增量**：
  - 阅读 HTML 注入 `__desireBlocks()`：给 `p/li/blockquote/h1-h4` 编号并返回纯文本；
    Swift 用 `TranslationSession.translations(from:)` 按 8 段一批翻译，`clientIdentifier`
    回填到对应块；JS 在每段后插入 `<div class="desire-translation">`，分页重建后保持。
  - 工具条加"翻译本章/隐藏译文"；目标语言菜单（系统语言默认 + 英/中/日/韩等），
    记住偏好；翻译中显示进度，可取消。
  - 缓存：`EbookTranslationStore` 按 `bookID + chapterIndex + targetLanguage` 存段落译文
    （DiskStore `ebook.translations.<bookID>`，每章 cap），重进书秒开。
  - 译文块参与分页：插入后重新 paginate；译文字号/颜色跟随主题但弱化（0.8 透明度）。
- **验收**：fixture 章节 10 段 → 插入 10 条译文；开关可隐藏/恢复；重开书缓存命中；
  分页模式下译文不跨页错位；语言包缺失时给明确错误。

### 2. 逐词朗读高亮（旗舰 B）

- **现状**：朗读只翻页，正文无标记。
- **增量**：
  - JS `__desireSpeechText()` 从正文文本节点拼出朗读文本（块之间加空格/换行），
    `__desireSpeechHighlight(start,end)` 按同一文本节点偏移包 `<mark class="desire-speech">`，
    清除上一个标记并滚动/翻到该页。
  - Swift 朗读改为使用 `__desireSpeechText()` 的字符串，`onSpeakRange` 直接映射 DOM 偏移；
    `seek(to:)` 仍保留，但不再作为主定位。
  - 停止/切章/手动翻页清标记；选中段 Speak 不启用逐词高亮。
- **验收**：整章朗读时高亮跟随、跨页自动翻页；停止后标记消失；与持久高亮/搜索高亮
  不互相清除；长章节偏移不漂移。

### 3. 全库正文搜索

- **现状**：只搜单本。
- **增量**：
  - `EbookLibrarySearchCore`（纯逻辑，进 harness）：多书结果合并、按书分组、命中数上限、
    排序（最近阅读优先）。
  - 书架搜索框输入后出现"在全部书籍正文中搜索"按钮/结果面板；后台用
    `EbookContentLoader` 读章节（最多 50 本），逐书 `EbookSearchCore.search`；结果
    点开 → 打开该书该章并高亮关键词。
  - Agent 工具 `searchLibrary(query, limit)`：返回 `书名 [chN] 片段`，供跨书问答。
- **验收**：fixture 3 本书不同命中；结果分组/跳转正确；取消/空查询不卡 UI；
  Agent 工具返回同上；50 本冷搜索有进度且可取消。

### 4. 阅读摘要（阅读回顾）

- **现状**：统计只有数字，无"最近读了什么/划了什么"。
- **增量**：
  - `ReadingDigestCore`（纯逻辑，进 harness）：输入最近 N 天统计、书进度、笔记/摘录，
    生成 Markdown：读了哪些书/时长、完成度变化、最近 10 条高亮/笔记、连续天数。
  - 统计页"生成本周回顾"→ 本地摘要卡；"让 Agent 写一段回顾"→ 预填 Agent 草稿
    （带摘要 + 可选 `addBookNote` 保存）。
  - Agent 工具 `readingDigest(days)` 返回同一份文本。
- **验收**：种子数据 3 天 → 摘要含书名/时长/笔记；空数据给空状态；Agent 工具同源；
  预填草稿带当前统计。

### 5. 网页书 → EPUB 导出

- **现状**：网页书只是库内 HTML 目录，无法带走。
- **增量**：
  - `EbookEPUBExporter`：为 `.html`/web 书生成 EPUB 3 目录（mimetype 必须**首个且不压缩**、
    META-INF/container.xml、OEBPS/content.opf、nav.xhtml、chapter.xhtml、images/、
    cover）；标题/作者/语言/identifier 来自 `Ebook`，图片沿用已本地化的 `images/`。
  - 打包用 `zip -0X` 先写 mimetype，再 `zip -rX` 写其余；输出 `.epub` 到用户选择路径。
  - 书架右键/阅读器菜单"导出 EPUB"；导出后可用 Desire 自己重新导入做 round-trip。
- **验收**：导出文件 mimetype 首条且 stored；重新导入后章节/图片/标题一致；
  无图片书也能导出；文件名安全化。

### 6. FB2 导入 + 固定版式检测

- **现状**：`EbookFormat` 无 fb2；固定版式按回流式硬排。
- **增量**：
  - `FB2Core`（XMLParser，nonisolated delegate）：`description/title-info` 取书名/作者，
    递归 `body/section` 取标题/段落，`binary` base64 图片落 `assets/` 并把 `<image>` 改写；
    导入为 `.html` 书（章节 HTML）或新 `.fb2` 格式 + 章节缓存。
  - 固定版式：`parseOPF` 读 `<meta property="rendition:layout">pre-paginated</meta>`；
    检出后阅读器顶部给"固定版式：按页缩放，可能不完美"提示，并按 spine 一页一章加载
    （不做完整绝对定位排版）。
- **验收**：FB2 fixture（两章 + 一张 base64 图）导入/阅读/搜索；固定版式 EPUB 检出提示；
  非固定版式不误报。

### 7. 继续阅读与书架仪表盘

- **现状**：书架按最近排序，无大卡。
- **增量**：书架顶部"继续阅读"卡（最近未读完 + 封面/进度/继续按钮），最近笔记 3 条
  （点击跳书），本周统计摘要；空库不显示。可与"最近添加"横向卡片并存。
- **验收**：进度 0.3 的书出现在大卡；点继续打开到上次章节；完成后大卡切到下一本；
  最近笔记跳转正确。

### 8. 正文图片查看器

- **现状**：图片只能按栏宽显示。
- **增量**：阅读 HTML 注入图片点击 → `ebookImage` 消息（src + rect）；Swift 覆盖层
  显示原图，支持滚轮/双指缩放、拖拽平移、双击复位、Esc/点背景关闭；本地图片经
  `bookRoot` 读取，远程图片仍被 CSP 挡。
- **验收**：点击 EPUB 图片打开；缩放/平移/关闭；翻页后覆盖层自动关；不劫持正文选择。

### 9. 朗读声音与语速

- **现状**：voice/rate 固定。
- **增量**：`ReaderSpeechSettings`（UserDefaults）：语速 0.3–0.8、声音按语言列出
  `AVSpeechSynthesisVoice`；阅读器朗读菜单进设置；选中段 Speak 与整章朗读共用。
- **验收**：改语速立即生效并持久化；切换声音重启后保留；无对应语言 voice 时回退默认。

### 10. 收口与验证

- i18n 三语补全；CHANGELOG 用 `scripts/changelog.py add`；WhatsNew 三亮点；
  产品页版本号/特性行同步。
- harness 新核心全绿；JS 探针（翻译插入/朗读高亮/图片点击）；E2E（FB2/EPUB round-trip/
  全库搜索/摘要）。
- **发版闸门**：本地 **Release** clean build 零警告 + `tests/run.sh`；用户说「发」才发。

## 五、批次

- **批一（读得懂）**：1 + 3 —— 翻译核心/JS/缓存/UI，全库搜索核心/UI/Agent 工具。
- **批二（听得见）**：2 + 8 + 9 —— 逐词高亮、图片查看器、朗读设置。
- **批三（找得到/带得走）**：4 + 5 + 7 —— 阅读摘要、EPUB 导出、继续阅读仪表盘。
- **批四（格式与收口）**：6 + 10 —— FB2/固定版式、i18n/探针/E2E/发版候选。

## 六、技术地图

**新增 `Features/Ebooks/`**

- `EbookTranslationCore.swift`（纯逻辑：块模型/缓存键/分批上限，进 harness）
- `EbookTranslationStore.swift`（按书 DiskStore 译文缓存，cap）
- `EbookTranslationJS.swift`（块编号/插入/清除/重新分页）
- `EbookSpeechJS.swift`（朗读文本与 DOM 偏移高亮/清除）
- `EbookLibrarySearchCore.swift`（多书结果合并/分组/上限，进 harness）
- `ReadingDigestCore.swift`（统计+笔记 → Markdown，进 harness）
- `EbookEPUBExporter.swift`（EPUB 3 打包，mimetype stored 首位）
- `FB2Core.swift`（XMLParser，delegates nonisolated，进 harness）
- `EbookImageOverlay.swift`
- `ReaderSpeechSettings.swift`

**改造**

- `EbookReaderModel`：翻译块/缓存、朗读文本来自 JS、图片消息、固定版式标记。
- `EbookReaderView`：翻译/朗读/图片菜单与覆盖层、继续阅读跳转。
- `EbookWebView`：`ebookBlocks` / `ebookImage` 消息、朗读文本求值。
- `EbookLibraryView`：全库搜索入口、继续阅读卡、最近笔记、导出 EPUB。
- `EbookAgentTools` + `BrowserToolProvider+Definitions/Execution`：
  `searchLibrary`、`readingDigest`。
- `Ebook.swift` / `EbookImporter` / `EbookContentLoader` / `EbookCore`：fb2、fixed-layout 元数据。
- `ReadingStatsView`：回顾入口。
- 资源：xcstrings、CHANGELOG、WhatsNew、website。

## 七、验证门

1. **harness**：翻译分批/缓存键、全库搜索合并、摘要聚合、FB2 解析（标题/章节/base64 图）、
   EPUB manifest 与 mimetype 顺序/路径安全。
2. **JS 探针（WKWebView）**：翻译块插入/清除后分页不丢；朗读高亮偏移跨块；图片点击消息。
3. **E2E**：FB2 fixture 导入→读→搜；网页书导出 EPUB→重新导入 round-trip；
   3 本书全库搜索→跳章；种子统计生成摘要；翻译在语言包已装时手动验证。
4. **构建**：本地 Debug + **Release** clean build 均零警告；`tests/run.sh` 全绿。
5. **i18n**：新键三语零 null。
6. **手测（用户）**：外文书对照翻译、听书跟字、全库搜索、EPUB 导出、FB2、图片放大。

## 八、不做（本版明确）

- **电子书跨设备同步**（进度/书签/高亮）：需要服务端 `DOMAINS` 白名单 + 用户部署；
  另开版本，客户端适配与服务端同批规划；部署提醒同样适用。
- CFI 精确锚点、DRM、CBR/RAR（无内置 unrar）、固定版式的完整绝对定位排版
  （本版只检出 + 按页缩放/提示）。
- 整本书一次性翻译（只做当前章，避免长任务与语言包限制）；逐词翻译。
- PDF/CBZ 批注、书城/书源、随包分发书籍。
- 翻译走模型/云端（本版继续 Apple 端上 Translation，不烧 token）。

## 九、风险与取舍

| 风险 | 取舍 |
|---|---|
| 翻译框架分批限制/语言包缺失 | 8 段一批、可取消、缓存；缺包给系统提示/明确错误 |
| 译文插入改变分页 | 插入后重新 paginate；译文块不参与搜索命中 |
| 朗读文本与 DOM 偏移不一致 | 朗读文本由同一套 DOM 文本节点生成，不从 stripHTML 取 |
| EPUB mimetype 被压缩/不在首位 | `zip -0X` 单独写 mimetype，再 `zip -rX` 写其余；round-trip 验证 |
| FB2 base64 图片内存 | 单图上限、总量上限、失败降级为占位 |
| 全库搜索冷启动慢 | 最多 50 本、后台、可取消、显示进度；不建持久全文索引（本版） |
| 固定版式误判/排版不完美 | 只检出 + 按页缩放 + 明确提示，不承诺逐像素还原 |
| 翻译缓存膨胀 | 每书每章 cap，超过淘汰最旧；清缓存入口 |

## 十、发版口径

按既有规矩：CHANGELOG 只用 `scripts/changelog.py add`；WhatsNew 三亮点
（整章对照翻译/听书跟字/EPUB 导出）；产品页同步版本号与特性行；
**发版前本地 Release clean build 零警告**；用户说「发」才发。
