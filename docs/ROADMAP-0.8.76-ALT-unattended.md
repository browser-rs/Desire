# v0.8.76 规划稿（2026-11-23）—— 无人值守：定时任务自己会处置（替人干活旗舰）

> **背景**：智能体五连（0.8.71-75）把"坐在旁边看"的体验打磨完了；本版解决
> "**没人看**"的场景——定时任务/后台值守回合碰到审批卡、失败、停摆时的
> 自主处置。这是 0.8.60「自校准与值守」规划里唯一未实施的核心，也是"替人
> 干活"主题的收官件：**任务能在没人时跑完，才算真的替人干活**。
>
> **场景锚点**：夜间批量下载、晨间简报、定时盯梢——到点触发后如果弹出
> 审批卡，任务就卡死在无人看见的屏幕上直到天亮（0.8.60 规划时的原痛点）。

## 规划前核实（2026-11-23，防误立）

- **调度器已有**：recurrence（minutes/daily/weekly）、任务链（chainTo）、
  夜间窗口顺延（deferInQuietHours）、RunRecord 历史（delivered/queued/
  missed/success/failed + attempts + **一次重试**）、jobTemplate 后台命令、
  builtin 流水线（weeklyReport）、targetSessionID 多窗口。
- **审批已有**：ApprovalPolicy（工具×站点 allow/deny，审批卡"Always on
  site"写入）、访问等级三档（confirm/auto/full）、guard pass（autoEdit
  副作用旁路复查 fail-open）。
- **缺的**：① 审批卡在无人值守回合的行为 = **永远挂起**（无超时处置）；
  ② 失败只有一次重试，无"连续失败自动暂停任务"（坏任务每天失败一次刷
  屏通知）；③ RunRecord 只有 lastResult 一行，无 failureRate 聚合；
  ④ 值守回合的完成通知走 routine 会被免打扰扣掉（设计如此），但**失败**
  也走 routine——夜间失败没人知道，早上也没有摘要。
- **已有不复做**：guard pass、心跳巡检（HEARTBEAT_OK 抑制）、通知分级、
  预算门控、检查点续跑、无人值守重试一次。

## 旗舰 A：无人值守审批处置档（.handle）

- **触发面**：`deliverScheduled` 起的回合 = 无人值守回合（SessionStore 打
  `isUnattended` 标志；手动回合不受影响）。
- **处置档**（每任务可选，默认 `timeoutQueue`）：
  - `timeoutQueue`：审批卡等 N 分钟（默认 10）→ 无人应答自动**拒绝**该
    工具（模型收到 denied 可换路），回合继续——不卡死、不静默放行。
  - `autoAllowReadonly`：只读工具直接放行、副作用工具走 timeoutQueue
    （夜间批量下载的推荐档：navigate/read/extract 放行，download 类仍看
    得见）。
  - `fullAuto`：全部按 autoEdit 同款闸门放行（副作用动作仍过 guard pass
    复查——fail-open 语义保留），**任务级显式授权**，设置页明示风险。
- **落地**：AgentSessionStore.askUser/审批 continuation 挂 deadline；
  Task 任务模型加 `handle: String?`（旧文件缺键 = timeoutQueue 默认）；
  设置页任务行内可直接切档。
- **审计**：timeout 拒绝走既有 denied 轨迹（threwError/denied 已在），
  RunRecord 备注超时拒绝数。

## 旗舰 B：失败处置与聚合读数

- **连续失败自动暂停**：同一任务连续 N 次（默认 3）失败 → 任务自动
  `isEnabled = false` + urgent 通知（"任务 X 连续失败已暂停"）——坏任务
  不再每天失败一次刷屏，用户知情后手动恢复。
- **failureRate 聚合**：RunRecord 已持久化 → 按任务聚合最近 14 天成功率，
  设置页任务行显示（样本 <3 显示"样本不足"——沿用量化纪律）。
- **失败通知升级**：任务失败走 **urgent** 直推（routine 夜间被扣 = 早上
  才看见）；成功维持 routine。
- **晨间摘要**（可选，默认关）：夜间被扣的值守通知在免打扰结束时由既有
  flushDigest 合并补推——核对现有摘要是否已覆盖任务失败行，缺则补一行
  "夜间任务：X 成功 / Y 失败"。

## 小件

- RunRecord 列表进设置页任务详情（最近 10 次时间/状态/耗时——现在只有
  lastResult 一行文本）。
- `/tasks` slash 输出补 failureRate 与 handle 档位（远程同路）。

## 四主题

### ① 浏览器基础 = 真实使用反馈修复
- 反馈到达即修。

### ② Agent 基础 = 无人值守处置（旗舰，见上）

### ③ 融合 = Remote 真机验收跟进
- 四项验收（发图/Handoff/Siri/扫码）继续跟进；任务详情/处置档在 Remote
  任务页可见。

### ④ 替人干活 = 运营收账
- 产品页 0.8.71-76 扩充部署（手工）；desire-admin 部署提醒。

### 工程（贯穿：可靠性 / 可发现性）
- 无人值守可靠性是旗舰本体；failureRate/Doctor 读数是可发现性；
- harness：处置档判定（超时→deny/放行分支）、连续失败暂停阈值、
  failureRate 聚合——纯逻辑进 run.sh；
- 190 全量（hermetic——0.8.75 的封闭启动首次服务闸门）+ i18n 四语 +
  smoke + Release 零警告 + CI 例行。

## 批次

批 1 = 旗舰 A（isUnattended 标志 + 处置档 + 审批超时）→ 批 2 = 旗舰 B
（自动暂停 + failureRate + 通知升级）→ 批 3 = 小件 → 批 4 = 190 hermetic +
i18n/WhatsNew + smoke → 发版。

## 不做

值守回合的端上模型自动降级（路由已有，不叠加）；任务依赖 DAG（chainTo
线性链够用）；cron 表达式（三档 recurrence 覆盖现实场景）；Web 通知；
iOS Watch；Android；体检周期化（0.8.75 维持手动）；工具动态子集（否决）。

## 风险

- **timeoutQueue 的任务退化**（审批超时→denied→任务没完成）：RunRecord
  明示"超时拒绝 N 次"；设置页任务行的处置档一眼可见——用户知道哪个任务
  该配 fullAuto。
- **fullAuto 风险**：guard pass 保留（副作用动作旁路复查 fail-open）+
  任务级粒度（不是全局开关）+ 设置页明示。
- **连续失败误暂停**（网络抖动场景）：N=3 + urgent 通知告知（可一键恢复）
  + 重试机制不变（第一次失败先重试一次才计 1 次）。
- **urgent 夜间打扰**：urgent 本就绕过免打扰（分级设计如此）——连续失败
  停顿只发生一次（暂停后不再触发），打扰有界。
