# v0.8.63 规划稿（2026-11-17）—— 随身产物：融合旗舰（iOS 产物卡）+ 值守收尾

> **主题叙事**：融合主题自 0.8.38「连成一片」后缺席旗舰——0.8.57 遗留的
> "Remote 产物卡 UI（iOS 端）"是明确的欠账：桌面端 0.8.57 已有产物中心
> （desire://artifacts + /artifacts 端点 + 作业产物自动入库），iOS DesireRemote
> 已有完整的连接/加密/通知/Agent 视图（九个 View）——**唯独没有产物视图**，
> 手机上看不到"电脑上 Agent 刚产出的东西"。本版补上这块，同时把 0.8.60/62
> 的两件小遗留收掉。规划前核实：iOS 工程九视图无产物视图（真空白）；
> 长截图（fullPageScreenshot）已存在（排除）；0.8.62 批 4 的".handle 等解锁"
> 未实施（真遗留）；iOS 工程依赖 SPM 远程包（swift-cmark/NetworkImage），
> 构建验证需要网络正常。

## 四主题

### ① 融合（旗舰）= iOS 产物卡
- **数据面**（已有）：`GET /artifacts`（列表/元数据/路径，0.8.57 桥端点）——
  iOS Remote 走既有 RemoteClient（加密 RPC 同管线）。
- **iOS 端**：
  · `ArtifactsView`：产物列表（类型图标/名称/大小/来源作业/时间排序）、
    分节（Converted/Extracted/Merged/…按 artifactType）、下拉刷新；
  · `ArtifactDetailView`：元数据 + 内容预览（文本类直接显示；图片类走
    NetworkImage；PDF/Office 类显示元信息 + "在 Mac 上打开"按钮）；
  · **发回再加工**：复用 Remote 既有指令通道（agent-send 语义）——产物详情
    页一键"让 Agent 对此产物继续加工"（预填提示词发回桌面 Agent）；
  · **RemoteModels** 解码扩展（Artifact 元数据结构）。
- **桌面端配合**：`/artifacts` 若缺 iOS 需要的字段（预览类型判定所需的
  mime/扩展名）增量补齐。
- **验证**：macOS 侧 `/artifacts` 探针已有（release-smoke）；iOS 端构建验证
  （xcodebuild 模拟器目标）+ **真机联调需要用户配对参与**（标注）。

### ② Agent 基础 = 值守处置收尾（0.8.62 遗留）
- **SessionGuard**：锁屏/无 frontmost 检测的工具化（NSWorkspace.frontmostApplication
  探针——0.8.62 批 4 实测它在锁屏/后台态语义清晰）；
- `.handle` 处置回合发起前的 guard：屏幕锁定时**不发起**（浏览器类处置动作
  会静默失效——0.8.61 教训），watch 标记"等解锁"（firedConditionKinds 保留、
  resumeUsed 不消耗），解锁后条件轮询自动重发；
- JobsPanel 的订阅行显示"等解锁"状态。
- **测试**：guard 判定纯逻辑进 harness。

### ③ 浏览器基础 = 打磨预留（反馈驱动）
- 0.8.60-62 三版的新能力（token 校准/值守处置/翻译缓存）进入真实使用期——
  预留"反馈修复批"（不预规划具体项，按反馈热修）。
- **记忆面板"最近常用"排序**（0.8.62 批 4 遗留收口：usageCount 数据已有
  徽标，排序入口本次补上——factSections 排序加"最近常用"档）。

### ④ 工程
- **激活探针共享化**：execution-e2e 与 agent-eval 的 activation_active()
  两份重复代码合并为 `tests/e2e_lib/activation.py`（0.8.60 遗留）。
- iOS 产物卡的桌面端数据面探针进 release-smoke 可选档。

## 批次

批 1 SessionGuard + 记忆"最近常用"排序（收尾遗留，纯逻辑）→ 批 2 iOS
RemoteModels + ArtifactsView/DetailView → 批 3 发回再加工 + 桌面字段补齐 →
批 4 构建验证（网络恢复后）+ 激活探针共享化 + 收口（i18n/AGENTS/WhatsNew）。

## 不做

Agent 大件继续休整（校准/处置/记忆/翻译的真实反馈仍在积累）；第三方翻译
引擎；--section（190 全绿 + fail-fast 已入，优先级低）；批量下载新能力
（上一轮已极深，等待真实反馈）。

## 风险

- iOS 工程构建依赖 SPM 远程包——**当前代理/DNS 对 GitHub 异常**，构建验证
  顺延至网络恢复；产物卡视图代码先行。
- 真机联调需要用户（手机配对/远程开关）——标注为用户参与环节。
- /artifacts 字段若与 iOS 解码对不齐——以桌面端 `/artifacts` 实际响应为准
  （先抓真实响应再写 RemoteModels，避免拍脑袋字段）。
