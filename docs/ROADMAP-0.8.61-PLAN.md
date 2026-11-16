# v0.8.61 规划稿（2026-11-17）—— 健康底盘：协作线程池卫生 + 生命周期 GC + 回归里程碑

> **主题叙事**：0.8.58-0.8.60 三连 Agent 版之后，本版回到**底盘**。三案同源的
> 隐患到了收口的时候：AppSecretsVault 的 Keychain 读（0.8.49）、DiskStoreWriter
> 的同步磁盘写（0.8.58）、AgentStreamWatchdog 的协作池轮询（0.8.60）——全是
> "**协作线程池被长占/阻塞 → 全局饿死**"同一根因的不同切面。本版把这类模式
> 一次性审计收口 + 建立水位观测（以后能看见而不是靠 sample 抓栈），同时兑现
> 0.8.59 规划里"execution-e2e 全量回归放到下里程碑"的承诺。规划前核实：
> RuntimeHealthMonitor 已有主线程 stall 检测（无协作池水位——真空白）；
> DiskStoreWriter.flush 的 `data.write` 仍直接跑在 actor（= 协作线程）上；
> execution-e2e 的 --section 分节化未实现。

## 四主题

### ① 可靠性（旗舰）= 协作线程池卫生专项
- **DiskStoreWriter IO 外移**：actor 内 flush 的磁盘写挪到专用串行
  DispatchQueue（`withCheckedContinuation` 包回填）——协作线程在 IO 期间
  释放；actor 继续管 task 槽/防抖语义不变；原子写保证同 key 乱序无害。
- **全仓审计清单**：扫 `Task.detached` / `Task {` / actor 方法体内的同步 IO
  （`Data(contentsOf:)`、`data.write`、`FileHandle`、`ContentOfFile`）与长循环
  模式，已知三案之外逐个定性（阻塞时长/频率）→ 当场修或记档。
- **协作池水位观测**（RuntimeHealthMonitor 扩）：周期性探针（utility 任务
  测量自身调度延迟）→ 滑动水位（p50/p95）→ Doctor"运行健康"字段 +
  诊断端点；超阈值（如 p95 > 2s）fault 一条——协作池饿死从此**可看见**。
- **测试**：DiskStoreWriter 外移后回归（防抖/取消/备份语义，纯逻辑可测的
  部分进 harness）；水位探针纯计算部分单测。

### ② Agent 基础 = 落盘生命周期 GC（0.8.59 遗留收口）
- **归档 GC**：`conversation-*.archive.json` 单份上限 ~10MB（超则从头截断
  最老轮次、保留尾部 + 一行截断标注）；删除会话联动已做（0.8.60）。
- **转存目录 GC**：`tool-results/` 按"容量 1GB + 30 天"双阈值自动清（Doctor
  的"转存目录"项升级为显示最近一次 GC 时间）；清理由会话结束时顺带跑
  （低频、后台）。
- **芯片 token 口径常驻**：校准比率就绪（样本 ≥3）后，芯片 help 与面板
  状态行显示"≈Nk tokens"（换算自 EMA 比率；未校准模型维持字符口径）。
- **测试**：GC 阈值判定纯逻辑进 harness。

### ③ 可发现性 = 设置诊断页"运行健康"卡
- RuntimeHealthMonitor 数据面（主线程 stall 历史 / 协作池水位 p50/p95 /
  活跃看门狗数）进设置诊断页 + `GET /diag/health`；无异常时显示
  "主线程 0 停滞 · 协作池 p95 120ms"式的确定性文案。

### ④ 贯穿 = 回归里程碑
- **execution-e2e 分节化**：`--section <名>` / `--sections a,b`（每节独立
  launch+探活，失败类目轮换转稳——0.8.58 规划项，本次兑现）。
- **190 项全量回归跑一轮**（0.8.59 承诺的"下里程碑"）：暴雷项逐个定性
  （环境/真回归），真回归当场修。
- **agent-eval E26**：值守处置链固化成用例（后台 sleep 任务 → stalled 1min
  → .handle 自动回合 → resumeUsed 断言；本地专属档，复用 0.8.60 的
  活体验证手法）。

### 批 1 审计清单（2026-11-17 实扫）

| 对象 | 定性 | 处置 |
|---|---|---|
| DiskStoreWriter.flush/flushNow 同步写 | 高（多 key 并发 + 外置卷秒级） | **已修**：IO 外移专用 GCD 串行队列 |
| AgentStreamWatchdog Task.sleep 轮询 | 高（每流常驻一协作线程） | 0.8.60 已修（asyncAfter 链） |
| AppSecretsVault Keychain 预载 | 高（26 条 data 读） | 0.8.49 已修（preload 外移） |
| FaviconStore 写盘 | 中（高频小写） | **已修**：写侧 detached（读侧早已外移） |
| ScreenshotOverlayView 大 PNG 写盘 | 低（低频用户触发） | 记档 |
| VideoEditorStore 工程文件 IO | 低（低频大文件） | 记档 |
| FilterListStore 列表编译/写 | 低（更新时一次性） | 记档 |
| AgentSessionStore 会话落盘 | 已走 DiskStore（本批外移覆盖） | 无需动作 |

## 批次

批 1 协作池专项（IO 外移 → 审计清单 → 水位观测）→ 批 2 GC + 芯片 token →
批 3 诊断健康卡 → 批 4 E2E 分节化 + 全量回归 + E26 → 收口（AGENTS/i18n/
WhatsNew）。

## 不做

新 Agent 能力大件（三连 Agent 版后休整，0.8.60 的 token 校准/处置档/记忆
反馈需要真实使用反馈再迭代）；动态成本路由；技能全自动沉淀；网络节流/
pixelRatio（维持证伪）；passkey；Remote 新能力。

## 风险

- DiskStoreWriter 外移的正确性：同 key 连续写靠 GCD 串行队列保序 + 原子
  写；flush 完成回调不回 actor（无状态回写需求）。回归点 = 取消/备份/
  进程退出 flush barrier（0.8.58 记录的 flush 等待语义）。
- E2E 全量可能暴一批历史问题——这正是目的，但需要预留修复轮的时间预算。
- 协作池水位探针自身是协作池任务（每 30s 一次轻探针，开销可忽略；探针
  失联本身也是"池已满"的信号——缺样本期直接按"不可测"上报）。
