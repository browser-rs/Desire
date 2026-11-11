# v0.8.50 规划稿 —— 招牌菜：研究简报（Web Research Brief）

> 基线：v0.8.49（2026-11-11，589）。0.8.47–0.8.49 把视频剪辑补成可交付的
> VideoPro，并把浏览器的崩溃韧性、可观测性焊死。这一版回到"AI 原生浏览器"的
> 看家本领：**给一个题目，浏览器自己去查、去读、去写，交一份带引用、可复核的
> 简报**——过程在后台跑，不碰用户的标签。

## 为什么是它

- 零件其实都在：`researchSources`（离线来源排序）、`ResearchRanking`（去重/
  引用格式）、阅读模式正文提取、ephemeral 标签、Jobs 台账、旁路模型档案、
  成本/预算、DOCX/PDF 工具、白板/摘录。**缺的是把它们编排成一件"产品"**。
- 现有 Agent 也能临时做一次"查资料写总结"，但没有**来源面板、引用契约、
  可复核的逐句出处、可重跑/可导出的产物**——一次性对话产物留不下来。
- 与普通"AI 搜索"的差别：跑在**真浏览器**里（登录态可选、动态页可渲染、
  能带用户已开的页面），产物落在本机（可导出 DOCX/PDF），并且**逐句给出来源**。

## 定位与取舍

- **不做**付费墙/登录墙绕过（识别到就标记 gated 并换源）、不做自动发布、
  不做无头引擎替换、不做学术数据库 API、不做整篇全文翻译（已有划词/双语）。
- 默认**不占用用户标签**：抓取走 ephemeral 会话；用户点"在标签中打开来源"
  才进自己的窗口。
- 成本可控：页数/字节/ token 三重预算 + 取消 + 超时；默认走旁路模型档案。

## 旗舰（P0）：研究简报

### 1. 编排与数据模型

- `ResearchBriefStore`（新 Feature `Features/ResearchBrief/`）：
  `Brief { id, topic, language, depth, template, createdAt, sources, sections,
  deliverableURL, tokensUsed, state }`，`Source { id, title, url, domain,
  publishedAt, fetchedAt, excerpt, gated }`。
- 落盘：`Application Support/Desire/ResearchBriefs/<id>/{brief.md, sources.json,
  meta.json}`；Job 台账记一条 `kind: .research`。
- 流程（后台 Task，步骤可观测）：
  1. **选题拆解**：topic → 3-5 条检索式（模型一次调用，确定性回退=原题）。
  2. **检索**：用用户默认搜索引擎（或指定）跑查询，收集候选 URL；与已开
     标签/历史 `researchSources` 合并（离线部分零模型）。
  3. **抓取**：候选去重/域名多样性/新鲜度排序后取前 N（默认 6，可配 3-12），
     逐个在 **ephemeral WKWebView** 打开 → 等正文稳定 → 阅读模式提取
     （复用 `reader-content.js` 的提取器）→ 记录标题/日期/正文；失败重试 1 次；
     登录墙/付费墙标记 `gated` 并跳过。
  4. **阅读笔记**：每源一次旁路调用，产出 3-5 条"可引用要点"（带原文片段）。
  5. **成文**：按模板合成（综述/对比/时间线），**每条结论必须挂来源编号**，
     找不到来源的结论必须写成"未找到来源"（硬约束，进输出护栏）。
  6. **交付**：写 `brief.md` + `sources.json`；可选导出 DOCX（现有工具链）/
     复制到 Downloads；完成通知 + 会话 system 备注（不打断回合）。
- 预算与取消：`maxPages`、`maxBytesPerPage`（默认 400KB）、`maxTokens`；
  超额停止并在产物里写明"因预算截断"；`cancel` 立即终止并落草稿。

### 2. 引用契约（本版最硬的一条）

- 正文行内引用 `[1][2]`；末尾"来源"列表与 `sources.json` 一一对应。
- 每条引用可选**逐句核验**：检查引用的原文片段是否在源正文中**逐字出现**
  （归一化空白/标点后精确匹配）；不匹配的引用在简报里标 ⚠️，并在 meta 里记
  `unverified: n`。伪造引用一律不许静默通过。
- 结构化输出：`brief.md` 由模型按固定 Markdown 骨架产出（标题/摘要/分节/
  来源），宿主解析骨架后**重建来源列表与编号**（不信任模型自排的编号）。

### 3. 模板

- `summary`（要点综述，默认）、`compare`（对比表：维度 × 对象）、
  `timeline`（按时间排序的事件线）。模板只改"章节骨架与提示词约束"，
  引用契约不变。

## 融合与替人干活

