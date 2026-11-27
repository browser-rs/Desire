# v0.8.80 规划稿（2026-11-27）—— 心里有数：权限与隐私中心 · 省钱与放手 · 跨端掌控

> **主题叙事**：0.8.70–79 连续把 Agent 与下载做深，用户对"这台机器上到底发生了什么"的掌控
> 没有同步跟上——权限只有三种且不能在弹窗里改、清除数据没有时间范围、翻译费用与缓存不可见、
> 审批一个一个点、手机看不到批次逐项进度、服务端没有配额与审计。本版回到**掌控感**：
> **看得见**（权限 / 费用 / 存储 / 下载 / 体检）、**管得住**（权限 / 审批 / 配额 / 保留策略）、
> **放得开**（提示词缓存 / 成本建议 / 审批批处理 / 定时窗口）。浏览器基础回到旗舰位，
> Agent 旗舰落在"省钱与放手"，Remote 与 API 两轨按 0.8.38 的三轨规矩同版跟进。
>
> **规模**：26 件（Track A 四主题 16 + 收口贯穿 5 + Remote/API 5），七批实施。
>
> **规划前核实（HEAD `a25849b0`，三路只读审计，逐条读代码）**——以下**已交付，不进本版**：
> 翻译 2.0 的全页分批 / 旁路档案 / 块缓存 / 术语表 / 双语成书（0.8.62–64）、token 校准与
> 可视化（0.8.60/63）、记忆使用徽标与排序（0.8.63）、.handle 等解锁重发（SessionGuard）、
> 下载中心 v2 与活动中心（0.8.10 / 0.8.39）、书签管理与死链校验、阅读模式与阅读列表同步、
> 标签搜索（⌘\）与概览、工作区、崩溃恢复、打印/PDF/WebArchive、按标签静音与 PiP、
> 档案切换、HTTPS 升级、同步 16 域（两端对齐）、admin CLI 基础命令。

## 存量收口（审计实锤，随批 1–5 修）

| # | 缺陷 | 证据 | 影响 |
|---|------|------|------|
| S1 | **翻译"替换式"不还原 inline code 占位符**：默认按钮走替换式，`el.textContent = it.text` 原样写入 `⟦N⟧` | `UserScripts/bilingual-translate.js:143-156`（对照式在 `:85-98` 有还原） | 页面正文出现乱码占位符 |
| S2 | 翻译缓存 LRU 从未接线：`evictionTargets` 只被 harness 调用 | `TranslationCache.swift:97-109`；调用点仅 `tests/main.swift:11512` | 缓存无上限增长 |
| S3 | 站点"自动双语"入口不可达：`setAutoBilingual` 零调用方；`cleanEmpty` 会把只剩该标志的站点丢掉；仅精确 host | `SiteSettingsStore.swift:74-84, 199-204`；`WebView.swift:2261-2267` | CHANGELOG 宣称可用，用户设不了 |
| S4 | **iOS 产物屏走错通道**：直连中继 `/artifacts`、`/artifacts/read`，服务端无该路由、信封也不同 | `RemoteClient.swift:1075, 1083`；`crates/` 零命中；`RemoteModels.swift:458-459` | 0.8.63 旗舰在真机上不可用 |
| S5 | Remote 丢弃 Mac 的 `ok` 确认帧；错误帧覆盖连接标签 | `RemoteClient.swift:834-995, 989-993` | 操作成功无反馈、误报断线 |
| S6 | token 校准显示用档案级窗口 + 小写键比对，按模型窗口恒显示未知 | `AgentSettingsSection.swift:166-174` | 设置页读不到真值 |
| S7 | 批次日志 GC 只在启动时跑，且容量统计含已按龄删除的文件 → 过度删除 | `BackgroundCommandStore.swift:455-478` | 日志早于预期消失 |
| S8 | **带档案后缀的同步域逃逸 TTL/GC**：`history@<uuid>` 落 `sync_items`，历史 TTL 与通用 GC 都不认 | `sync_model.rs:37-43`、`sync_service.rs:310`、`sync_gc.rs:123-127`；客户端 `SyncModels.swift:65-73` | 服务端历史数据永不清理 |
| S9 | 锁屏检测是 `frontmostApplication != nil` 的代理，且只覆盖 JobWatch 一处 | `SessionGuard.swift:14-18`；`JobEventCenter.swift:193-259` | 定时/心跳/看门狗在锁屏时照跑或静默失败 |
| S10 | `HTTPSUpgrader.swift` 无任何引用（死代码）；HTTPS 失败总回退 http | `HTTPSUpgrader.swift:7-75`；`WebView.swift:2610-2627` | 无严格模式，死代码误导 |

