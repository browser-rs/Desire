# v0.8.58 规划稿（2026-11-14）—— 卡住即报警：僵尸专项 + 常驻探针 + 评估分节

> 定位：**Agent 基础旗舰（可靠性/可观测）**。v0.8.57 批 2 验证时活体复现
> **主 actor 僵尸第 3 例**（E16 起全部回合挂死；lldb 探针 `suspended|enqueued`
> 实锤；0.8.56 发布基线 stash 对照同挂——**非本版回归，日期相关**）。僵尸的
> 恶劣之处：界面照常渲染、进程可优雅退出、**没有任何崩溃报告**，桥无响应时
> 用户只觉得"卡了"——而现在它连评估套件（验收基建）都能吞掉。本版三件事：
> **找到它（复现固化 + 二分定位）→ 修掉它 → 让它以后自己报警**（常驻探针
> 把一次性的判定手法变成运行时可观测）。

## 一、现状核实（2026-11-14；排除项都查过）

**已排除（非根因）**：
- `SecretRedactor`：现实现每轮重算 NSRange（0.8.55 修复后形态），knownKeys 走
  String.contains/replace——安全。
- `MemoryExtractor`：无 NSRegularExpression。
- 路由/FM：`/ai/routing` enabled=false、costAware=false——排除 FoundationModels 路径。
- `BackgroundCommandStore`/`JobChainRunner`：批 2 新代码，0.8.56 基线同挂——排除。

**复现序列（已固化）**：重启 dev 实例 → 跑 agent-eval（无 --fixtures）→
E9（41KB 工具结果大文本）必过 → E14（纯 HTTP）→ E16 send 后僵尸。昨天同
序列 79/79 全过 = **概率性**（流式分块时序敏感——0.8.55 第一例也是"只在流式
中间态出现"）。

**根因候选（按先验排序）**：
1. **MarkdownRendererView 流式中间态的 AttributedString 失效索引**（0.8.55
   第一例同源；41KB BIGTEXT 流式渲染是高危场景；"块数 >120 退化纯文本"防护
   在 isLive 生效前的窗口期不覆盖）。这类崩溃"已落盘的消息复现不出来"——与
   本例"昨天过今天挂"吻合。
2. 收尾路径（generateTitle/记忆整理/自评）的 Foundation 大文本操作。
3. 其它 41KB 文本上的 NSAttributedString/正则（审计覆盖）。

**真缺口**：
- `RuntimeHealthMonitor` 只抓**主线程 stall**（心跳阻塞）——抓不到**主 actor
  僵尸**（主线程 run loop 空闲、任务只排队）。僵尸无任何报警路径。
- execution-e2e 无分节（0.8.57 的 --keep-going 只保证失败不吞结果）。
- agent-eval 无 --only 过滤（一跑 15+ 分钟，调试单用例不便）。

## 二、四主题

### ① Agent 基础（旗舰）＝ 僵尸专项 + 常驻探针

1. **复现固化**：`tests/zombie-repro.sh`——重启实例 → 单跑 E9 场景（假端点
   BIGSTREAM 大文本回合）→ E16 场景 → 主 actor 探针判定（复用 lldb 手法或
   进程内标志）。目标是**确定性复现**（现在概率性——多轮循环 + 分块时序抖动）。
2. **二分定位**：E9 回合收尾与流式渲染路径逐段打点（LaunchAudit.mark 同款）；
   若确认 Markdown 流式中间态——按 0.8.55 的"保真探针"整套手法（逐字抠函数 +
   1/8 前缀模拟 + 看门狗）离线复现并修复；若在收尾路径——同法。
3. **修复**：定位后修根因；修不了根因时做**防御**（有风险的 Foundation 大文本
   操作包 autoreleasepool + 异常捕获护栏？——ObjC 异常无法 catch，防护只能靠
   修复；所以重点是修）。
4. **常驻主 actor 探针**（把判定手法产品化）：RuntimeHealthMonitor 扩——
   后台 watchdog 每 5s 投一个 `Task { @MainActor in flag = true }`，**3 个周期
   （15s）未翻转 = 僵尸** → fault 日志 + `health/actor.json` + `/diag/startup`
   增 `actorHealthy` 字段 + 通知分级（urgent）。与既有 stall 检测并列成
   "两种死法都看得见"。

### ② 浏览器基础（测试基建）＝ execution-e2e 分节

- `--section <name>`：单节独立跑（各节前置自包含——现在 MUSCLE 段共享
  main 里的局部状态，重构为每节一个闭包 + 统一前置/清理注册表）；
  `--sections fast` 快档预设（CI 日常）；全量保留给里程碑。
- 0.8.56/0.8.57 的轮换失败类（splitView/收件箱/阅读进度）逐节定位——
  分节重启实例即消，预期全部转稳。

### ③ Agent 基础第二件 ＝ 评估可用性

- agent-eval `--only E21,E9` 过滤参数（调试单用例）；
- E19/E20/E21 归入 release-smoke 可选档（`--eval-heavy`，本地跑）；
- 评估结果进 run summary（CI）与 `GET /diag/eval` 快照。

### ④ 融合 ＝ 产物 → 继续干活的小闭环

- **白板 → ImagePro**：白板导出图一键进编辑器（BoardRenderService 已有渲染）；
- ArtifactsPanel 行加**缩略卡**（image/folder 首图缩略——ThumbnailStore 复用）。

### 贯穿（可靠性 / 可发现性）

- AGENTS.md 僵尸判定手法更新（第 3 例证据链 + 探针用法）；
- 纯逻辑（探针状态机、分节注册表）进 harness；i18n/WhatsNew。

## 三、不做（本版明确）

- Remote 产物卡 UI（iOS 端发版节奏）——记档后延。
- 响应式 pixelRatio（同上）。
- 跨设备产物同步、新作业类型（0.8.57 口径延续）。
- Markdown 渲染器重写（只修流式中间态的具体异常）。
- 评估集自动扩面（手动 fixture 仍是最有效语料）。

## 四、批次

- **批 1（旗舰）**：复现固化 → 二分定位 → 修复 + 常驻探针 + diag 字段。
- **批 2（分节）**：execution-e2e 每节闭包化 + --section/--sections fast +
  轮换失败类逐节定位转稳。
- **批 3（评估可用性 + 融合小件）**：--only + E19/E20/E21 归 smoke 档 +
  白板→ImagePro + 产物缩略卡。
- **批 4（收口）**：AGENTS.md/i18n/WhatsNew + Release 闸门。

## 五、验收

1. **僵尸复现→修复闭环**：zombie-repro.sh 稳定复现 → 修复后 20 轮循环 0 僵尸。
2. **常驻探针**：人为注入僵尸态（探针模拟）→ 15s 内 fault + actorHealthy=false
   + urgent 通知；健康时全绿。
3. **分节**：`--section muscle14` 独立跑稳定；`--sections fast` ≤ 全量 1/3 时长；
   轮换失败类 3 连跑全绿。
4. **eval 可用性**：`--only E21` 30 秒内出结果。
5. **融合**：白板导出图一键进 ImagePro；产物行有缩略卡。
6. **闸门**：harness 全绿、Release clean 零警告、双架构 CI 绿、smoke 全过。

## 六、版本口径

- 版本号 v0.8.58（构建号 598）；发版流程照旧。
