# v0.8.39 规划稿（2026-11-02）—— 后台值守：交给它跑，跑完回来告诉你

> 触发场景（2026-11-02 用户提出）：发版时我在终端 `gh run watch` 盯 CI，用户问
> 「这个后台监控的功能加到浏览器的 Agent 上，比如视频批量下载完成等，规划到下个版本」。
> 目标不是再做一个任务系统，而是把已有的 Job 账本、批量下载、媒体导出、定时任务
> 接成 **Agent 可启动 / 可查询 / 可订阅 / 完成自动回报** 的闭环。

## 一、现状核实（先查再规划）

已有、不能重复造轮子的部分：

- `Features/Jobs/JobRecord.swift`：统一作业记录（kind/state/progress/artifact/error/
  source/externalID），Foundation-only。
- `JobStore.swift`：账本 + tombstone + 同步；`allJobs / active / failed / finished`。
- `JobAdapter.swift`：把 ActivityCenter 的下载/批量/导出/定时/Agent/crew 投影成 JobRow
  （只读、不复制状态）。
- `ActivityCenter` + `ActivityCenterCollector`：实时采集下载、批量下载、媒体导出、
  定时运行、Agent 会话、crew。
- `JobsPanel` + 桥 `GET /jobs` + `POST /jobs/action`（dismiss/delete/clearFinished/approve）。
- `BatchMediaExportStore.finalize` 已经会发完成备注 + 系统通知（成功/失败/跳过 + 目录）。
- `MediaExportStore.deliverNote`：长任务完成追加会话备注 + 通知。
- `PageWatchStore`：定时页面监控（价格/文本 diff），已有 `addPageWatch/listPageWatches`。
- Agent 长任务纪律：`downloadMedia` 立即返回任务 id，不 await 到底。

真正的缺口：

1. **Agent 看不见 Job 账本**：没有工具列出/查询/取消后台任务，只能等系统备注。
2. **没有通用“后台命令”**：`runCommand` 阻塞到 120s 超时；无法跑构建/CI/长 ffmpeg
   并稍后拿退出码和日志尾部。
3. **没有订阅语义**：用户说“下载完告诉我”只能依赖各子系统自己发备注；无法对任意
   Job 注册一次性 watcher，也没有“完成后自动回一轮话”的模式。
4. **完成通知各写各的**：批量/媒体各自 deliverNote，无法去重、无法统一策略/动作。
5. **UI/Remote 只能看下载和媒体**：没有一个“正在后台干什么”的统一面。

## 二、目标与非目标

**目标**

- Agent 能启动一个长任务并立刻结束回合；任务在后台跑，完成/失败时按订阅回报。
- 所有后台任务共用一份账本与一套终态事件；通知只发一次、带可执行动作。
- 用户能在 Jobs 面板 / 菜单栏 / Remote 看到同一份“正在跑 + 最近完成”。
- 批量视频下载、媒体导出、转码/GIF、后台命令、定时任务、crew 全部纳入。

**非目标（本版不做）**

- 不做常驻守护进程/launchd；app 退出后任务不继续（命令会标记 interrupted）。
- 不做 APNs；Remote 仍靠在线帧 + 本地通知。
- 不把 PageWatch 的调度合并进 Job 状态机（保持确定性监控独立，最多只读投影）。
- 不做跨设备执行任务（任务只在发起它的 Mac 上跑）。
- 不做无限日志；命令输出有环形上限。

## 三、四主题覆盖

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | Jobs 面板升级（运行中/已完成、筛选、日志尾部、取消/重试/打开产物）；菜单栏后台任务计数与快速入口 |
| ② Agent 基础 | `listBackgroundTasks` / `backgroundTaskStatus` / `watchBackgroundTask` / `cancelBackgroundTask` / `runBackgroundCommand` |
| ③ 融合 | 任务起于对话、完成回对话；Jobs 面板“问 Agent”；Remote 任务页与完成通知；点击通知回到发起会话 |
| ④ 替人干活 | 批量下载/媒体导出/转码的完成回报；后台构建/CI/测试命令；失败摘要与重试 |

## 四、Track A：后台任务核心（Agent 基础）

### A1. 账本扩展（不新建平行系统）

- `JobRecord.Kind` 增 `command`、`media`（旧记录 Codable 兼容，未知值只影响新记录）。
- `JobRecord` 增可选字段：
  - `conversationID: UUID?`：任务发起的会话（通知/回报回到这里）。
  - `logFile: String?`：命令/长任务的日志文件路径（文件放
    `Application Support/Desire/JobLogs/<jobID>.log`，不把 8KB 日志塞进 UserDefaults）。
  - `exitCode: Int?`。
- `JobStore.start/update/finish` 增 `conversationID/logFile/exitCode` 参数。
- 适配器继续只读投影；批量/媒体改由 A4 的终态事件统一回报，避免双份备注。

### A2. Agent 工具（5 个）

