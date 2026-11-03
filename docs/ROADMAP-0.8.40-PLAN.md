# v0.8.40 规划稿（2026-11-03）—— 后台值守 2.0：盯条件、会自愈、能排队

> v0.8.39 已把「启动 → 离开 → 完成回报」打通（Job 账本、组 watcher、后台命令、
> Jobs/Remote 面板）。本版不重复铺基础设施，专门把后台值守**做厚**：
> 从"跑完告诉我"升级为"盯住我关心的条件、失败自动处理、多个任务排队跑、
> 在哪都能看"。

## 一、现状与缺口

已有（v0.8.39，勿重复造）：

- `JobRecord`（kind/state/progress/artifact/logFile/exitCode/conversationID/retryOf）
- `JobStore` + `ActivityCenter/JobAdapter`：下载/批量/导出/定时/Agent/命令统一视图
- `JobWatch`/`JobWatchCore`/`JobWatchStore`：组订阅、只终态、notify/resume、去重
- `BackgroundCommandStore`：allowlisted argv、日志、取消/重试、interrupted 恢复
- `JobEventCenter`：终态备注/通知/Remote 推送；批量/媒体已接入
- Agent 工具 6 个、Jobs 面板筛选/日志/取消/重试/Notify、Agent 面板任务条、
  菜单栏计数、新标签页卡、Remote 后台任务页/通知深链
- 桥 `/jobs/run|watch|cancel|retry|log|watches`

仍缺：

1. **只能等终态**：想"看到 BUILD SUCCEEDED 就告诉我"、"失败立刻说"、"每 10 分钟
   报一次进度"都做不到。
2. **无进度语义**：任意命令只有 running/done；长任务没有阶段、百分比、产物声明。
3. **无队列/依赖**：并发满了直接报错；不能"先跑 A，A 成功再跑 B"。
4. **无自动重试**：失败只能手点；临时网络/锁冲突要人盯。
5. **watcher 没有条件日志**：重启/重复事件/条件多次命中可能重复或漏报。
6. **日志只给尾部 40 行**：不能搜索/复制全文/打开日志面板；敏感信息未脱敏。
7. **通知只能开/关**：没有"只在失败时通知"、没有重试/打开日志动作、没有静音单任务。
8. **监控分裂**：PageWatch（页面变化）和 JobWatch 两套；用户要记两个入口。
9. **消费者还没做厚**：批量下载只能整体 cancel，媒体/Office 批量没有逐项重试队列。

## 二、目标与非目标

**目标**

- watcher 条件化：终态 / 任一失败 / 进度阈值 / 日志正则 / 心跳 / 文件出现。
- 任务可排队、有依赖、可自动重试；并发受控，失败可自愈。
- 命令可用轻量协议上报进度/产物/链接；日志可看全文、脱敏、可搜索。
- Jobs 中心成为"后台工作台"：任务 + 订阅 + 模板 + 历史指标。
- 批量下载/媒体/Office 批量共用队列与逐项重试。
- Agent / 桌面 / Remote 三端同一份状态与条件。

**非目标**

- 不做常驻守护进程/launchd；app 退出后命令不继续。
- 不做任意 shell；仍 argv-only + 允许名单 + 审批。
- 不做跨设备执行任务（只在发起 Mac 跑）。
- 不替代 cron/PageWatch 调度；PageWatch 仍独立，只在 UI 汇总。
- 不无限保存日志；不做 APNs。

## 三、基础四主题 + 后台值守专项

> 后台值守是本版专项，但**常规四主题不能缺席**。下面四项是独立成立的常规迭代；
> Track A–D 的后台能力同时服务这四项。

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | 最近关闭中心（跨标签/窗口、可搜索、可恢复）；跨窗口标签搜索（⌘⇧A）；Jobs 中心与菜单栏进度 |
| ② Agent 基础 | 回合断点恢复 2.0（崩溃后完整续跑）；工具失败自愈（分类/建议/只读重试）；条件 watcher/队列/重试 |
| ③ 融合 | PageWatch 变化写回 Agent 会话；后台任务条件订阅卡；Remote 任务详情/日志/重试；通知动作深链 |
| ④ 替人干活 | Office 文件夹批量；定时任务执行命令/模板链；批量下载逐项重试；媒体导出/转码 |