## Track A — 常规四主题（16 件）

### ① 浏览器基础（旗舰：站点权限与隐私中心）

**1. 站点权限与隐私中心（旗舰）**
- **现状依据**：权限类型只有 camera / microphone / cameraAndMicrophone / geolocation
  （`PermissionRule.swift:15-17`）；锁弹窗只展示不能改（`SiteControlsView.swift:7-220`）；
  没有"仅允许一次"；清除浏览数据恒为 `.distantPast`、历史只能全清
  （`PrivacySettingsSection.swift:234`）。
- **增量**：① 权限类型扩展——通知 / 弹窗 / 剪贴板读取：**先做 WKWebView 能力探针**
  （通知与剪贴板读取在 WKWebView 里可能没有系统提示 API），API 支持不了的类型在面板里
  如实标"系统不支持"，不做假开关；② "仅此一次"；③ 锁弹窗内直接改权限、清站点数据；
  ④ 清除浏览数据加时间范围（1 小时 / 24 小时 / 7 天 / 全部）与"仅此站点"的历史/数据；
  ⑤ 严格 HTTPS-only 模式（升级失败即拦截页，可显式继续 http）并删掉死代码 `HTTPSUpgrader`。
- **验收**：harness（规则矩阵 / 时间范围参数 / 严格模式判定）+ 桥 E2E（锁弹窗读写、
  按站点清除后的记录数、HTTPS 拦截页）+ 快照；探针结论写进 AGENTS。

**2. 密码面板补全**
- **现状依据**：生成 / CSV 导入 / 改密提示已有；无手动增改删
  （`PasswordPanel.swift:227-345`）；健康判定（弱 / 重复 / 旧）只能经智能体工具
  （`PasswordHealth.swift:7-119`）；无泄露检查。
- **增量**：手动添加 / 编辑 / 删除；健康卡进面板；泄露检查——HIBP k-匿名
  （只发 SHA-1 前 5 位，opt-in，明文不出本机）。
- **验收**：harness（健康判定 / 前缀计算）+ 桥 E2E + 假端点断言**只收到 5 位前缀**。

**3. 自动填充升级**
- **现状依据**：只有地址、单档案、页面加载即填、无卡、无聚焦选择器
  （`FormAutofillStore.swift:6`；`WebView.swift:2325-2330`）。
- **增量**：多档案（已落地：命名/存库/载入/新建 + 站点弹层按档案填充）、聚焦时选择器、
  提交后询问保存；**支付卡暂缓**——需要独立的加密存储设计（不能落明文 DiskStore，
  也不宜塞进现有 AI 密钥保险库），留到单独一批。
- **验收**：本地 fixture 表单 E2E（填充值 / 已有值不覆盖）已过；卡片与保存提示随后续批。

**4. 标签与阅读小件**
- **现状依据**：标签组不能重色、不能把标签拖进组（`TabGroupStore.swift:12-76`；
  `TabBar.swift:900-930` 只重排/转移）；查找没有整词（`FindBar.swift:51-66`）；
  只有页面缩放、没有纯文本缩放（`TabManager.swift:149-153`）。
- **增量**：组重色 / 拖标签入组（已落地）；查找"整词"开关与纯文本缩放**暂缓**——
  WKWebView 的查找没有整词模式，自绘高亮需要改写页面 DOM（React 站风险），要单独设计；
  纯文本缩放没有公开 API（页面缩放已有）。不做"看起来能点但只对一半生效"的开关。
- **验收**：标签组重色/加组走桥 E2E；整词/文本缩放在下一版用独立方案评估。