1. `listBackgroundTasks(state?, kind?, limit?)`
   - 返回 id/标题/kind/state/进度/开始时间/最近更新/来源会话；默认只列 active，
     `state=all` 看最近完成。工具索引从 `toolDefs` 生成，不手写。
2. `backgroundTaskStatus(id)`
   - 状态、进度、detail、error、artifact、exitCode、日志尾部（最多 40 行/8KB）。
3. `watchBackgroundTask(id, mode="notify"|"resume", reason?)`
   - **立即返回**“已订阅”；不阻塞回合。
   - `notify`：终态时追加系统备注 + 通知（默认）。
   - `resume`：除备注外，在会话空闲且用户明确要求时自动跑一轮“汇报结果”的短回合；
     每 watcher 只触发一次，禁止 watcher 回合再创建 `resume` watcher（防自激）。
4. `cancelBackgroundTask(id)`
   - 按 kind 分派：下载/批量/导出/命令各自 cancel；终态写 cancelled。
5. `runBackgroundCommand(command, title?, cwd?, timeoutMinutes?)`
   - 复用 `runCommand` 的审批/风险分级与路径策略；**不新增绕过通道**。
   - `Process` + 进程组，stdout/stderr 合并写日志文件；立即返回 job id。
   - 上限：并发 3、单任务 6 小时、日志 2MB 环形（超出截断并标注）。
   - 取消 = SIGTERM 进程组，5s 后 SIGKILL；退出码非 0 = failed。

### A3. Watcher 状态机（`JobWatchCore`，纯逻辑进 harness）

- 持久化 `JobWatch`：id、jobID、conversationID、mode、createdAt、deliveredAt、
  deliveredState。
- 事件源 `JobEventCenter`：JobStore 的 start/update/finish 与适配器变更都归一成
  `(jobID, state, progress, detail)`；只在 **进入终态** 时发一次事件。
- 去重键 `(jobID, terminalState)`：批量/媒体自己已发过的备注迁到中心后不再重复。
- 会话不存在/已删除：丢弃并记日志；不得写回已删会话。
- 上限：watcher 20 个，单会话 10 个；会话结束/任务完成即释放。
- `resume` 触发条件：会话仍存在、没有正在跑的回合、没有被用户暂停/取消；
  否则只备注 + 通知，等用户下次说话时模型自然看到备注。

### A4. 统一终态回报

- 新增 `JobEventCenter.deliverTerminal(job, summary)`：
  - 系统备注（进原会话，走 `appendExternalNote`，不直接发 system 消息——服务端只收
    开头一条 system）。
  - 系统通知（成功静默/失败 urgent，按 ProactiveNotificationStore 策略）。
  - 标记 watcher delivered。
- 迁移 `BatchMediaExportStore.finalize` 与 `MediaExportStore` 的完成备注到该入口，
  文案/成功失败统计保持现状；旧路径保留到验证通过后删除。

## 五、Track B：用户可见面

### B1. Jobs 面板升级

- 顶部三档：运行中 / 待处理 / 已完成；按 kind 筛选（下载/媒体/命令/定时/Agent）。
- 行内：进度、最近更新、失败原因、日志尾部展开、产物定位。
- 动作：取消、重试（命令/媒体可重试；下载走既有失败重试）、打开产物、“问 Agent”。
- 运行中任务显示 watcher 徽标（“完成时会告诉你”）。

### B2. 菜单栏与入口

- 现有 `MenuBarQuickEntryController` 增加“后台任务 N”行与进行中数量；
  点击打开 Jobs 面板（已有入口不复用新窗口）。
- 新标签页“在后台运行”卡片：最多 3 条运行中任务 + 最近完成；可关闭（同其它卡片）。

### B3. 通知动作

- 完成：Open Result / Ask Agent。
- 失败：Open Log / Retry / Ask Agent。
- 同一 job 的重复帧按 jobID 替换通知；静默策略沿用免打扰/夜间档。

### B4. Agent 面板内联任务卡

- 工具返回 `jobID` 时，在消息流或输入区上方显示卡片：标题、进度、状态、取消、
  “完成时告诉我”开关（写 watcher）。
- 卡片跟着会话保存；切回会话仍能看到；任务完成后变成一行“已完成 · 打开产物”。

## 六、Track C：Remote 2.1

### C1. 后台任务帧与页面

- 新帧 `backgroundTasks`（列表：id/title/kind/state/progress/updatedAt/artifact）与
  `backgroundTask`（详情 + 日志尾部）。
- Remote 新增“后台任务”页（Agent 首页入口，带运行中计数），支持刷新、取消、打开产物。

### C2. 通知与深链

- 终态推 `notify`（kind=job，带 jobID/severity）；通知动作：打开任务 / 打开产物 /
  让 Agent 汇报。
- 点击通知回 Agent 首页任务页；会话关联存在时给“回到对话”按钮。

### C3. 离线缓存

- 任务列表进 Remote 离线缓存（复用 v0.8.38 缓存机制），断网可看最近状态；
  离线时禁用取消并说明。

## 七、Track D：接入与验收场景

### D1. 批量视频下载（用户点名）