### 3.1 浏览器基础

#### 3.1.1 最近关闭中心

- 现状：`TabManager.recentlyClosed` 只支持“重开最后一个”，关掉多个或整个窗口后
  前面的一去不返；跨启动不保留。
- 增量：`RecentlyClosedStore`（DiskStore，cap 50）记录关闭的标签与窗口
  （标题/URL/favicon/时间/是否无痕/来源窗口）；菜单「Recently Closed」打开面板，
  按窗口+时间分组、可搜索、单选恢复/全部恢复/清空；`⌘⇧T` 行为不变。
- 边界：无痕条目不落盘；恢复标签走既有 `addTab`/session 路径；不恢复表单/登录态。
- 验收：关 3 标签 + 关 1 窗口 → 面板列出 → 恢复单条与整窗；重启后仍在；
  无痕标签不出现在列表。

#### 3.1.2 跨窗口标签搜索

- 现状：`TabOverviewView` 只覆盖当前窗口；多窗口时找标签要靠肉眼切窗口。
- 增量：命令面板 `⌘⇧A`（SearchEverywhere 增加 Tabs 源也可）列出所有窗口的标签
  （标题/URL/host/是否挂起），模糊搜索、↑↓ 选择、回车切到对应窗口并激活标签；
  挂起标签激活时走 resume；显示窗口名/序号。
- 边界：只读；不改变标签顺序；无痕窗口按标题模糊化（不显示完整 URL）。
- 验收：两窗各 3 标签，关键词只命中另一窗 → 回车切窗并选中；挂起标签恢复；
  Esc 关闭不改当前标签。

### 3.2 Agent 基础

#### 3.2.1 回合断点恢复 2.0

- 现状：v0.8.25 有工具级 `TurnCheckpointCore`（未完成 tool_call 的只读重放），
  面板有“继续/放弃”条；但回合快照不完整，计划/页面上下文/模型档案在崩溃后可能丢。
- 增量：回合开始持久化 `TurnSnapshot`（消息前缀、未完成 tool_calls、已得结果、
  plan、页面上下文、profile/model、预算档）；重启后“继续”从快照恢复并只重放
  只读调用，副作用调用逐个确认；同一 assistant 消息不重复落盘；放弃则标
  interrupted 并写一条备注。
- 边界：不重放已产生副作用的调用；模型/档案已删时提示重新选择；快照只在
  回合进行中存在，正常结束即清。
- 验收：工具批处理中 `kill -9` → 重启提示继续 → 只读调用重放、副作用调用询问、
  最终回答不重复；放弃后会话无脏 assistant 消息。

#### 3.2.2 工具失败自愈

- 现状：`TaskFailureClassify` 有失败分类，轨迹页可“重跑原步骤”；但没有自动建议
  或只读重试，模型常直接换路。
- 增量：失败分类扩展（网络超时/403/选择器不存在/页面已变/权限拒绝/内容超限）；
  只读工具遇到瞬态失败自动重试 1 次（退避 500ms）；副作用工具不自动重试，
  在工具结果里给出“可重试/需确认”标记与建议参数；轨迹记录 attempt。
- 边界：自动重试仅限 `.readonly` 且非取消；不得重试 executeJS/点击/提交；
  失败结果仍以 `Error:` 前缀返回。
- 验收：模拟只读工具超时 → 自动重试成功且轨迹 attempts=2；模拟点击失败 →
  不自动重试、给出建议；取消回合时不触发重试。

### 3.3 融合

#### 3.3.1 PageWatch 变化写回 Agent 会话