**5. 媒体控制**
- **现状依据**：静音按标签（`TabManager.swift:162-168`），无站点级静音、无全局媒体控制。
- **增量**：站点级静音；全局媒体控制（菜单栏 / 工具栏：播放暂停、跳到有声标签、全部静音）。
- **验收**：桥 E2E + 手测（手感由用户验）。

**6. 普通下载跨重启续传**
- **现状依据**：`resumeData` 只在内存（`DownloadItem.swift:29-35`），重启后不能续。
- **增量**：resumeData 随会话落盘，重启恢复为暂停态可续；单条重试。
- **验收**：E2E（quit → 重启 → 续传，fixture 断言 Range 请求与已下字节不重下）。

### ② Agent 基础（旗舰：省钱与放手）

**7. 提示词缓存（Agent 旗舰）**
- **现状依据**：全仓 `cache_control` / `prompt_cache` 零命中；AnthropicProvider 不发缓存头；
  `ModelProvider` 没有 cached token 字段——系统提示 + 工具索引（≈ 最大的一块）每回合全价重算。
- **增量**：① 计量——OpenAI `prompt_tokens_details.cached_tokens` / DeepSeek
  `prompt_cache_hit_tokens` / Anthropic `cache_read_input_tokens` 解析进消息与统计；
  ② Anthropic 加 cache_control 断点（system / tools 稳定前缀）；③ 前缀稳定性审计
  （工具索引顺序、系统提示分层不随会话抖动）；④ 统计页显示缓存命中率与省下的 token。
- **验收**：假端点断言请求字段 / 响应解析（三家用量纯逻辑进 harness）；统计页快照。

**8. 成本 / 延迟感知路由（建议式）**
- **现状依据**：`RoutingDecision` 是关键词 + 字符长度启发式（`RoutingDecision.swift:44-80`）；
  价格只进统计与预算（`ModelPriceTable.swift`、`CostBudgetMonitor.swift:49-70`），
  `modelPerf` 的 TTFT / 耗时没有参与决策。
- **增量**：按任务类型给"建议模型"（价格 × 预计 token + 实测 TTFT/耗时 p50），回执与面板
  写明理由；**不偷偷换模型**——与 0.8.78"方式决定权"同一原则，用户 / 智能体采纳才切。
- **验收**：harness（排序纯逻辑）+ 假端点回合断言"建议"行与采纳后的切换。

**9. 审批批处理**
- **现状依据**：单个 `pendingApproval`（`AgentSessionStore.swift:108`）；重启丢待批
  （`:1963-1968`）；没有"批准本轮剩余"。
- **增量**："批准本轮剩余同类调用"（按工具 + 站点 + 参数模式）；待批持久化跨重启；
  每次批量批准写审计行；危险工具不进批。
- **验收**：harness（模式匹配）+ 桥 E2E（批量批准后连续执行 / 重启后待批仍在）。

**10. 自评后自动修订**
- **现状依据**：critique 只附在消息上给用户看（`AgentSessionStore.swift:4073`），
  发现缺陷后没有修订动作。
- **增量**：有客观失败证据的 critique → **一次**有界修订回合（成本上限、用户可见"修订中"）。
- **验收**：假端点 E2E（critic 指出 → 修订 → 终答）。

### ③ 融合（浏览器 + Agent / 跨端）

**11. Remote 批量下载控制**
- **现状依据**：iOS 只有聚合作业行（`RemoteJobsView.swift:58-134`），没有逐项状态、
  暂停 / 恢复 / 跳过 / 重试 / 日志——这些只在 Mac 本地桥（`AutomationServer.swift:408-409, 700-706`）。
- **增量**：逐项状态与进度、暂停 / 恢复 / 跳过 / 重试、日志尾；批次完成 / 失败通知。
- **验收**：帧契约测试 + 模拟器；真机联调（用户参与）。

**12. Remote 实时标签页**
- **现状依据**：Remote 只能恢复工作区 / 归档会话 / 在 Mac 打开网址；没有实时标签列表、
  切换、关闭、搜索、标签组（桥 `/tabs/*` 已有）。
- **增量**：实时标签列表（含分组）、切换 / 关闭 / 搜索、移动到窗口；Handoff 不变。
- **验收**：帧契约 + 模拟器。

