# DPP 设计评审（2026-10-11）

> 范围：`docs/DPP-PROTOCOL.md` v1.1、`Features/Agent/PageProtocol/`、审批闸门
> （`AgentSessionStore.effectiveRisk`/`gate`、`DPPActionApprovals`）、适配包链路
> （`DPPAdapterStore`、`docs/dpp-adapters/`）、事件系统（`PageEventHub`）。
> 性质：设计层建议，未实施；按优先级排列，文件:行号对应评审当日代码。

## 总体判断

四根柱子是对的，保持不回退：

1. **分层采用（L0–L3）**——零改造起步、声明多少用多少，接入成本梯度合理；
2. **声明 ≠ 授权**——协议声明能力，授权始终在用户（三段信任模型 §7）；
3. **容错解码**——单字段失败只丢该字段 + warnings，不整份失败；
4. **求值隔离**——Agent 工具求值在 `desireAgentTools` 隔离世界，页面猴补不可达。

适配包"纯 JSON、零代码、不引入新执行面"的定位也克制，审批链照常生效是正确选择。

---

## P0 — 安全边界

### 1. 风险分级是"页面自评"的，闸门信任了不可信输入

`AgentSessionStore.effectiveRisk`（AgentSessionStore.swift:2866）按页面自己声明的
`effects`/`danger` 升档——但恶意页面只要**不标** outbound/danger，动作就是 base 档，
autoEdit 档下静默放行（`run` 步骤真实执行）。页面对自己动作的分级是不可信输入。

建议两层加固（可独立实施）：

- **静态步骏述算风险下限**：`run` 里有 `navigate` 步骤、click 命中
  `[type=submit]`、`pressKey: Enter` 在表单上下文中 → 无论声明什么，至少升
  sideEffect/danger。声明可以撒谎，步骤语义撒不了。
- **执行后观测回写**：动作执行完若顶层导航发生 / 出现 POST / `window.open`，
  把该 (host, action) 记入"观测到不可逆"名单，下次自动升级风险档。观测比自评可信。

### 2. 跨源 frame 的审批授权没有算来源

审批卡会亮出 frame host（`pendingApprovalSourceFrameHost`，AgentSessionStore.swift:116），
但 `DPPActionApprovals` 的授权键是 `(页面host, 动作名)`——用户为**第三方 iframe
声明的动作**点"本站始终允许"，授权记在页面 host 上，之后同名的页面动作（或反向
场景）一起被放行。

修复：授权键拼入 `sourceFrame` host（有值时），与审批卡展示的来源一致。

### 3. 适配包是供应链面，目前最松

`DPPAdapterStore.installFromURL`（DPPAdapterStore.swift:105）：

- 注释写"http 不落地（协议降级拒收）"，但代码 `url.scheme == "http"` 照收——
  注释与实现矛盾，应择一改正（建议 https-only）；
- 同名**静默覆盖**，无 diff——被投毒的 raw 链接可以悄悄换掉既有包；
- 无版本、无校验和、无来源记录。

适配包控制一个 host 的选择器与动作 = 完整的钓鱼面（声明看似 local 的动作指向
伪装元素）。建议：https-only、更新时展示变更 diff、落盘记录 source URL 与
`lastVerified` 日期、设置页对陈旧包亮提示。

---

## P1 — 协议设计

### 4. `run` 存成字符串 + 字符串嗅探，两套解析口径

`ProtocolAction.run: String?`（DesireProtocol.swift:211）导致：

- 风险判断靠 `run?.contains("\"mcp\"")` 子串匹配（AgentSessionStore.swift:2891）——
  脆弱（依赖 JSON 序列化形态），且与 `isBridgeSafeLocal`（真解析步骤数组，
  DesireProtocol.swift:217）两套口径；
- 未支持的步骤操作要到执行时才失败，解码时就能预警。

建议：解码时一次性解析成类型化 `[RunStep]`（保留 raw 字符串用于展示/回写），
风险 / 桥安全 / 执行器全读同一结构；未知步骤操作进 warnings（符合容错解码第一原则）。

### 5. events 的 `debounce` 声明了但被丢弃