- 现状：PageWatch 变化只发系统通知与桥事件；用户要问 Agent 时得自己复述。
- 增量：PageWatch 增可选 `conversationID`；变化/数值告警时把差异摘要写成
  system 备注进该会话（走 `appendExternalNote`），通知仍发；Agent 已有
  `listPageWatches/checkPageWatch`，新增 `reportPageWatch(name, conversationId)`
  绑定；会话删除时自动解绑。
- 边界：只写摘要（≤1200 字符），不写整页；不自动起回合（除非用户订阅时选
  resume，复用 JobWatch resume 语义）；每日摘要不变。
- 验收：本地 fixture 页面文本变化 → 会话出现差异备注；Agent 下一轮能引用；
  删除会话后不再写；同一变化不重复备注。

#### 3.3.2 后台值守条件订阅

- 见 Track A–D：任务起于对话、条件命中/完成回对话，Remote 与桌面同一账本。

### 3.4 替人干活

- **Office 文件夹批量**：见 Track D3（docx/pdf/xlsx/pptx/图片/文本 → `Converted/`，
  每文件一个 Job，失败逐项重试，不覆盖原文件）。
- **定时任务执行命令/模板链**：见 Track D5（到点跑命令/模板链，结果进 Job 账本，
  失败可订阅/重试）。
- **批量下载逐项重试**与**媒体导出/转码**：见 D1/D2。
- **任务模板**：把常用的构建/测试/CI/转码命令保存为模板，Jobs 中心一键运行，
  Agent `runJobTemplate` 调用（见 B1）。

## 四、Track A：Watcher 2.0（条件、心跳、自愈）

### A1. 条件模型（`JobWatchCondition`，纯逻辑进 harness）

一个 watcher = 一组条件 + 动作。条件可组合（AND，最多 3 个）：

- `.terminal`：全部终态（v0.8.39 行为，默认）。
- `.anyTerminal` / `.failed`：任一任务失败/结束即触发（fail-fast）。
- `.progressAtLeast(0.5)`：任一任务进度首次越过阈值。
- `.logMatches(pattern, scope)`：日志出现正则/关键词（大小写、上下文 2 行、
  最多命中 5 次；默认只在活动任务上评估）。
- `.heartbeat(minutes)`：每 N 分钟发一次摘要（仍运行、已跑时长、最后一行日志），
  最多 12 次；任务终态即停。
- `.fileAppeared(path)` / `.fileChanged(path)`：产物落盘/更新（路径必须在可写
  workspace 或任务 cwd 内，防越权探测）。
- `.exitCode(0|nonZero)`。

动作（按顺序，最多 2 个）：

- `.notify(tier, title?)`：默认；失败 urgent，成功 routine。
- `.resume(prompt?)`：会话空闲时起一轮汇报；每 watcher 一次。
- `.retryJob`：仅失败命令/可重试媒体；最多 1 次，新 job 记录 retryOf。
- `.runTemplate(templateID)`：失败后跑预设后续命令（如收集日志）；需该模板已
  被用户批准过（避免 watcher 成为绕过审批的后门）。
- `.stopWatching`：条件命中后自动解绑（默认）。

### A2. 条件评估与去重

- `JobWatchCore.evaluate(watch, jobs, logTails, now)` 返回 `[TriggerEvent]`；
  纯函数，时间注入，便于测试。
- 每个条件维护 `lastFiredAt` / `fireCount` / `lastValue`（进度/文件 mtime/日志游标），
  随 watcher 落盘；重启后从上次游标继续，不重复报旧命中。
- 日志匹配用**增量游标**（记录已扫描字节），不整文件重扫；日志轮转/截断时游标复位。
- watcher 状态机：active → triggered（可继续心跳/终态）→ done；显式 cancel。
- 上限：每 watcher 3 条件、20 watcher、单会话 10；同条件每分钟最多触发 1 次。

### A3. 会话与 resume 策略