**13. Remote 体检与同步健康**
- **现状依据**：Doctor / 同步健康 / DPP 适配器在 Remote 全缺（`apps/ios` 零命中）。
- **增量**：一键体检结果页（含修复建议）、同步状态 / 冲突 / 设备、适配器启停。
- **验收**：桥帧 + 快照。

**14. 截图 OCR 翻译**
- **现状依据**：OCR 面板只有复制 / 复制表格 / 上白板（`ScreenshotOverlay.swift:280-326`）。
- **增量**：OCR 结果加"翻译"（走旁路档案与术语表，原文 / 译文对照）。
- **验收**：假端点回合 + 快照。

### ④ 替人干活

**15. 定时任务链输出交接**
- **现状依据**：`chainTo` 是单链且不传上一轮输出（`AgentScheduler.swift:493-499`）。
- **增量**：链上可引用上一轮输出 / 产物（占位符 + 产物路径）；链路在任务卡上可视化。
- **验收**：harness（链解析）+ 桥 E2E（两步链，第二步拿到第一步产物）。

**16. 批量下载定时窗口**
- **现状依据**：批次只有立即开始 / 暂停；没有时段与总时长。
- **增量**：批次可设"时段窗口"（如 02:00–08:00）、总时长 / 并发上限；到点自动开始 / 暂停；
  Remote 可见。
- **验收**：harness（窗口判定纯逻辑）+ 桥 E2E（立即触发分支）。

## Track B — 收口与贯穿（5 件）

**17. 翻译存量收口（含 P0）**
- **增量**：替换式还原占位符（S1）；缓存驱逐接进写路径 + 缓存体量 / 清理 UI（S2）；
  站点自动双语入口——站点设置 UI + 桥 + 智能体工具，`cleanEmpty` 不再丢该标志（S3）；
  失败批"重试"按钮；TranslateBar 显示当前档案 / 费用与缓存命中。
- **验收**：E2E（替换模式页面无 `⟦N⟧`；缓存上限生效；自动双语命中）；harness（驱逐）。

**18. 存储健康面板 + 统一 GC**
- **现状依据**：保留策略碎片化——三处翻译缓存无 GC（`ReaderTranslationStore`、
  `EbookTranslationStore`、`TranslationCache`）、会话文件无保留 / 容量策略、批次日志见 S7；
  没有按域体量视图。
- **增量**：设置"存储"页（按域体量 / 可清理）；统一保留策略（会话 N 天 / 容量、翻译缓存
  50MB、批次日志修正）；单一调度（启动 + 每日）。
- **验收**：harness（保留判定）+ 桥 `GET /diag/storage` + 快照（宽 / 窄）。

**19. 锁屏真检测 + 全面守卫**
- **增量**：真锁屏检测（`CGSessionCopyCurrentDictionary` / NSWorkspace 组合）；定时任务 /
  心跳 / 看门狗 / 通知统一守卫；等待队列落盘；`/diag/health` 增 `screenLocked`；Doctor 检查。
- **验收**：harness（策略纯逻辑）+ 桥 E2E（模拟锁屏标志下动作挂起、解锁后重放）。

**20. 上下文预算控件 + 转存可见**
- **现状依据**：`compactionBudgetOverride` 私有且不持久化（`AgentSessionStore.swift:490`）；
  工具结果转存只在模型侧，UI 行被截断看不到标记（`AgentToolCallList.swift:246`）。
- **增量**：预算 / 触发阈值滑杆（持久化，按档案）；工具行"已转存 N KB"徽标 + Finder 显示；
  与占用芯片同源。
- **验收**：harness + 桥 E2E + 快照。

**21. 校准显示修复 + Doctor 稳定 ID / 一键修复 + 轨迹导出**
- **增量**：按模型窗口 / 键归一（S6）；检查项稳定 ID + 修复动作（清转存 / 重测连通 / 重校准）；
  轨迹页导出全量 JSONL；新增存储 / 翻译缓存 / DiskStore 检查。
- **验收**：harness（ID 唯一）+ 桥 E2E。

## Track C — Remote / API 运营面（5 件）

