# v0.8.45 规划稿（2026-11-05）—— 订阅与信息流：RSS 阅读器 + 每日阅读流

> 阅读生态（0.8.34–37、0.8.43、0.8.44）收官后，"读什么"成了新的缺口：浏览器有
> 阅读列表（手动存的）、有页面监视（盯单页变化的），但**没有订阅**——博客/播客/
> 新闻源这类"会更新、要追更"的信息源没有家。本版补上 RSS/Atom 订阅器，并与
> 三条既有管线天然接通：阅读模式（文章打开即读）、每日简报（读什么自动进简报）、
> 同步（订阅跨设备）。

## 一、现状核实

- 全仓无 RSS/Atom 任何实现（grep 零命中）。
- 可复用件：ReaderView（阅读模式 UI，文章用 reader HTML 打开）、
  `EbookSearchCore.plainText`（HTML 剥文本）、PageWatch（定时抓取 + 噪声归一 +
  diff）、DailyBrief（每日简报 builtin）、SyncEngine（16 域骨架，加域 checklist
  成熟）、Jobs（定时抓取可走 Job 台账）、Agent 划词/摘要旁路。
- 服务端 sync 域白名单在 crates（`DOMAINS`），加域 = 白名单 + 重启，**无迁移**
  （sync_items 单表按 domain 键）。参照 ebooks 域先例（v0.8.37：无迁移、需部署）。

## 二、目标

1. RSS 2.0 / Atom 1.0 订阅：解析、抓取、未读管理、文章列表 → 阅读模式打开。
2. 追更自动化：定时抓取（ Jobs 后台）、新文章通知（分级走既有通知门控）、
   每日简报并入"今日新文章"摘要。
3. 订阅跨设备（第十六同步域，opt-in 默认关——订阅列表是个人上下文）。
4. Agent 能读能订：subscribeFeed / listFeeds / readFeedArticles。

## 三、四主题

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | RSS/Atom 订阅器（解析/抓取/未读/列表/阅读模式打开）+ 新标签页"今日阅读"卡 |
| ② Agent 基础 | 订阅工具族（subscribeFeed/listFeeds/readFeedArticles/markArticleRead）+ 摘要接通 |
| ③ 融合 | feeds 同步域（第十六域，opt-in）；Remote 手机侧订阅/未读数（API 白名单 + 部署） |
| ④ 替人干活 | 定时抓取走 Jobs、新文章通知分级、每日简报并入订阅摘要 |

**贯穿**：可靠性 = 抓取失败退避 + 单源故障不拖垮全队列；可发现性 = 页面检测到
feed（`<link rel="alternate">`）时工具栏给"订阅"入口。

## 四、Track A：订阅核心

### A1. 解析与存储

- `FeedCore`（Foundation-only，进 harness）：RSS 2.0 / Atom 1.0 解析
  （XMLParser）→ FeedMeta（title/siteURL/feedURL/description）+
  FeedItem（guid/title/link/publishedAt/summary）；容错：缺 guid 用 link、
  缺日期用抓取时间；字符实体/CDATA；编码嗅探（UTF-8 为主，ISO-Latin 兜底）。
- `FeedStore`：订阅列表 + 文章台账（guid 去重、未读集合、已读/星标、每源
  上限 500 条 + LRU 淘汰），DiskStore 落盘。

### A2. 抓取

- 抓取器：URLSession 直取 → 解析 → 台账合入（新文章计数）；并行每源独立
  任务，单源失败退避（5min 翻倍至 6h 封顶），不拖垮其他源。
- 定时：默认 30 分钟一轮（可配），走既有 15s tick 之外的独立 Timer；
  手动"全部刷新"即时跑。
- 页面发现：导航完成时检查 `<link rel="alternate" type="application/rss+xml">`，
  命中则工具栏给"订阅此站点"入口（一键 subscribeFeed）。

### A3. 阅读体验

- 订阅面板（面板类）：源分组列表 + 未读徽标；文章列表（标题/源/时间/未读点）；
  点击 → 复用 ReaderView 打开文章正文（无正文全文的源开原链接）。
- 已读/星标；"全部标为已读"。
- 新标签页"今日阅读"卡：未读数 top 源 + 最新 N 篇（与继续阅读卡同区）。