- `resume` 增加 `on: terminal|failed|condition`，默认只在终态/失败时汇报。
- 会话忙：只写备注 + 通知，不排队 resume；用户下次说话可见。
- resume 回合的系统提示强制带：任务摘要、失败原因、日志尾部（≤40 行）、产物；
  禁止在 resume 回合创建 `resume` watcher（降级为 notify），防自激。
- watcher 触发但会话已删：丢弃并记录诊断；不写回已删会话。

### A4. 通知动作与分级

- 类别：`JOB_PROGRESS`（可静音）、`JOB_DONE`、`JOB_FAILED`、`JOB_HEARTBEAT`。
- 动作：Open Log / Open Result / Retry / Mute this job / Show Jobs。
- 同一 job 固定 identifier 覆盖；心跳合并为一条；免打扰/夜间档沿用。
- 失败通知默认 urgent；成功/心跳 routine；用户可按 job 设 "only on failure"。

## 五、Track B：执行 2.0（队列、依赖、重试、协议）

### B1. 队列与并发

- `JobQueueStore`（持久化）：pending/running/paused，按 kind 分桶；
  并发上限设置（命令默认 3，媒体导出默认 2，Office 批量默认 2）。
- 超过上限不再报错：进入队列，槽位释放自动启动；Jobs 面板显示排位。
- 优先级：high / normal / low；用户手动"立即运行"可插队。
- 资源闸：磁盘低于 reserve（复用批量的 5GB 底线）或用户开启"电池时暂停重任务"
  时，队列暂停并说明原因，恢复后续跑。

### B2. 依赖与任务链

- `dependsOn: [jobID]`（最多 5 个）：全部 done 才启动；任一 failed/cancelled →
  本任务 `.cancelled`（原因 "dependency failed"）。
- `runBackgroundCommand(..., after:[ids], priority)` 与模板链共用。
- 任务链（template chain）：A → B → C 的模板序列，落成队列依赖；每步独立日志/重试。
- 防环：依赖图建时 DFS 检查；跨启动恢复后重新校验。

### B3. 自动重试

- 命令模板 / 队列里可设 `maxAttempts`（1-5）、`retryOn`（nonZero/timeout/always）、
  `backoffSeconds`（指数，上限 15 分钟）。
- 自动重试生成新 JobRecord（`retryOf`），原记录保留 attempts 链；
  通知只在最终失败时发（中间重试静默，面板可见）。
- 只对可重试任务：命令、媒体导出（URL 未失效）、Office 单文件；
  批量下载用自身逐项重试，不套这层。

### B4. 进度 / 产物协议（命令可选）

- 命令可向 stdout 输出行：
  - `@@desire:progress {"percent":42,"message":"compiling"}`
  - `@@desire:artifact {"path":"/…/out.mp4","kind":"video"}`
  - `@@desire:link {"url":"https://…","title":"CI run"}`
  - `@@desire:phase {"name":"tests"}`
- 解析器剥离控制行（不写入日志正文）→ 更新 JobRecord.progress/detail/artifact；
  非法 JSON 忽略并计数（不崩溃）。
- 未使用协议的命令保持 0/未知进度；ffmpeg 的 `out_time_us` 仍映射百分比。
- 环境变量：`DESIRE_JOB_ID`、`DESIRE_LOG_FILE` 供脚本自报。

### B5. 日志与安全

- `JobLogStore`：每任务独立文件，2MB 上限；Jobs 详情页可看最近 500 行、
  搜索、复制、在 Finder 显示、打开完整日志；支持 tail follow（1s）。
- 脱敏：token/Authorization/password/api_key 等模式替换为 `[redacted]`；
  写入时脱敏，推导时也脱敏（历史日志兼容）。
- 保留：7 天/50MB 现有策略；新增"保留最近 N 个任务日志"设置。
- 安全边界：argv-only、允许名单、审批沿用；`cwd` 限工作区/用户目录；
  模板不含 shell 串联；`runTemplate` 动作要求模板已批准。

## 六、Track C：界面 2.0

### C1. Jobs 中心