- 批次状态投影已有；`finalize` 改为 JobEventCenter 交付，保留成功/失败/跳过与目录。
- `watchBackgroundTask(batchID, mode=resume)`：完成后自动汇报“成功 N/失败 M/产物路径”，
  失败项列出前 5 条标题（已脱敏/截断）。
- 不在每一条下载完成时推送，只在批次终态推一次（避免刷屏）。

### D2. 媒体导出 / 转码 / GIF

- `downloadMedia`、`convertMedia`、`videoToGIF` 返回 jobID 并登记 JobRecord；
  MediaEditStore 的 Job 与 JobRecord 以 externalID 对应。
- 完成通知带产物与 ffprobe 摘要（已有 probe 能力）。

### D3. 后台命令（CI/构建/测试）

- `runBackgroundCommand("gh run watch <id> --exit-status")` 返回 jobID；
  日志尾部可查；退出码 0/非 0 分别 done/failed。
- 安全：与 `runCommand` 同一审批档；危险命令仍逐次确认；`cwd` 限制在工作区/用户目录。

### D4. 定时任务 / crew

- 只读投影进统一列表；完成仍走各自调度记录，不重复发备注。
- 定时任务失败进 needsReview，Jobs 面板可“问 Agent”。

## 八、接口与数据

- Agent 工具：上述 5 个，全部写进 `BrowserToolProvider.toolDefs`（提示词自动跟随）。
- 桥：`GET /jobs` 已有；新增 `POST /jobs/watch`、`POST /jobs/cancel`、
  `GET /jobs/{id}/log`，供 E2E 与自动化。
- Remote：`backgroundTasks` / `backgroundTask` 帧 + `cancelJob` / `retryJob` 动作。
- 持久化：`JobStore`（账本）、`JobWatchStore`（订阅）、`JobLogs/`（日志文件）；
  运行中命令在启动时发现残留 → 标记 interrupted，不自动重启。

## 九、验收清单

1. `runBackgroundCommand("sleep 2; echo ok")` 立即返回 jobID，回合结束；2 秒后会话出现
   “命令完成（exit 0）”备注 + 通知，Jobs 面板 done。
2. 批量下载 3 个 fixture 视频，途中问“下到哪了” → `listBackgroundTasks` 给出进度；
   完成后只收到 **一条** 汇总备注/通知（不重复）。
3. `watchBackgroundTask(id, mode=resume)` → 完成后会话空闲时自动一轮汇报，包含成功/失败
   与产物路径；忙碌时只备注，下一次用户消息模型能看到。
4. 取消运行中的命令 → 进程组退出，状态 cancelled，不出现“完成”备注；日志可打开。
5. 强杀/重启 app → 运行中命令标 interrupted，不发假完成通知；watcher 不重复触发。
6. 会话删除后 watcher 不崩、不写回已删会话。
7. Remote 任务页可见运行中/完成，取消生效，通知深链回任务页。
8. `listBackgroundTasks` 覆盖下载/批量/导出/命令/定时/crew；jobs 计数与 `/jobs` 一致。

## 十、批次（4 批）

- **批一（核心）**：A1 + A2（list/status/cancel/runCommand）+ A4 事件中心骨架；
  JobWatchCore 单测。
- **批二（订阅与回报）**：A3 watcher + resume 模式 + 批量/媒体迁移到统一交付 +
  通知动作。
- **批三（用户面）**：B1 Jobs 面板 + B4 会话内联卡 + B2 菜单栏/新标签页。
- **批四（Remote + 收口）**：C1–C3 + D2/D3 + 桥端点 + 全量验收。

## 十一、风险与取舍

| 风险 | 取舍 |
|---|---|
| 与批量/媒体现有备注重复 | 迁移到单一 JobEventCenter；按 (jobID, terminalState) 去重；旧路径灰度一轮后删 |
| resume 自激/烧 token | 每个 watcher 只触发一次；resume 回合禁止再建 resume watcher；会话忙时只备注 |
| 后台命令安全 | 复用 runCommand 审批与风险分级；并发/时长/日志上限；取消杀进程组 |
| app 退出任务丢失 | 明确“不承诺跨进程”；启动时标 interrupted，绝不假装完成 |
| `JobRecord` 加字段破坏同步 | 新字段全部 optional；旧客户端忽略；同步 upsert 保持 LWW |
| Remote 帧变大 | 列表只带摘要，日志尾部走详情帧；沿用 32KB 预算与截断 |
| 通知风暴 | 批量只在终态一次；同 job 替换；免打扰/夜间档沿用 |

## 十二、发版口径

- CHANGELOG 只用 `scripts/changelog.py add`；What's New 三亮点（后台任务中心、
  完成自动回报、后台命令/CI 监控）。
- 发版前：harness（JobWatchCore 新用例 0 失败）+ macOS Debug/Release clean build
  零警告 + Remote 模拟器构建 + 本版 E2E（后台命令/批量下载回报/Remote 任务页）。
- 用户说「发」才发。
