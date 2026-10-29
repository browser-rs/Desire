# 使用模式（Agent / 浏览器 / 混合）设计稿

状态：v0.8.23 规划期设计（2026-10-30）。实现前先过 spike（文末）。

## 1. 目标与硬约束

目标：让"Agent 干活"和"用户浏览"不再互相干扰，同时不牺牲现有浏览体验。

硬约束（违反即方案作废）：

1. **绝不跨窗口搬 WKWebView**（reparent 后 SwiftUI 会覆盖 frame，全屏/黑屏
   历史事故）。
2. **Agent 的后台路径不许抢焦点**：不 `NSApp.activate`、不 `makeKey`、不切用户
   标签、不滚动用户页面。需要人时走 Peek / 通知。
3. **模式切换不丢东西**：对话、标签、排队消息、在跑回合、审批卡都要有落点。
4. **窗口角色必须落盘**：重启、崩溃、强杀后都能把"A"认回 A。
5. **网站自己的拖放/快捷键等页面行为不受影响**（同拖放修复的纪律）。

## 2. 现状实证（2026-10-30 核实，设计据此落地）

| 能力 | 现状 |
|---|---|
| 主窗口 | `WindowGroup(id:"main")`，窗口 UUID → `session-<uuid>.json` 独立会话 |
| 多窗口恢复 | **只有崩溃路径**会补开其他窗口；干净重启只恢复首窗（SessionRestore.restoreAdditionalWindows 有 `launchedAfterCrash` 闸） |
| 窗口级会话/工具面 | 有：`AgentScheduler.liveSessions()`、`WindowToolSurface(tabManager:)` |
| 容器隔离 | 有：`TabContainer` + `ContainerStore.dataStore(for:)`；`SavedTab.containerID` 随会话落盘 |
| Agent 独立窗口 | 只是浮动 `NSPanel`（`AgentFloatingPanel`），无浏览内容 |
| 使用模式 | **无**（`AgentMode` 是工具子集，不是界面模式） |
| 焦点违规 | `newWindow` 工具会 `NSApp.activate` + 强制 key；其余激活路径基本是用户动作 |
| 离屏 webview 先例 | 有：`URLReader`/`ReadingListCache` 用窗口外 `WKWebView` 取正文 |

## 3. 三种模式（定稿）

| | 界面 | 浏览器在哪 | Agent 操作对象 | 打扰规则 |
|---|---|---|---|---|
| **Agent 专注** | **单窗工作台**：对话 + 目的地侧栏 + **可折叠内嵌浏览面板** | 内嵌面板的标签（折叠=后台） | 面板自己的 `TabManager` | 不抢焦点；Peek=面板就地展开 |
| **纯浏览器** | 现状 | 用户窗口 | 用户当前窗口（现状） | 现状 |
| **混合** | **两个完整浏览器窗口**：用户的 / Agent 的 | 用户窗口 + Agent 窗口（独立容器） | 默认 Agent 窗口 | 互不抢焦点；Peek=非激活浮层 |

## 4. 模式一：为什么是"单窗 + 内嵌面板"，不是"工作台 + 隐藏浏览窗口"

上一稿写的是"工作台窗口 + 后台隐藏的浏览窗口"，调研后否掉：

- **隐藏窗口没有干净做法**：SwiftUI `openWindow` 必然前置；创建后立刻 `orderOut`
  会闪一下，且首次创建必抢一次 key；而 `orderOut` 的主窗口在 Dock/Mission
  Control/窗口菜单里的行为还要额外兜。
- **同窗内嵌面板零焦点问题**：面板就在已激活的工作台窗口里，展开/收起只是
  SwiftUI 布局变化，不涉及任何窗口激活。
- **离屏 webview 有现成先例**：折叠时面板视图移出层级，但 `TabManager` 与
  `WKWebView` 仍存活——读页面/导航/JS 属于既有可验证能力（spike 1 确认）。

### 折叠语义（需 spike 定稿）

- 折叠 = 面板视图从 SwiftUI 层级移除（不是 0×0、不是 opacity 隐藏——0×0 在
  WebKit/VisionKit 有 NaN 事故史）。