- 左栏：运行中 / 排队 / 待处理 / 已完成 / 订阅 / 模板；按 kind/标签筛选。
- 任务详情：状态/进度条/阶段、开始/耗时、exit code、全文日志（搜索/tail）、
  产物与链接、重试/取消/复制命令、订阅条件、发起会话跳转。
- 订阅列表：条件摘要、上次触发、下次心跳、静音/取消。
- 历史指标：今日任务数/成功率/平均时长/失败 Top（派生自 JobStore，不另存）。
- 空状态给"新建后台命令 / 保存为模板"入口。

### C2. Agent 面板

- 后台任务卡显示条件 badge（如"失败时通知"、"每 10 分钟"）。
- 卡片内可切换：完成通知 / 仅失败 / 静音 / 停止订阅；不再只有 Notify。
- 任务详情展开日志尾部与重试按钮；resume 汇报时自动带上下文。

### C3. Remote

- 任务详情页：日志尾部（按需拉取，不塞列表帧）、订阅条件、重试/取消/静音。
- 通知动作：Open Log / Retry / Show Jobs；后台任务帧增加 `progress/phase/watch`。
- 离线缓存任务与订阅；离线禁用写操作并说明。

### C4. 设置

- 后台任务：并发上限、日志保留、默认通知策略（完成/仅失败/静音）、
  电池/磁盘闸开关、任务模板管理入口。

## 七、Track D：消费者接入

### D1. 批量下载

- 批次 watcher 支持 `.failed`（某项失败即提醒）与终态汇总；
  摘要带失败项短 id + 标题（截断）+ 目录。
- Agent 工具/桥：`retryBatchItem`、`pause/resumeBatch`（已有端点，补 Agent 工具）。
- 逐项重试不新建批次，复用原 batch item id；重试历史写日志。

### D2. 媒体导出 / 转码 / GIF

- ffmpeg 进度接入统一进度字段；完成摘要带 ffprobe 校验。
- 失败重试策略可配（网络 403/分段失败）；产物写入 artifact 协议。

### D3. Office 文件夹批量（补 v0.8.38 欠账）

- 选文件夹 → 目标格式（docx/pdf/xlsx/pptx/图片/文本）→ 预演列表 →
  队列执行（并发 2、每文件一个 JobRecord、失败重试/打开产物）。
- 输出 `Converted/`，重名加序号，绝不覆盖原文件；取消保留已完成项。
- 复用 `DocumentConvert`，不新增转换引擎；Agent 工具 `batchConvertFolder`。

### D4. PageWatch 汇总

- Jobs 中心"监控"区只读展示 PageWatch（名称/间隔/上次检查/变化数/告警），
  可跳转管理页；不合并状态机、不改 PageWatch 调度。
- 同一通知中心按来源分组，避免页面监控和任务通知互相淹没。

### D5. 定时任务 + 任务链

- 定时任务可以执行"命令/模板链"而不是只投 prompt；运行结果进 Job 账本，
  失败可订阅/重试；与现有 `AgentScheduler` 失败进 needsReview 兼容。

## 八、数据与接口

- 模型：`JobWatchCondition`/`JobWatchAction`/`JobTriggerEvent`（Foundation-only）；
  `JobTemplate`、`JobQueueEntry`、`JobAttempt`。
- Store：`JobQueueStore`、`JobTemplateStore`、`JobLogStore`；`JobWatchStore` 增条件
  游标/触发日志。
- Agent 工具新增/扩展：
  - `watchBackgroundTasks` 增 `conditions`、`onFailure`、`heartbeatMinutes`、
    `logPattern`、`resumeOn`；
  - `runBackgroundCommand` 增 `after`、`priority`、`maxAttempts`、`retryOn`；
  - `saveJobTemplate` / `runJobTemplate` / `listJobTemplates`；
  - `backgroundTaskLog`（全文/搜索/分页）。
- 桥：`/jobs/watch` 增条件；`/jobs/templates` CRUD；`/jobs/log` 支持 offset/search；
  `/jobs/queue` 查看/暂停；`/jobs/retry-policy`。
