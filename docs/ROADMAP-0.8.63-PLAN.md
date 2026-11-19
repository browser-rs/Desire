# v0.8.63 规划稿（2026-11-17）—— 随身产物：融合旗舰 + 值守收尾 + 统计可视（丰富版·四主题全覆盖）

> **主题叙事**：融合主题自 0.8.38 后缺席旗舰——兑现 0.8.57 遗留的"Remote 产物卡
> UI（iOS 端）"为旗舰，同时把 0.8.60-62 三版 Agent 能力沉淀的**数据**（校准比率、
> 使用反馈、值守记录）首次上屏/进简报，浏览器基础明确"反馈修复预留"（核实
> 否决了隐私统计候选：CSS 拦截天然不可数，无可靠数据源）。规划前核实：iOS
> DesireRemote 九视图无产物视图（真空白）；产物推送通知已存在（deliver 终态口
> 调 notifyBackgroundJob，0.8.57——排除）；隐私统计无数据源（否决）；值守月报
> 数据源 = JobWatchStore.watches 现有字段可派生（deliveredAt/resumeUsed）。
> **批 1-3 已落地**（28637d01/e7c1e419/6211f373/daf7b43d/1793dfa7——SessionGuard
> 等解锁重发链、记忆排序档+徽标、iOS 产物卡模拟器构建绿、激活探针共享化）。

## 四主题

### ① 融合（旗舰，批 2-3 已落地 + 批 6 增强）
- **iOS 产物卡**（已落地）：ArtifactsView（列表/kind 图标/下拉刷新）+
  ArtifactDetailView（元信息/复制路径/**发回再加工**）+ AgentHome"产物"入口 +
  **iOS 模拟器构建绿**。
- **批 4 增强（已完成）**：桌面 `/artifacts` 增 `sizeBytes`（文件 stat
  现查 ArtifactIndex.withSizes，文件夹 null）+ iOS 端显示大小；kind/days
  过滤 0.8.57 已有（kind 值 = folder/image/video/…，非 file|folder）。
- **真机联调**（用户参与环节）：手机装 Remote 配对后验收产物卡三屏
  （列表/详情/发回再加工）。

### ② Agent 基础（批 1 已落地 + 批 4 增强）
- **批 1 已落地**：SessionGuard（NSWorkspace 探针，System Events 误报不采）+
  `.handle` 等解锁重发链（15s utility tick，不消耗 resumeUsed）+ JobsPanel
  "等解锁"胶囊；**记忆排序档**（最近更新/最常用/最近使用，sortFacts 4 单测）
  + 记忆行使用反馈徽标。
- **批 4 增强 = token 校准可视化**（0.8.60 数据首次上屏）：设置诊断页 +
  `GET /diag/health` 增"模型校准"段——每模型的窗口 tokens（档案设值/默认表）、
  校准样本数、EMA 比率、**当前生效字符预算**（全局换算值；会话级
  compactionBudgetOverride 不在此端点反映）——校准是否在干活一目了然。
- **.handle 等解锁已含于批 1**（见上）。

### ③ 浏览器基础 = 反馈修复预留
- 0.8.62 翻译 2.0 / 0.8.60-61 的校准/值守/记忆进入真实使用期——**预留反馈
  修复批**（不预规划具体项）。
- **核实否决记录**：隐私/拦截统计报告候选否决（CSS 拦截天然不可数，无可靠
  数据源——除非引入每页扫描统计，开销/可靠性不成立）。

### ④ 替人干活 = 值守月报进每日简报
- **DailyBrief 增"值守段"**：Input 增 `watchHandledCount`（今日 resumeUsed=
  true 的 watch 数）+ `watchQueuedCount`（当前等解锁挂起数）——今日 Agent
  自主处置了几件后台任务一目了然（数据源 = JobWatchStore.watches 现有字段
  派生，无新存储）。
- DailyBrief.compose 的值守段文案（0 项不显示，同既有段模式）。

### 工程（贯穿）
- **批 4 已落地**：激活探针共享化（tests/e2e_lib/activation.py，-I 模式
  sys.path 修复）；**批 6 增 = E27 翻译缓存 E2E**（fixture 页面 → 桥 bilingual
  → 断言缓存文件/二次命中零模型调用——0.8.62 活体验证手法固化成用例，
  agent-eval 本地专属档）。

## 批次（实况更新）

批 1 SessionGuard+等解锁重发+记忆排序徽标（28637d01 ✓）→ 批 2 iOS 产物卡
（e7c1e419 ✓）→ 批 3 激活探针共享化+190 干净 EXIT=0（f1df5060 ✓）→
批 4 完成：/artifacts sizeBytes 现查（withSizes 3 单测）+ token 校准可视化
（/diag/health 活体验证）→ 值守月报（DailyBrief 值守段+i18n 三语）→
E27 翻译缓存 E2E 绿灯（12/12，第二遍零模型调用）+ /ai/calibration/prune
（评估收尾清假模型校准）→ 收口（AGENTS/WhatsNew）→ **真机联调（用户）**。

## 不做

新 Agent 能力大件（休整等反馈）；隐私统计报告（数据源否决）；第三方翻译
引擎；--section；批量下载新能力；iOS QuickLook 远程预览。

## 风险

- iOS 构建依赖 SPM（GitHub）——当前网络时好时坏，构建验证顺延。
- 真机联调需用户配对参与（已标注）。
- DailyBrief 值守段依赖 JobWatchStore 现有字段（无新存储）——聚合口径
  与 JobsPanel 显示一致（同一派生逻辑，抽纯函数共用）。