- 折叠期间：标签仍可导航、`evaluateJavaScript`/`getPageText`/`getPageHTML`
  仍可用（spike 1）；需要真实点击/登录时才 Peek 展开。
- 展开 = 把面板放回层级并恢复其 `TabManager.selectedTab` 的 webview；**不做
  reparent**，视图始终属于同一窗口。

### 工作台窗口内容

- 顶栏：模式徽标、迷你浏览条（spike 2 后加缩略图）、"展开/收起浏览面板"。
- 主区：对话（`AgentPanel` 复用）+ 目的地侧栏（任务/技能/记忆/统计/轨迹/
  能力/体检，复用 `AgentWindowRoot`）。
- 浏览面板：紧凑标签条 + 地址栏 + `WebView`（`WebViewContainer`）。

## 5. 模式三：双窗口 + 独立容器

- 用户窗口：现状；Agent 侧栏默认收起（可选）。
- Agent 窗口：完整浏览器窗口（标签栏/地址栏/侧栏），角色 `agent`，默认使用
  **Agent 专用容器**（`ContainerStore.addContainer("Agent")`，只建一次）。
- 两窗可手动平铺；提供菜单"并排 Agent 与浏览窗口"（只调整窗口 frame，不做
  应用内分屏）。
- Peek：**非激活浮层**（`NSPanel` + `.nonactivatingPanel`）显示 Agent 窗口当前
  页面的快照 + 原因 + "去处理"按钮；点击才激活——默认不打断用户正在打的字。

## 6. 实体与持久化

```
AppUsageMode: agentFocus | browser | hybrid        // UserDefaults "app.usageMode"
WindowRole: user | agent                            // 与 mode 正交
WindowRoleRegistry: sessionKey -> { role, containerID?, createdAt }
  // DiskStore "window-roles"（session-index 是 [String]，不能直接塞结构）
Adoption 过滤: mostRecentSessionKey / crashRestoreSessionKeys
  // 必须跳过 role == agent 的会话，否则 Agent 会话会被首窗收养
```

- 角色写在 `TabManager` 注册时（窗口创建时按会话 key 查注册表；缺省 = user）。
- 模式一不创建浏览器主窗口；工作台的浏览面板有自己的 `TabManager`
  （sessionKey 固定 `agent-pane`，随窗口关闭归档）。
- 模式三首次进入：若注册表里有 agent 会话 → 静默补开（spike 3）；没有 → 创建
  一扇 agent 窗口并写入角色。

## 7. 工具目标解析（单点）

```swift
enum AgentSurface { case pane, agentWindow, userWindow }

func resolveTarget(session, mode, explicitWindow) -> TabManager? {
  if explicitWindow == "user" { return userManager }            // 危险动作走审批
  switch mode {
  case .browser:    return session.ownManager                   // 现状
  case .agentFocus: return AgentPaneManager.shared             // 折叠也能读
  case .hybrid:     return agentWindowManager ?? createSilently()
  }
}
```

- 所有工具/MCP/crew/handoff/Remote 都走这一个入口（本次一并收口，别再各自猜
  `activeTabManager`）。
- `<usage_mode>` 注入系统提示词：模式名、可操作面、默认目标、Peek 规则、
  "不许抢焦点"。

## 8. Peek 协议（状态机）

```
idle → requested(reason) → visible → resolved(completed|dismissed|timeout) → idle
```

- 触发：① 用户点迷你条；② Agent 调 `requestUserHelp(reason, needsPage)`；
  ③ 审批卡"看现场"。
- 模式一：展开内嵌面板 + 顶部横幅（原因 + "完成，收起"）；焦点不变（工作台
  本来就是 key）。超时（默认 5 分钟）自动收起并标记 timeout。
- 模式三：非激活浮层 + 菜单栏/工具条徽标；用户点"去处理"才激活 Agent 窗口。
- Agent 回合**不阻塞**在 Peek 上：`requestUserHelp` 立刻返回请求 id，回合继续；
  用户完成后写一条系统备注（`Peek resolved: …`）告知模型。

## 9. 接管锁

- 用户接管某面板/窗口期间（Peek 打开或点"接管"），该 `TabManager` 加锁：
  Agent 工具的目标解析命中即返回 `Error: surface is being used by the user`。