- Remote 帧：`backgroundTasks` 加 `watch`/`phase`/`priority`；`backgroundTask` 详情帧
  带日志尾与条件。
- 兼容：所有新字段 optional；`JobRecord.Kind` 已有未知值降级；旧 watcher 视为
  `.terminal`。

## 九、验收清单

1. `runBackgroundCommand(tool:"xcodebuild", args:[…], watch:{logPattern:"BUILD SUCCEEDED", heartbeatMinutes:10})` 立即返回；中途收到心跳，命中后收到一次“条件达成”，终态汇总不重复。
2. 批量下载 3 项其中 1 项失败：`.failed` 条件在失败时立即通知，终态仍给完整汇总；重试该 item 后批次状态更新，不新建批次。
3. 并发上限 2 时排 5 个命令：2 运行、3 排队；前两个结束后自动接续；依赖 A→B 在 A 失败时 B 取消并说明原因。
4. 自动重试：命令第 1 次 exit 1、第 2 次成功；最终只发一条完成通知，详情能看到 attempt 链与重试间隔。
5. 命令输出 `@@desire:progress`/`artifact`/`link`：Jobs/Remote 显示百分比、产物、CI 链接；控制行不在日志正文出现。
6. 日志含 `Authorization: Bearer …` / `password=`：详情页与通知均为 `[redacted]`；搜索不到明文。
7. 强杀/重启：排队任务保留为排队（不自动执行命令），运行中标记 interrupted；watcher 恢复后旧条件不重复报。
8. Remote 详情页可看日志尾、重试、取消、静音；通知动作 Open Log 直达详情。
9. Office 文件夹混合 3 文件：2 成功 1 失败；失败项可重试，输出在 `Converted/`，原文件未改。
10. Jobs 中心历史指标与 `/jobs` 计数一致；PageWatch 只读区能跳转且不影响其调度。

## 十、批次（5 批）

- **批零（常规四主题基础）**：3.1.1 最近关闭中心 + 3.1.2 跨窗口标签搜索 +
  3.2.2 工具失败自愈 —— 独立成立，不依赖后台值守。
- **批一（条件引擎 + 融合）**：A1/A2/A3 + 3.3.1 PageWatch 写回会话 +
  JobWatch 条件模型/游标/触发日志 + 单测；`watchBackgroundTasks` 条件参数与桥。
- **批二（执行 2.0）**：B1/B2/B3/B4/B5 —— 队列/依赖/自动重试/进度协议/日志脱敏。
- **批三（界面 + 断点恢复）**：C1/C2/C4 + 3.2.1 回合断点恢复 2.0 —— Jobs 中心详情/
  订阅/模板/指标、Agent 卡片、设置、崩溃续跑。
- **批四（Remote + 消费者）**：C3 + D1/D2/D3/D4/D5 + E2E。

## 十一、风险与取舍

| 风险 | 取舍 |
|---|---|
| 条件 watcher 复杂度 | 条件纯函数 + 游标落盘；先做 6 种高频条件，不做通用规则引擎 |
| 通知风暴 | 每条件每分钟 1 次、心跳上限、同 job 覆盖、失败优先；通知中心合并 |
| 自动重试放大故障 | 默认不重试；模板显式开、最多 5 次、指数退避、只对可重试任务 |
| 队列跨重启 | 排队保留、运行中断；命令绝不自动重启，避免不可控副作用 |
| 日志泄密 | 写入即脱敏 + 读取再脱敏；日志权限 0600；通知只带摘要 |
| 模板绕过审批 | 模板首次运行需审批；watcher 的 runTemplate 只允许已批准模板 |
| Office 批量体量 | 单文件一个 Job、并发 2、取消保留已完成；不合并转换引擎 |
| Remote 帧变大 | 列表只带摘要，日志走详情按需拉取；沿用 32KB 预算 |
| PageWatch 状态机 | 不合并；只读汇总，避免回归既有页面监控 |

