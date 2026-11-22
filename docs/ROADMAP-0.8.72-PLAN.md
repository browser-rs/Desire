# v0.8.72 规划稿（2026-11-22）—— 智能体自我升级：工作记忆 + 技能闭环（Agent 基础旗舰）

> **背景**：0.8.71 重构了上下文管线（压缩不丢数据、真值占用），但智能体
> "越用越懂你"的**写入侧**仍是缺口——本版把智能体本身当产品对象：
> 它能不能自己记住东西、自己沉淀技能、自己知道哪条记忆/技能好用。
>
> **设计依据**：Anthropic 工程（2025-12）公开数据——context editing 与
> memory tool 组合 +39%（0.8.71 已交付前一半的"编辑"，本版补"记忆工具"
> 后一半）；ReMe 式"记忆成为可读文档"已在 MemoryKB 落了一半。

## 规划前核实（2026-11-22，防误立）

- **`remember` 类记忆写入工具不存在**（293 个工具签名逐一核过）——记忆
  目前只有三条写入路：自动提取（回合收尾、≥4 条新消息门槛）、桥/面板手动、
  同步。**智能体本人在任务中想记东西时没有工具**。
- **记忆按需查询工具不存在**——`recallConversation` 只查会话历史与归档；
  记忆库只有 promptBlock 自动注入 top-12，模型无法主动"查全库"。
- **MemoryStore API 全齐**：`addFact(content/category/scope/source)`、
  `recordUsage/recordNegative`（注入事实的反馈闭环）、`promptBlock`、
  `rankWithVectors`（向量主排）——缺的只是工具层。
- **技能蒸馏是手动的、单次的**：`SkillDistiller` 只在用户显式触发时跑
  （面板菜单/桥），无自动候选、无使用追踪（`Skill` struct 无
  usage/version 字段）、无成功率评估。
- **已有不复做**：工具级续跑（TurnCheckpoint，0.8.25）、会话接力
  （Remote 镜像）、反思 critic、轨迹、Doctor、旁路用量入账
  （attributeBypassUsage）、记忆去重（bigram ≥0.8）、技能 vars、
  端上模型（FoundationModelsProvider）。

## 旗舰 A：工作记忆工具（智能体自己写、自己查）

- **`remember(fact, category?, scope?)`**：任务中显式保存长期值得记住的
  偏好/事实。实现 = `AgentMemoryStore.addFact` 直连，`source: "agent-tool"`
  （面板记忆页来源可见——MemoryFact.source 字段已在）；既有去重
  （normalizeFact/areNearDuplicates）自动生效。
  - **限次**：每回合 ≤5 次（防刷屏）；**pin 不开放**（置顶是用户特权）。
  - 提示词层：memory 段落加一句使用指导——"只记用户明确表达的偏好与
    事实，不记推断"；工具索引从 toolDefs 自动生成，无需手改。
- **`recallMemory(query, scope?)`**：按需查记忆库（rankWithVectors 向量
  主排 + BM25 兜底，同一套口径），返回 top-N 条含 category/scope/source。
  与 promptBlock 自动注入互补：注入管"大概率相关"，recall 管"我确认
  要查"。
- **反馈闭环补全**：remember 写入的事实同样进 usage 追踪（注入→
  recordUsage 已有）；👍 回合引用过的 agent-tool 事实加权（既有链路）。
- **治理**：来源徽标露出（记忆页 agent-tool / 自动提取 / 手动三种）；
  批量清理入口已有则复用。

## 旗舰 B：技能闭环 2.0（会用 → 会沉淀 → 会淘汰）

- **B1 自动候选**：回合干净结束 + 工具步骤链 ≥6 步 + 无失败标记 →
  后台旁路蒸馏候选技能（`SkillDistiller.draft` 复用，候选**不进正式
  技能库**）→ 面板菜单/收件条提示"本次任务可提炼技能？"→ 用户一键
  采纳（写入技能库）或忽略（候选 7 天过期）。
  - **节流**：每会话最多 1 次候选；全局 24h 滚动上限（防旁路烧钱）；
    失败/取消回合绝不触发（沿用"不静默存烂技能"原则）。
  - 候选存储：独立小 Store（候选 id/草稿/时间/来源会话）。
- **B2 使用追踪**：`Skill` 增量字段 usageCount/lastUsedAt（UserDefaults
  meta，同 sourceMeta 模式）；判定口径 = 回合轨迹中出现该技能的
  runSkill 调用（诚实口径：注入 ≠ 使用）。
- **B3 技能评估**：按技能聚合"使用 → 回合结果（成功/失败/
  verificationNote）"→ 技能库页显示成功率与最近使用；连续失败的技能
  提示"重新蒸馏或退役"。**样本 <5 只显示"样本不足"，不判失败**。
  - 重新蒸馏 = 对最近一次使用该技能的会话再跑 SkillDistiller，新草稿
    走 B1 候选流（用户确认后覆盖，版本 +1）。

## 四主题

### ① 浏览器基础 = 真实使用反馈修复
- 0.8.62-71 的浏览器面继续使用期——反馈到达即修。

### ② Agent 基础（旗舰）= 智能体自我升级（见上）
- A 工作记忆 + B 技能闭环；体检/Doctor/轨迹既有面反馈预留。

### ③ 融合 = Remote 真机验收闭环
- 0.8.70 攒的四项（发图 / Handoff 路由归属 / Siri 短语 / 扫码授权）
  真机验收（用户参与），暴露问题进本版修复。

### ④ 替人干活 = 运营收账
- 产品页 0.8.71-72 扩充 + 部署（发版手工活）；服务端 desire-admin
  部署提醒。

### 工程（贯穿：可靠性 / 可发现性）
- 技能评估（可靠性）与自动候选浮出（可发现性）即两条贯穿的落地；
- 分层压缩纯逻辑单测已在 harness（0.8.71 交付），本版新增：remember
  参数校验/去重、候选节流判定、技能成功率聚合——纯逻辑进 harness；
- 190 全量回归（发版前）+ i18n 四语 + smoke + Release 零警告 + CI 例行。

## 批次

批 1 = 旗舰 A（remember/recallMemory + 治理）→ 批 2 = B1/B2（自动候选
+ 使用追踪）→ 批 3 = B3（评估）+ 小件收口 → 批 4 = 190 + i18n/WhatsNew
+ smoke → 发版 → Remote 四项真机验收（用户）。

## 不做

Crew 架构重写（planner-executor-verifier 全面重做——现有 crew 未证伪，
改动面不成比例）；记忆图谱 UI（MemoryKB 链接渲染已够）；评估集自动入
CI（agent-eval 手动已够）；Android；iOS Watch；向量记忆重推（bge 已在）；
AGUI/前端流式协议类新标准；浏览器内代理/节流/第三方翻译（既有否决维持）。

## 风险

- **remember 噪音**（模型乱记）：限次 + 既有去重 + source 标记 + 提示词
  指导 + 面板全可见可删；观察一周注入命中率（usage 追踪有真值）。
- **自动候选烧旁路**：节流两层（会话 1 次 / 全局 24h 上限）+ 失败回合
  不触发 + 用量入账可查。
- **技能评估样本稀疏**：只提示不硬闸；<5 样本如实标注。
- **隐私边界**：remember 内容全部进既有记忆面板（可见/可删/可同步——
  agent-memory 域已有），无新存储面。