- 归还时记录前后快照（URL/title/表单是否变化），作为系统备注交给 Agent。
- 锁只在内存（进程重启自然解除）；UI 上明确显示"用户接管中"。

## 10. 焦点与打扰宪章（含现状违规清单）

- 规则：Agent 发起的任何路径不得激活应用/抢 key/切用户标签；例外只有 Peek 的
  用户点击。
- 现状需修的：`newWindow` 工具的无条件 activate/makeKey（模式一下应改为静默
  创建，模式三下由 Agent 窗口自带）。其余激活点（菜单栏快速入口、浮动面板、
  跨窗指示器）都是用户动作，保留。
- 回归探针：桥暴露 `GET /diag/windows`（role/key/title/frame），后台 Agent 操作
  前后断言 key 不变；静态扫描白名单外的 `NSApp.activate`。

## 11. 登录态与隔离（四种策略，按任务选）

业界可验证的三种隔离模型（扩展接管 / 持久档案 / 隔离会话）对应到我们：

| 策略 | 实现 | 隔离 | 登录态 | 并行 | 用在哪 |
|---|---|---|---|---|---|
| **持久容器**（默认） | `TabContainer` + 磁盘 data store | 中（cookie 独立） | 登录一次长期有效 | **单写者**（同一容器同时只能一个浏览器会话） | 模式一/三的 Agent 主会话 |
| **临时会话** | `WKWebsiteDataStore.nonPersistent()` | 高（内存，结束即清） | 无（可种子） | 可多开 | crew worker、一次性敏感任务 |
| **借用登录态** | 把用户档案的 **cookies** 拷进临时会话 | 中高 | 仅 cookie（localStorage/IndexedDB 不迁移，部分站点仍需重登） | 可多开 | 需要登录的一次性任务 |
| **沿用当前档案** | 设置项：Agent 直接用当前 profile | 低 | 完整 | 与用户共享 | 便利优先（审批链兜底） |

关键约束（来自可验证的同类实现）：

- **持久档案同一时刻只能一个实例用**——并行 Agent 必须各用临时会话或各自独立
  的容器，否则会互相踩 cookie。
- **登录态迁移只有 cookie 可靠**：localStorage/IndexedDB 不在通用迁移范围内，
  所以"借登录态"之后仍有站点要求重登，必须如实告知用户。
- 不做按站点混合登录态（同站两种会话容易串号）。

## 12. 恢复与迁移

- 重启：读 `AppUsageMode` + `WindowRoleRegistry`；browser/hybrid 恢复用户窗口
  （现有路径），hybrid 额外静默补开 agent 窗口；agentFocus 只开工作台。
- 崩溃：沿用崩溃恢复，但收养过滤掉 agent 会话。
- 关窗：关掉 agent 窗口不改角色（下次按需补开）；关掉工作台且 mode=agentFocus
  → 降到 browser 模式或提示，不留下"无窗"状态。
- 模式切换（有在跑回合）：默认让它跑完，输出进原会话；不静默取消。
- 强杀：角色注册表与普通会话同为 500ms 防抖落盘（DiskStore），与既有风险同级。

## 13. 验收口径（桥可测，不依赖真实鼠标）

1. `GET/POST /app/mode` 三模式往返；切换后 `/state` 的标签集合不变。
2. 混合模式：`POST /navigate` 落在 Agent 窗口；`/state`（用户窗口）的
   selected/url 不变；`/diag/windows` 的 key 不变。
3. 专注模式：折叠状态下 `getPageText`/`readTabs` 可用；`POST /peek {open:true}`
   展开、`{open:false}` 收起；key 始终是工作台。
4. 接管锁：`POST /peek` 打开后对同窗口 `navigate` 返回 `Error:`；
   关闭后恢复。
5. 重启：混合模式下重启，agent 窗口按角色恢复且不被收养为用户窗口。

## 14. 必须先过的 Spike（P0 闸门）

- **S1 离屏/折叠 webview**：折叠（移出层级）后 `load` / `evaluateJavaScript` /
  `document.body.innerText` 是否仍工作；定时器与 rAF 是否被节流（可接受，但
  要记录）；页面可见性 API 的表现。