## 五、Track B：Agent 与替人干活

### B1. Agent 工具族（只读 + 受控写）

- `subscribeFeed(url)`（写：订阅）、`unsubscribeFeed(url)`（写）、
  `listFeeds()`（只读：源+未读数）、`readFeedArticles(feedUrl?, unreadOnly?)`
  （只读：标题/时间/摘要）、`markArticleRead(guid)`（写）。
- ToolRisk：listFeeds/readFeedArticles = readonly；其余 sideEffect。

### B2. 简报与通知

- DailyBriefService 并入"订阅今日新文章 N 篇（前 3 条标题）"。
- 新文章通知：走既有通知分级（routine 默认，可按源升级 urgent）；
  免打扰/预算门控照旧。

## 六、Track C：同步与 Remote

### C1. feeds 同步域（第十六域）

- payload = 订阅列表快照（源 URL/标题/分组）+ 文章**已读/星标**状态
  （正文不入库——文章抓回来就有）；client_id = 源 URL 的 HMAC（同书签密文
  语义，走既有 per-domain HKDF）。
- 客户端按加域 checklist：domainAdapters + init 订阅 + applyRemotely 包裹 +
  commit 快照。**opt-in 默认关**（同 whiteboard/workspace——个人上下文）。
- 服务端：DOMAINS 白名单加 `feeds`，**无迁移**；需要部署后跨设备才生效
  （release 注记写明）。

### C2. Remote 手机侧（轻）

- `/sync/status` 各域行自动出现 feeds；手机侧订阅列表/未读数读 sync 行
  （快照语义），不做手机端全文阅读（体量控住；进度/已读回传走域）。

## 七、批次

- **批 1**：A1 FeedCore 解析 + FeedStore（harness 覆盖 RSS/Atom/容错/去重）。
- **批 2**：A2 抓取器 + 定时 + feed 发现入口 + A3 订阅面板/阅读打开。
- **批 3**：B1 工具族 + B2 简报/通知 + 评估集 fixture。
- **批 4**：C1 同步域 + C2 Remote 快照 + 收口（i18n/CHANGELOG/WhatsNew）。
- 全程 harness 同步；每批 Debug/Release 零警告。

## 八、不做

- 播客（enclosure 音频播放）、社交媒体流（Twitter/微博类）、全文抓取适配
  （正文提取复用 Reader 管线，不做逐源定制）、OPML 导入导出（下版看需求）、
  手机端全文阅读、付费/认证 feed（HTTP Basic 除外）。

## 九、发版口径

- 用户说「发」才发；CHANGELOG 只用 `scripts/changelog.py add`。
- C1 跨设备需服务端部署（白名单 + 重启）；发版前本地 Release clean 零警告。

## 进度（2026-11-05，四批完成）

- 批 1（460c2b8）：`FeedCore` RSS 2.0/Atom 1.0 解析（XMLParser 委托 nonisolated、
  tuple 匹配避开 where 只约束末 pattern 的坑）+ `FeedCore.merge` 台账合并
  （guid→link→title id 链、缺日期补抓取时间、上限淘汰星标保护）。
- 批 2（aeeba60）：`FeedFetcher`（并行逐源、失败退避 5min→6h、ETag/
  Last-Modified 304、30 分钟定时）+ didFinish feed 发现 → 工具栏"订阅此站点"
  + `FeedPanel`（源列表/未读徽标/星标/全部已读）+ 新标签页"今日阅读"卡
  （可隐藏区块 .feeds）。
- 批 3（0808b21）：Agent 工具族 + 简报 feeds 段 + 新文章 routine 通知 +
  E18（fixture 服务器新增 /feed.xml 真实 RSS；订阅→读→退订全链，清理按
  精确 URL 不按关键词）。
- 批 4：feeds 第十六同步域（`FeedSyncCore` 快照 LWW 进 harness、SyncStore
  adapter/commit、FeedStore.applySyncChanges、服务端 DOMAINS+feeds 无迁移）
  + Rust workspace/fmt 全绿。Remote 手机端 UI 留下一版（快照 /sync/status
  已可见）。
- harness 2879/0；Debug/Release 构建零警告见发版闸门。