**22. Remote 传输缺陷修复（P0）**
- **增量**：产物改走控制帧通道（请求 / 响应帧 + 统一信封，S4）；处理 `ok` 帧（S5）；
  错误用独立横幅不覆盖连接标签；访问等级对齐 Mac 三档。
- **验收**：模拟器 + 桥帧 E2E（产物列表 / 读取 / 确认提示）。

**23. Remote 下载记录与多 Mac**
- **现状依据**：无下载记录；单条只能暂停 / 恢复（`RemoteDownloadsView.swift:42-49`）；
  单 `desktopDeviceID`（`RemoteClient.swift:205-206`），服务端已允许 4 台。
- **增量**：下载记录（按站点）+ 单条取消 / 重试 / 移除；多 Mac 切换。
- **验收**：帧契约 + 模拟器。

**24. API 账号生命周期与安全**
- **现状依据**：logout 不调服务端（refresh token 14 天有效）；改密不吊销其它会话；
  撤销设备后 access token 最长 2 小时仍有效；无忘记密码；无审计。
- **增量**：logout / 改密吊销；token 版本即时撤销；忘记密码（恢复码路径）；审计事件。
- **验收**：cargo test（吊销 / 改密 / 恢复）。

**25. API 配额 / 存储 / TTL-GC**
- **增量**：原子配额（读后写 → 条件更新 / Redis）；按用户存储上限；带档案后缀的域走
  历史 TTL 与 GC（S8）；游标数量上限与过期。
- **验收**：cargo test + 本地 E2E（`history@<uuid>` 被 TTL / GC 清理）。

**26. API 可观测 / 中继加固 / 运维**
- **现状依据**：metrics 5 个序列无直方图；无审计日志；访问日志无 user id；WS 不重验证、
  无每用户上限；单会话密钥；at-most-once 投递；`x-forwarded-for` 可伪造；限流单实例；
  demo PII / `growth_events` / `sync_usage` 不修剪；admin 无 `user create`。
- **增量**：直方图 / 连接池 / WS gauge；审计日志；WS 重验证 + 每配对密钥 + ack；
  trusted proxy + Redis 限流；修剪任务；admin 补 `user create` / 用量 / 审计。
- **验收**：cargo test + 本地压测。

## 批次

1. **浏览器旗舰**：1 权限与隐私中心 → 2 密码面板 → 3 自动填充 → 6 下载续传。
2. **浏览器补件**：4 标签/阅读 → 5 媒体 → 14 OCR 翻译。
3. **Agent 旗舰**：7 提示词缓存 → 8 成本路由 → 9 审批批处理 → 10 自评修订。
4. **跨端掌控**：22 传输修复（P0，先做——11/12/13 都依赖它）→ 11 Remote 批次 → 12 实时标签 →
   13 体检/同步 → 23 下载记录/多 Mac。
5. **替人干活 + 翻译收口**：15 任务链 → 16 定时窗口 → 17 翻译收口（S1 先修）。
6. **可靠性收口**：18 存储 GC → 19 锁屏 → 20 预算/转存 → 21 校准/Doctor/导出。
7. **API 运营面**：24 → 25 → 26。
8. 收口：i18n 三语 / AGENTS / WhatsNew / 本版特性探针 / 190 里程碑（改了权限、Remote 通道、
   Agent 回合循环，按规矩跑全量）。

## 不做

passkey / WebAuthn（等 Apple 审批，见 `docs/PASSKEYS-APPLE-REQUEST.md`）、Safe Browsing
（外部列表与密钥，下一版评估）、Chrome 应用商店安装、工具栏自定义、OTLP 导出、Android Remote、
第三方翻译引擎、语义级记忆冲突（embedding）、网络节流 / pixelRatio、对话跨设备同步。

## 风险

- **WKWebView 权限能力边界**：通知 / 剪贴板读取可能没有系统提示 API——先探针，支持不了的
  如实标注，不做假开关（与"响应式模式勿做假 UI"同一条纪律）。