- **S2 面板挂载稳定性**：反复展开/收起 50 次、全屏视频、VisionKit 关闭前提下
  无 0×0/NaN/崩溃；webview 不重建（`webView ===` 不变）。
- **S3 静默建窗**：混合模式首次进入时开 agent 窗口**不改变 key window**；若
  `openWindow` 做不到，评估 `NSWindow + NSHostingView(ContentView)` 方案。
- **S4 角色恢复**：注册表落盘 + 收养过滤，在干净重启/崩溃重启/强杀三种路径下
  都把 agent 会话认回 agent 窗口。

Spike 不过就降级：S1/S2 失败 → 模式一退回"工作台 + 浏览窗口并排（不隐藏）"；
S3 失败 → 混合模式首次进入需用户点一次"打开 Agent 窗口"。

## 15. 明确不做

- 同窗口双标签集/第二套标签栏；应用内任意分屏布局。
- 跨窗口 reparent webview。
- 改 `AgentMode`（standard/research/writing）语义。
- 按站点混合登录态；云端/多机模式。

## 16. 附：业界隔离模型对照（做法，不列出处）

调研只能验证到两类资料：开源 agent 浏览器框架的文档（可达）、AI 浏览器官方
帮助页（本次网络不可达，仅按公开常识归纳，不作为硬依据）。可验证的结论：

1. **扩展接管型**：Agent 连接用户**正在运行的浏览器**，在现有标签里操作，直接
   复用登录态。优点：零迁移、连续性最好；缺点：隔离最弱，必须假设用户可能随时
   接管，动作要有"元素可读描述"供人确认。→ 映射：我们的**纯浏览器模式**。
2. **持久档案型**：独立档案目录，登录一次长期有效；文档明确"**同一档案同时
   只能一个实例**"，并行必须换档案或隔离。→ 映射：**Agent 容器 / 模式一/三**。
3. **隔离会话型**：内存档案，关闭即清；可用 storage-state 预置登录态；适合
   一次性/不可信任务。→ 映射：**crew worker 与临时任务**。
4. **云/虚拟机型**：彻底隔离，登录态不共享，成本高、延迟大。→ **不做**。

对我们设计的三条直接修正（已并入路线图）：

- 并行任务必须**临时会话**或**独立容器**，不能共用一个"Agent 容器"
  （持久容器单写者）。
- "借登录态"只承诺 **cookies**，localStorage/IndexedDB 不迁移——写进 UI 文案。
- 人机确认卡要带**元素可读描述**（名字/角色/附近的可见文字），不只是选择器；
  参考实现里所有点击/输入工具都带 `element` 描述参数就是为这个。

## 17. 实现进度（2026-10-30）

- **Spike**：S1/S2 通过（折叠后仍可导航/取文/执行 JS；50 次挂载不崩、实例不变；
  折叠时定时器节流到约 1s）。S3 以策略解决（建窗只发生在用户切模式时）。
  S4 通过（browser/agentFocus/hybrid 三种干净重启路径均按角色恢复，用户窗不收养
  Agent 会话）。
- **已落地**：模式模型与切换（设置/菜单 ⌃⌘1-3/桥 `GET/POST /app/mode`）；
  窗口角色注册表 + 收养/归档过滤；混合模式自动补开 Agent 窗口（独立会话 +
  Agent 容器，Tab 容器随会话落盘）；专注模式工作台（对话 + 可折叠内嵌面板 +
  迷你条 + Peek 横幅）；Peek 协议（`requestUserHelp` / `/peek`，完成后页面前后
  对比写系统备注）；接管锁（`Error: surface is being used by the user`）；
  工具目标规则（专注→面板；混合→用户窗会话默认指向 Agent 窗）；`newWindow`
  专注模式禁用；模式切换在回合中延迟重配工具面；拖 URL/文本进页面（页面没接住
  时）。
- **未落地**：审批卡"看现场"按钮、拖文件到标签栏、工具栏模式徽标、首次切换引导、
  通知分级的模式联动、焦点回归探针进 CI、crew/handoff/Remote 的角色化解���、
  临时会话与 cookies 快照、登录态设置项。