解码把 events 扁平成 `[String: String]`（DesireProtocol.swift:46），warning 文案写
"debounce/on 由宿主事件层统一处理"——但宿主实际用的是固定 3s（PageEventPolicy），
声明值根本没读。规范 §4.5 与实现不一致。

建议：要么实现 per-event debounce（events 值改为结构化），要么规范标注该字段
deprecated、warning 文案改诚实。另外规范 §7.1 架构图写 MutationObserver、实现
注释写 Timer 轮询——文档与实现要对齐一处。

### 6. `context` 是页面直达 Agent 的提示词通道

`context.persona/rules` 随 page_context 注入（"reference, not instruction" 前缀已做），
但这是 DPP 里唯一"页面文本进 system 层"的路径，值得最保守对待：

- 硬性长度上限（防挤占上下文）；
- 按 host 的 context 注入开关（用户可整体关闭某站的语义注入）；
- 注入处始终带 host 徽标（模型与用户都能看见来源）。

### 7. 小问题

- `DesireProtocol.merged` 里 `if page != nil || true` 恒真（DesireProtocol.swift:69）
  ——死逻辑；frames 合并应拆成独立函数（现在塞在 merged 的 site/page 分支前）。
- 规范 chat profile 示例里 `open-conversation` 有**重复的 `run` 键**
  （DPP-PROTOCOL.md §5 chat profile）——JSON 重复键后者静默胜出，示例本身误导接入方。
- `isBridgeSafeLocal` 里 `effects == "danger"` 的分支：`danger` 是独立布尔字段，
  effects 枚举没有 "danger" 值——死分支，可删。

---

## P2 — 生态与工程

### 8. 适配包会腐烂，需要存活度机制

9 个包全部手工对真实 DOM 核对，站点改版即静默失效（views 抽空、动作点空）。
建议：

- 包内 `lastVerified` 字段 + 设置页陈旧提示；
- 收集 pageAction/pageExtract 失败率，连续失败自动建议禁用；
- 或桥加 `POST /dpp/adapters/verify`：对当前打开的匹配标签页跑一次真抽取核对。

### 9. 规范与实现状态分离

`DPP-PROTOCOL.md`（728 行）= normative 规范 + 实现状态日志 + E2E 结果表的混合体。
既然设计原则 P5 是"开放规范、任何 Agent 可消费"，建议拆：

- 规范：纯 normative、带版本、发布在产品页（对齐 §10 三期"公开托管"项）；
- 实现状态/E2E：挪去单独文档或 CHANGELOG 引用。

E2E 表里两个 ⬜（事件驱动真机验证、chat profile 事件驱动回合）应补掉再宣布 v1.1 完整。

### 10. `pageExtract` 要有显式截断契约

`all=true` 翻页/滚动收集建议带上限，返回
`{"items": [...], "truncated": true, "moreAvailable": N}`——否则长列表吃穿上下文，
且模型不知道还有更多、无法决定是否继续。

### 11. pageAction 成功时返回轻量事后证据

目前成功判定 = `success` 文本 / signals。建议成功时顺带返回相关 view 的前几条
（事后快照），Agent 一个回合内自验证，省一轮 pageExtract。与"工具失败统一
`Error:` 前缀"的既有约定互补：成功也要有可核验的形态。

---

## 建议实施顺序

| 顺序 | 项 | 理由 |
|---|---|---|
| 1 | #1 静态步骏述风险下限 | 小改动，堵最真实的绕过面（autoEdit 静默执行未标注 outbound 的动作） |
| 2 | #2 授权键带 frame host | 小改动，跨源 frame 上线后授权模型必须闭环 |
| 3 | #3 适配包 https-only + diff + 来源记录 | 供应链面收口，趁包还少 |
| 4 | #4 run 类型化解析 | 消灭字符串嗅探，统一三处消费口径 |
| 5 | #5/#7 文档-实现对齐 | 成本最低的诚实性修复 |
| 6 | #8–#11 生态与工程 | 随社区包增长逐步补 |

#6（context 加固）视隐私取向可提前；与 #1 同批做也不重叠。
