# v0.8.60 规划稿（2026-11-15）—— 自校准与值守：Agent 上下文真值化 + 自主处置闭环

> **主题叙事**：上一版（0.8.59）让 Agent 的上下文"自治理"（压缩/转存/看门狗），
> 但治理的标尺还是**字符盲猜**；让 Agent 的值守"会汇报"，但汇报之后**人不来就
> 停**。本版把这两件事做完：①上下文预算从字符口径升级为 **token 真值**（每模型
> 校准）；②后台值守从"汇报"升级为**自主处置**（异常 → 唤醒会话 → 受约束处置
> → 回报）。③记忆检索加入使用反馈闭环。规划前核实过：跨会话语义检索已存在
> （searchConversations mode=semantic + readConversation）；watch 已有
> notify/resume 两档与条件触发面（JobWatchCondition）；档案无窗口字段、请求
> 字符数未落盘——为真空白。

## 四主题

### ① Agent 基础（旗舰）= 上下文预算 token 真值化
- **档案级窗口**：`AIProviderProfile.contextWindowTokens: Int?`（nil = 按模型名
  前缀默认表：gpt-* → 128k、claude-* → 200k、deepseek-* → 64k、qwen* → 128k、
  gemini-* → 1M、本地/未知 → 32k 保守值）；设置页档案编辑器加"上下文窗口
  (tokens)"行（留空 = 用默认表）。
- **校准数据落盘**：`assembleRequestMessages` 返回请求字符数 → 会话内存记
  `lastRequestChars`；回合的 `promptTokens`（已有）与之配对 → 每模型滚动样本。
- **TokenCalibrator**（Foundation-only，进 harness）：每模型 EMA 比率
  （chars/token，夹逼 1.5–6），持久 `AgentPreferenceStore.modelCalibration`；
  预算换算 `budgetChars = min(160k, windowTokens ÷ ratio × 0.9)`。
- **消费端接线**：芯片 contextFraction 改 token 口径（估算字符 ÷ 比率 ÷ 窗口，
  无校准样本或样本 <3 条的模型回退字符口径——灰度安全）；回合末自动压缩条件
  与 `compactWithDigest` budget 换算同源。spill 阈值维持字符口径。
- **测试**：比率收敛/夹逼/窗口覆盖/灰度回退/芯片口径切换（纯逻辑全测）。

### ② Agent 基础 = 值守从"汇报"升级为"处置"
- `JobWatch.Mode` 增 `.handle`：异常条件触发 → owner 会话空闲 → 自动发**处置
  回合**（模板 = 任务状态 + 失败/卡死明细 + "按你的判断处置并简报"），处置动作
  全部走既有 guard pass / 审批策略 / 无人值守超时语义；处置后按结果分级通知。
- 条件语义补两 kind（通用）：`failureRate`（批内失败率阈值）、`stalled`（无进度
  时长阈值）——JobWatchCore 进 harness 的判定逻辑扩展。
- 五套守望收口：pageWatch / heartbeat / scheduled / crew 的异常统一走
  JobWatchCondition 触发面（复用 firedConditionKinds 限频，不强改存储）。
- UI：JobsPanel 的 Watching 行加 mode 选择（通知/汇报/处置）。
- **测试**：条件判定纯逻辑扩展 + `.handle` 触发面（会话空闲判定/模板组装）。

### ③ Agent 基础 = 记忆使用反馈闭环
- `AgentMemoryStore.promptBlock` 返回 `(block, factIDs)`（调用点：主循环/子代理
  两处）。
- 回合末：回合成功（无 fail 标记/无点踩）→ 注入过的 facts `recordUsage`
  （usage+1、lastUsedAt）；点踩回合 → 弱化计数。
- 检索：BM25/向量得分 × `(1 + 0.1·ln(1+usage))`；`/memory/decay` 整合 usage
  （长期未用且零反馈的衰减更快）。
- **测试**：UsageBoost 评分（纯逻辑）+ 注入-反馈链路。
- 门槛：`memoryLearning` 开关沿用。

### ④ 浏览器基础（工程）= 评估回归产品化
- v0.8.59 的四探针产品化进 `tests/agent-eval.py`：E22 自动压缩 / E23 转存+
  全文检索 / E24 看门狗（30s 档）/ E25 Doctor——fixture 复用
  `~/Documents/DesireAgent/v0859_probes/`。
- release-smoke 可选档 `--with-agent-probes` 接线（CI 仍只跑桥纯接口用例）。
- AGENTS.md 更新：stallSeconds 需重启生效的实测、探针脚本位置。

## 批次

批 1 token 真值化（窗口表 → 校准器 → 三消费端）→ 批 2 值守处置（条件 kinds →
.handle → UI）→ 批 3 记忆反馈（签名变更 → 回合末钩子 → 检索加权）→ 批 4
评估回归 + 收口（AGENTS/i18n/WhatsNew）。

## 不做

动态成本路由（按任务复杂度换主模型）；技能全自动沉淀（维持手动提炼）；跨设备
记忆同步；多代理协作协议扩展；MCP 新能力；passkey。

## 风险与依赖

- **token 校准改预算语义**：灰度设计（样本 <3 回退字符口径）；`compactionBudgetOverride`
  （超限重试/空响应重试写）优先级高于校准值——语义为"按这家服务的真实窗口校准"。
- **.handle 无人值守处置的安全面**：处置回合与主回合同走 guard pass + 审批
  （无人值守审批超时语义 0.8.58 已修）；限频靠 firedConditionKinds。
- **promptBlock 签名变更**触及两调用点 + bypass 路径——编译器兜全。
- 依赖 0.8.59 的：estimatedSentTotal / compactNow / ToolResultSpill / 看门狗
  （本版全部在其上叠加，不改其语义）。