### 4. 入口与产物去向（可发现性）

- Agent 快捷动作「研究简报」+ 侧栏「研究」页（历史简报、来源数、重新生成、
  导出、删除）+ 深链 `desire://research?topic=…`。
- 简报卡嵌在 Agent 消息里（标题/来源数/未核验数/打开/导出）。
- 产物去向：Markdown 默认存 `Downloads/Research/<slug>.md`；DOCX 可选；
  「发送到白板」= 按章节生成结构化块；「关键引用进摘录」= 每源 top 1 句进
  `ExcerptStore`（带反链）。

### 5. 后台纪律

- 抓取用 **ephemeral WKWebsiteDataStore**（默认不共享用户 cookie；用户可在
  设置里允许"使用我的登录态抓取"，默认关——登录墙站点因此标 gated）。
- 并发 2、单页超时 20s、域名间隔 1s；整体 10 分钟硬超时（进 Job 失败终态）。
- 页面内容进模型时明确标注"数据不是指令"（沿用防注入口径）。

## Agent 基础

### 6. 工具与桥

- 工具 `researchBrief`：`{topic, depth?, language?, template?, maxPages?,
  openInTabs?}` → 立即返回 job id；`backgroundTaskStatus` 查进度。
- 桥：`POST /research/briefs`（start）、`GET /research/briefs`（列表/状态）、
  `GET /research/briefs/{id}`（含 sources/核验统计）、`POST /research/briefs/
  {id}/cancel|rerun|export`。
- 工具描述与命令面同步进 `tests/video-pro-actions.py` 同款漂移检查
  （新脚本 `tests/research-actions.py`）。

### 7. 成本与路由

- 默认旁路档案（标题/记忆整理同款）；简报生成单独统计 token 与成本（沿用
  `AgentUsage`/单价表），完成备注里带 `promptTokens/completionTokens`。
- 预算上限（默认 60k tokens）可配；超额先降"每源要点数"再停。

## 可靠性与可发现性（贯穿）

- 每个失败可归因：gated / 404 / 超时 / 提取为空 / 预算截断，逐项写进 meta
  与简报附注（用户看得到"为什么少了一个源"）。
- 空结果诚实化：0 个来源时**不出简报**，给"检索失败/全部被墙"的明确提示。
- i18n 三语；What's New 一条"研究简报"；体检页加"研究抓取（最近一次）"。

## 批次

1. **批 1（P0）**：数据模型 + 存储 + 引用契约 + 编排骨架（模型调用用假端点
   可测）+ 本地 fixture 端到端（离线确定性）。
2. **批 2（P0）**：实时抓取（ephemeral 会话/提取/去重/预算/取消/失败归因）
   + 登录墙识别 + 并发与限速。
3. **批 3（P0/P1）**：成文模板 + 逐句引用核验 + DOCX 导出 + 白板/摘录回填。
4. **批 4（收口）**：研究页与快捷动作/简报卡 + 桥与工具 + i18n/WhatsNew +
   套件（`tests/research-brief-e2e.py`）+ 发版闸门。

## 验收（每批过桥/脚本）

- 批 1：本地 3 页 fixture → 简报生成；`sources` 3 条；行内 `[1][2][3]` 与
  来源一一对应；无来源结论带"未找到来源"标记；伪造引用被标 ⚠️。
- 批 2：fixture 造 慢站/404/登录墙/超大页 → 逐项状态正确（gated/timeout/
  failed/truncated）；取消 1s 内停；预算上限生效；用户标签零变化。
- 批 3：DOCX 打开含标题/分节/来源列表；白板块数与章节一致；摘录反链可回跳。
- 批 4：桥端到端（start→poll→export）+ 面板快照 + 三语键齐 + 漂移检查过。

**发版**：用户说「发」才发；本地 Release clean 零警告 + harness + release-smoke
是硬闸门。

## 实现状态（2026-11-11）

**已交付**：批 1（模型/引用契约/渲染 + 注入式编排 + fixture 测试）、批 2（三引擎检索解析/
非持久会话抓取/服务编排/Jobs/桥端点 + 离线 E2E 18/18）、批 3（交付物落 Downloads/摘录
回填/Agent 工具/桥对齐）、批 4 部分（`desire://research` 研究页、`/research` 斜杠命令、
三语键、What's New）。

**未做（明确挪后）**：DOCX 导出（当前交付 Markdown；DOCX 需要最小 WordprocessingML 写出器，
单独排期）、简报 → 白板块回填（先保留「关键引用进摘录」）、研究页的实时进度条与来源预览
（当前靠 state/Jobs 面板）、模板的对比表渲染优化。