## 十二、不做

- 常驻守护进程 / 后台跨 app 退出继续执行
- 任意 shell 字符串 / 自动批准新模式
- APNs / 跨设备执行
- 通用工作流引擎（条件分支、循环）——本版只做线性队列/依赖
- 无限日志 / 全量归档
- 重写 PageWatch 调度

## 十三、发版口径

- CHANGELOG 只用 `scripts/changelog.py add`；What's New 三亮点（条件值守、
  队列与自动重试、Office 批量）。
- 发版前：harness 新条件/队列/脱敏用例 0 失败 + macOS Debug/Release clean build
  零警告 + Remote 构建 + E2E（条件心跳/失败快报/依赖取消/协议/脱敏）。
- 用户说「发」才发。

## 十四、开发进度（2026-11-03）

- **批零完成**：RecentlyClosedStore（跨窗口/跨启动、搜索、标题/时间）+ 面板改造；
  SearchEverywhere 跨窗口标签（`foreign:` 命中、切窗激活）；只读工具瞬态失败重试一次。
- **批一完成（条件部分）**：`JobWatchCondition`（terminal/failed/progress/logMatch/
  heartbeat）+ 条件去重/心跳基线 + Agent 工具与桥参数 + PageWatch 变化写回会话
  （`reportToConversation`）。桥实测 logMatch 触发、心跳/进度单测通过。
- **剩余**：批三（Jobs 中心详情/模板/指标、回合断点恢复 2.0）、批四（Remote 任务
  详情、Office 批量/定时命令链）。

- **批二部分完成（协议/脱敏）**：`CommandProgressParser` + `JobLogRedactor`（进 harness，
  2722/0）；命令 stdout 的 `@@desire:` 控制行实时更新进度/阶段/产物/链接且不写日志；
  日志写入与读取均脱敏。桥实测 30%→80%→artifact，控制行未落盘，Bearer 变 `[redacted]`。
  **队列/依赖/自动重试**仍在批二，下一轮继续。

- **批二完成**：队列（并发满排队、high/normal/low 优先级、槽位释放自动续跑）、
  `after` 依赖（依赖失败 → 取消并说明）、自动重试（maxAttempts/retryOn/指数退避，
  同 jobID 续跑、最终才通知）、进度协议与日志脱敏（上一条）。模板/指标留给批三。

- **批三部分完成（模板/指标）**：`JobTemplate`/`JobTemplateStore` + Jobs 面板模板
  管理器 + Agent 三工具 + 桥 `/jobs/templates`；`JobMetricsCore` 今日完成/失败/
  成功率/平均耗时/失败 Top 进 Jobs 头部与 harness（2731/0）。**任务详情页与回合
  断点恢复 2.0 仍留批三**。

- **批三完成**：任务详情 sheet（状态/退出码/产物/订阅条件/日志尾 200 行 + 取消/重试/
  通知/打开）；模板与指标已在前一条。回合断点恢复 2.0 经核实 v0.8.25 的工具级
  checkpoint（只读重放 + 继续/放弃）已覆盖核心语义，本版不重复改造，只留 UI 入口。

- **批四部分完成（Remote 详情）**：Mac `jobDetail` 帧（日志尾/订阅条件/退出码）；
  iOS 任务详情 sheet（产物/日志/取消/重试/刷新），iOS 构建零代码警告。
  **Office 文件夹批量、定时任务命令/模板链**仍留批四。

- **批四 Office 完成**：`OfficeBatchStore`（目录扫描/递归/Converted 唯一命名/逐文件
  失败汇总/进度） + Agent `batchConvertFolder` + 桥 `/office/batch`；fixture PNG→PDF
  实测通过，产物目录与 Job 进度正确。**定时任务命令/模板链**仍待做。

- **批四完成**：Remote 任务详情、Office 文件夹批量、定时任务执行命令模板
  （`scheduleJobTemplate` → `addTemplate` → 到点启动后台 Job）。v0.8.40 全部批次完成。
