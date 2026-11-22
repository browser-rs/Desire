# v0.8.73 规划稿（2026-11-22）—— 吃一堑长一智：失败学习与记忆治理（Agent 基础旗舰）

> **背景**：0.8.71 补了上下文的读侧（压缩/真值），0.8.72 补了写侧（工作记忆/
> 技能闭环）——但智能体仍然"不长记性"：**失败回合的证据只展示不学习**（机械
> 核验/点踩/自评产出后没有动作），记忆**只进不出**（没有治理 pass），技能连败
> 没有"重新蒸馏"的具体入口。本版把学习闭环的后半段收口：失败 → 教训 → 注入
> → 不再犯。
>
> **设计依据**：2026 智能体共识——self-correction（错误反馈回灌）是 Agent
> 可靠性最大的杠杆之一；长期记忆的标配是治理（consolidation）——ReMe 式
> "记忆成为可读文档"已有渲染面（MemoryKB），缺的是整理动作。

## 规划前核实（2026-11-22，防误立）

- **机械核验只展示不学习**：`runMechanicalVerification` 产出 verificationNote
  （判定口径 = `Error:` / `[User denied` 两个客观标记，零模型），写进消息后面
  板提示——没有任何下游学习动作。
- **点踩只记一条裸 fact**：`learnFromDislike` → `addFact("User dislikes: X",
  category: "feedback")` + 弱化注入记忆。失败回合本身不产教训；feedback 与
  correction 两类负反馈没有统一出口。
- **crew worker 无记忆/技能注入**：固定 system + 工具子集（`workerToolNames`
  过滤），leader 的记忆与技能对 worker 不可见。
- **记忆无治理 pass**：200 上限 + near-dup 去重（≥0.8）+ decay 加权已有；
  批量合并/陈旧退役/体检报告没有。冲突复核队列（pendingConflicts）与
  keepNew/keepOld 语义已在。
- **SkillUsage 无会话映射**（0.8.72 定案的字段面只有 count/lastUsedAt/
  outcomes）——连败技能的"重新蒸馏"没有具体入口。
- **已有不复做**：critique 自评、recallConversation、MemoryKB 渲染、usage
  追踪、候选收件箱（0.8.72）、`/compact` 全家（0.8.71）。

## 旗舰 A：教训记忆（失败回合 → 教训 → 注入防重复）

- **触发（收紧，防噪音）**：回合结束且**有客观失败证据**——verificationNote
  非空（全败/被拒）或 turnFailed。不凭关键词猜（沿用机械核验的判定纪律）。
- **提取**：旁路一次调用（走 fallbackPreferences，无 fallback 跳过——0.8.72
  的既有语义），输入 = 本回合用户目标 + 失败工具签名/错误行 + verificationNote，
  提示词要求"只在能明确归因时输出"≤200 字符教训（category=**correction**，
  source=**lesson**）：以后遇到同类任务应该怎么办/避免什么。12s 竞速 + 失败
  静默（不阻塞收尾）；用量入账（kind=lesson）。
- **治理**：去重走既有 areNearDuplicates；**节流**（每会话 ≤2 条/天、全局
  ≤6 条/天，复用候选节流模式）；记忆页来源徽标 lesson（0.8.72 的 source
  徽标机制延续）。
- **注入加权**：correction 在检索排序中优先级提升（不进 pinned——置顶仍是
  用户特权），命中即靠前。
- **👎 打通**：用户点踩原因改走同一教训管道（结构化 correction，不再裸
  feedback fact）——两类负反馈同一出口、同一注入待遇。

## 旗舰 B：记忆体检（consolidation pass）

- **入口**：`/memory-checkup` slash + 桥 `POST /memory/checkup` + 记忆页按钮。
  **手动触发，不周期化**（先观察报告质量再谈自动）。
- **动作**（判定纯逻辑进 harness）：
  ① **近重复合并**：areNearDuplicates 以 **≥0.9 严阈值**（比注入去重的 0.8
  严）聚簇 → 每簇合成一条（保留最新 + 来源最硬的：lesson > correction >
  手动 > 自动）→ 被合并原文**先导出归档**（MemoryKB 伴生文件，不丢原文）。
  ② **陈旧退役**：>60 天未用且 usageCount=0 且非 pinned → 移出注入池，
  保留在 KB 导出（退役 ≠ 删除）。
  ③ **冲突清账**：pendingConflicts 逐条列出 + 一键处置（keepNew/keepOld/
  merge 既有语义）。
- **产出**：体检报告（总条数/合并簇数/退役数/待审冲突数）——面板展示 +
  会话外备注（模型知道记忆被整理过）。

## 旗舰 C：技能重蒸馏收口（0.8.72 B3 遗留）

- `SkillUsage` 加 `lastUsedConversationId`（useSkill 时由 provider 从
  ownerSession 回填）。
- 连败技能卡上"重新蒸馏"按钮 → 定位该会话 → SkillDistiller 起草 → 走
  0.8.72 候选流 → 采纳时**同名覆盖 + 旧版备份**（`skills/.archive/<name>-
  <日期>.md`），回执注明"已更新（旧版已备份）"。会话已清理 → 按钮置灰。

## 小件

- crew worker 注入 top-K 记忆事实 + 技能清单（worker 预算 8 调用不变；
  用量面板观察 token 影响）。
- `/memory-checkup` slash 命令（22 → 23，known.count 单测同步改）。

## 四主题

### ① 浏览器基础 = 真实使用反馈修复
- 0.8.62-72 的浏览器面继续使用期——反馈到达即修。

### ② Agent 基础（旗舰）= 学习闭环收口（A/B/C，见上）

### ③ 融合 = Remote 真机验收跟进
- 0.8.70 攒的四项（发图 / Handoff 路由 / Siri / 扫码）真机验收（用户参与）；
  0.8.72 新面（技能候选/健康、工作记忆）在 Remote 快照的可见性适配。

### ④ 替人干活 = 运营收账
- 产品页 0.8.71-73 扩充部署（手工）；服务端 desire-admin 部署提醒。

### 工程（贯穿：可靠性 / 可发现性）
- 教训防重复犯（可靠性）+ 体检报告/来源徽标/重蒸馏入口（可发现性）；
- harness：教训触发判定/节流、体检合并聚簇/退役/报告统计、重蒸馏会话映射——
  纯逻辑进 run.sh；
- 190 全量回归（fresh 实例）+ i18n 四语 + smoke + Release 零警告 + CI 例行。

## 批次

批 1 = 旗舰 A（教训记忆）→ 批 2 = 旗舰 B（记忆体检）→ 批 3 = 旗舰 C +
小件 → 批 4 = 190 + i18n/WhatsNew + smoke → 发版。

## 不做

Crew 架构重写（维持否决）；记忆图谱 UI；评估集自动入 CI；**体检周期化自动跑**
（先手动观察）；Android / iOS Watch；向量记忆重推（bge 已在）；AGUI/前端流式
协议类新标准；浏览器内代理/节流/第三方翻译（既有否决维持）。

## 风险

- **教训噪音**（偶发失败固化成错误教训）：触发只认客观证据 + 提取提示词
  "只在能明确归因时输出" + 双层节流 + 记忆页可删；注入命中率有 usage 真值
  可观察。
- **体检误合并**：0.9 严阈值 + 原文导出兜底 + 报告逐簇可回溯。
- **重蒸馏的会话已清理**：按钮置灰（usage 映射只为定位，不新建依赖）。
- **crew 注入 token 膨胀**：worker 预算 8 调用不变，用量面板观察；事实注入
  复用 promptBlock 的 top-K 口径（不是全量）。