- **HIBP 隐私**：k-匿名（5 位前缀）+ opt-in；假端点断言只发前缀。
- **提示词缓存各家口径不一**：按 provider 解析，未知字段不显示，不估算冒充。
- **审批批处理的安全面**：只批同类工具、参数模式、留审计、危险工具不批。
- **自动修订成本**：一次上限 + 成本上限，用户可见。
- **Remote 真机联调依赖用户在场**；API 变更需要部署迁移（服务端部署由用户执行）。
- **浏览器权限 / Remote 通道 / Agent 回合循环属核心路径**：本版发版前跑一次 190 全量。

## 批 1 进展（2026-11-27）

- **权限与隐私中心**：权限类型扩展（弹窗 / 剪贴板读取）、锁弹层三态编辑、清除本站数据、
  清除数据时间范围、严格 HTTPS-only。探针结论：WKWebView 的 `Notification.requestPermission()`
  恒返回 denied（无系统提示 API）→ 面板如实标"不支持"；剪贴板无权限 API，只能按站点注入脚本
  拦截（didCommit 注入，晚于页面首屏会被无手势 readText 卡住 WebContent）。
- **顺带修掉两个真缺陷**：① HTTPS 升级代码被 beforeunload 守卫的 early-return 挡成不可达
  （升级与严格模式从未执行）；② 浏览器缺 `NSAllowsArbitraryLoadsInWebContent`，非 localhost
  的 http 页面被 ATS 拒掉。
- **密码面板**：手动增改删、健康卡、HIBP k-匿名泄露检查（假端点断言只收到 5 位前缀）、
  同键去重。
- **自动填充**：多档案（新建/存库/载入 + 弹层菜单）。支付卡/提交时保存暂缓（见上）。
- **下载续传**：URLSession resumeData 落盘（`<dataDir>/download-resume/`），重启后可续；
  服务器需 Range + ETag/Last-Modified。暂停时的取消错误不再把行判失败。
- **验收**：`permissions-e2e` 21/21、`password-autofill-e2e` 16/16、`download-resume-e2e` 12/12；
  harness 3998；Debug 零警告。

**批 2 进展（2026-11-27）**：标签组创建后重色（右键 Color 子菜单）+ 拖标签到折叠组胶囊入组；
站点级静音（锁弹层开关 + 页面加载自动应用）；Media 菜单（全部静音/取消/跳到播放标签）；
截图 OCR 翻译（旁路档案流式 + `POST /translate/text`）。验收：`browser-batch2-e2e` 14/14。
**暂缓**：整词查找（WebKit find 无该模式，自绘高亮需改 DOM）、纯文本缩放（无公开 API）、
支付卡/提交时保存（需要独立加密存储）。

**批 3 进展（2026-11-27）**：提示词缓存三家计量（OpenAI `prompt_tokens_details.cached_tokens` /
DeepSeek `prompt_cache_hit_tokens` / Anthropic `cache_read_input_tokens`）随消息落盘、统计页
与 `/agent/stats` 给命中率；Anthropic 在 system 与最后一个工具上加 `cache_control`
断点（按模型白名单）。成本/延迟**建议式**路由：`RoutingAdviceEngine`（纯逻辑）+ 统计页
"Routing advice" 卡 + `GET /ai/routing/advice`，价格未知不比较、样本 <3 不谈延迟，只建议
不切换。审批批处理：`ApprovalBatchPattern`（工具 + 站点 + 顶层参数键集合）驱动
"本轮剩余同类都允许"，危险级不进批；待批快照随会话落盘（`Conversation.pendingApproval`），
重启后 `POST /agent/open` → recovered 卡 → 允许/拒绝并续跑被打断的回合（同形状调用自动放行）。
自评后修订：`AnswerRevision` 只在"机械核验结论或失败/被拒调用"存在且评语未说"未发现问题"时
跑一次无工具修订，答案失控变长则丢弃；面板显示"修订中"、消息标 `wasRevised`、用量
`kind=revision`。
- **验收**：`prompt-cache-e2e` 8/8（假 OpenAI + 假 Anthropic 请求体断点与用量落盘）、
  `agent-batch3-e2e` 12/12（建议不改模型、批量批准只弹一次卡、自评→修订终答）、
  `approval-recovery-e2e` 12/12（quit → 重启 → recovered → 续跑）；harness 4024；
  Debug 零警告。
