# v0.8.52 规划稿 —— 窗口 2.0：多窗口恢复与窗口操作

> 基线：v0.8.51（2026-11-11，591）。本版把"窗口"从"能用多扇"补成
> **多窗口是一等公民**：退出后所有窗口按位置回来、误关的窗口能整窗找回、
> 标签能在窗口间显式移动/搜索、Agent 能定向某扇窗口干活。
>
> 规划前核实（2026-11-11）：以下能力**已有**，本版不重复规划——
> 地址栏候选下拉 / ↑↓ 选择 / Tab-to-Search / 自定义引擎关键字（0.8.6+）、
> 标签拖出成新窗与跨窗拖拽（0.2.13）、最近关闭标签面板（0.8.40，跨窗跨启动）、
> 标签搜索切换器（窗口内）、查找栏跨标签扫描（0.7.14）、书签栏（含一层文件夹）、
> 画中画 / 视频速度、内存压力挂起、会话快照 `.bak` 与无窗自愈（0.8.49）。

## 为什么是它（实测缺口，全部有现场）

1. **退出只恢复一扇窗**：`prepareForTermination` 把所有活窗口的 key 写进
   `session-index`（`[String]`），但启动时只有**首窗**采纳 index 里最近的
   一个 key（`mostRecentSessionKey`），其余窗口的会话文件随即被
   `pruneOrphanSessions` 归档——测试实测：三窗场景重启后只剩一窗，其余进
   `session-archives/`。
2. **窗口几何完全没有持久化**：全仓没有 `setFrameAutosaveName` / frame 落盘，
   重启后窗口回到系统默认位置；多屏用户每次都要重新摆。
3. **"恢复"只有覆盖当前窗这一种语义**：工作区恢复（`WorkspacePanel.restore`）、
   归档会话恢复（`restoreArchivedSession(into: manager)`）、最近关闭标签
   （`RecentlyClosedPanel.row` → `tabManager.reopen`）全部替换当前窗口标签；
   **没有"整窗重开"**——误关一扇 20 标签的窗口，只能靠"归档会话"面板找回，
   而且还得先牺牲当前窗口。
4. **没有窗口菜单面**：Window 菜单只有系统平铺项；没有窗口列表、没有
   Reopen Closed Window；标签右键没有"移动到新窗口/移动到某窗口"（拖拽能
   做到，但不可发现、不可脚本化）；标签搜索只扫本窗。
5. **Agent 不知道"窗口"这回事**：`listWindows/newWindow/closeWindow` 有了，
   但没有 `focusWindow` / `moveTabToWindow`；AGENTS 明文记着
   "多窗口 Agent 联动：未实现"。

## 旗舰（P0）：多窗口恢复 2.0

### 1. 窗口快照与索引（取代裸 key 数组）

- 新模型 `WindowSnapshot`（Foundation-only，进 harness）：
  `sessionKey` / `frame`(x,y,w,h) / `screenID?` / `role`(user|agent) /
  `isActive` / `lastActiveAt` / `tabCount` / `isMinimized`。
- 干净退出写 `window-index-v2`（**保留** 旧 `session-index` 同步写，老版本
  回退可用）；启动时读 v2，v1 缺失时按旧逻辑降级。
- 角色过滤：`role == .agent` 的窗口走既有角色恢复路径，不参与用户窗口
  批量恢复（避免 Agent 窗与用户窗互相顶）。

### 2. 启动多窗恢复

- 首窗照旧采纳"最近会话"；`.task` 里通过 `openWindow(id:"main", value:)`
  **逐个复活其余用户窗口**（复用 0.2.13 撕出窗口同一条 value-based 路径；
  每窗按自己的 key 恢复标签）。
- 恢复顺序按 `lastActiveAt` 降序，逐窗 `NSWindow.setFrame`（经
  `WindowSurfaceRegistry` 按 sessionKey 找 NSWindow；**可见区裁剪 + 同帧
  阶梯偏移**，多屏拔插不落屏外）。
- **异常退出（哨兵在）**：按 session 文件 mtime 恢复最近 ≤N（默认 5，
  设置可调）个**有标签**的用户窗口，并套 7 天年龄过滤——防测试残留/远古
  空窗复活（0.8.49 的教训：测试窗口会变成幽灵窗口）。
- 恢复失败单窗降级：不弹阻塞框，只在窗口里开新标签页并记日志；
  `LaunchWindowHealer` 从"首窗没起"扩展为"计划窗口少了 k 个"的一次补开。

### 3. 诊断与可观测

- `GET /diag/windows`（扩展既有）输出：每窗 sessionKey/frame/role/是否恢复/
  恢复耗时/计划数 vs 实际数；`/diag/startup` 带多窗恢复摘要。
- 日志：`window-restore: key=… frame=… role=… restored=…`（tabs category）。

## 四主题常规（各一件）

### 4. 浏览器基础（第二件）：窗口操作面

- **Window 菜单**：窗口列表（标题 + 标签数，点击聚焦）、
  **Reopen Closed Window**（Window 菜单显式项；⌘⇧T 在标签队列空时回退到
  最近关闭的窗口快照——Chrome 语义，⌘⇧N 已被「新建无痕标签」占用）、
  Bring All to Front 保留系统行为。
- **窗口快照**（`WindowSnapshotStore`，DiskStore `closed-windows`，cap 20）：
  用户关窗时记录 tabs（复用 SavedSession 序列化）+ frame + 关闭时间；
  RecentlyClosedPanel 加"Windows"分段，行内"整窗重开"= 开新窗口装快照；
  与标签最近关闭共用同一面板语义。
- **标签右键移动**：Move Tab to New Window（⌘ 拖等价）；Move Tab to Window ▸
  [窗口列表]（与拖拽同一条 `transferIn` 路径，保留 history 状态）。
- **跨窗标签搜索**：切换器加范围"本窗口 / 所有窗口"；所有窗口时按窗分组
  显示，回车 = 跳到该窗并选中该标签（`TabSessionCoordinator.manager(forSession:)`
  已有）。

### 5. Agent 基础：多窗口定向

- 工具：`focusWindow {id}`、`moveTabToWindow {tabID, windowID, index?}`；
  `listWindows` 回包补 frame/isActive/tabCount/role。
- 语义收敛：标签类工具**作用于本会话所在窗口**（现状 `deliveryTarget`），
  回包带 windowID；桥同名端点（`/windows/focus|move-tab|organize`）。
- 面板头部显示当前窗口标识（多窗时可见，避免"Agent 在操作哪扇窗"含糊）。

### 6. 融合：窗口快照 ↔ 工作区/归档统一

- `Workspace.restore` 增加语义选择：**替换当前窗 / 开新窗口**（新窗走
  value-based openWindow）；工作区保存带 frame（可选）。
- `SavedSession` 增加可选 `frame`（老文件缺键 nil，向后兼容），工作区与
  归档恢复都可"按保存时的位置开新窗"。
- 归档会话面板行内加"开新窗口恢复"（现在只有替换当前窗）。

### 7. 替人干活：窗口整理器 organizeWindows

- `organizeWindows {mode}`：`splitBySite`（按站点把某窗/全部窗的标签拆到
  多窗口，每窗一组 host）/ `mergeAll`（所有用户窗口合并为一窗）/
  `dedupe`（跨窗 URL 去重，保留最早窗口）/ `onlyHost {host}`（只留一组）。
- Agent 工具 + 桥 `/windows/organize`；标签数 >60 时走 **Jobs 台账**
  （进度 = 已迁移标签数，完成会话备注 + 通知），小批量直接同步返回。
- 全部走 `TabTransfer` 既有迁移路径（保 history/挂起状态），不新建搬运机制。

## 贯穿

- **可靠性**：恢复计划纯逻辑（`WindowRestoreCore`：上限/年龄/角色过滤/
  多屏 clamp/同帧阶梯）进 harness；退出、崩溃、无窗三条路径都有 E2E；
  绝不复活空窗与 Agent 窗（0.8.49 幽灵窗口教训）。
- **可发现性**：Window 菜单、⌘⇧N、设置页"窗口恢复"三档
  （全部窗口 / 仅上次活跃窗口 / 不恢复）；What's New 一条
  "多窗口原样回来"。
- **i18n**：新文案三语在提交时补齐（CLI 构建不抽键）。
- **性能**：多窗恢复只对**选中标签**急切加载，其余走挂起路径（复用
  `apply(session:)` 既有策略），恢复 N 窗不放大启动转圈。

## 不做

- 跨设备窗口布局同步（workspace 同步域已能带走标签集，布局不跟）。
- 用自研状态保存替代 SwiftUI 场景体系（只做"自家 session 文件"这一层）。
- 多屏像素级还原（超出可见区一律裁剪，不保证原样回多屏）。
- Agent 多窗联动全量（只做定向基础：focus/move/organize，不做跨窗编排）。
- 标签组跨窗口同步、窗口标签页自研（macOS WindowTab 归系统）。
- 书签栏多级文件夹/拖拽排序（本版暂缓，记入 0.8.53 候选）。

## 批次

1. **批 1（P0）**：`WindowSnapshot`/索引 v2 + 多窗恢复 + 崩溃上限 +
   `WindowRestoreCore` harness + `/diag/windows` 扩展。
2. **批 2**：Window 菜单 + ⌘⇧N + `WindowSnapshotStore` + RecentlyClosedPanel
   窗口段 + 标签移动菜单 + 跨窗标签搜索。
3. **批 3**：Agent 定向（focusWindow/moveTabToWindow/listWindows 增强）+
   桥 + organizeWindows（含 Jobs 大窗）+ 工作区/归档"开新窗"。
4. **批 4（收口）**：右键菜单补齐（Open in New Private Window / Download
   Linked File / Copy Link Text / 选区换引擎搜索）+ i18n/WhatsNew +
   多窗 E2E + Release 闸门。

## 验收

- 三窗（各自标签/位置/选中）→ 优雅退出 → 重启：**三窗全回来**，位置按
  可见区还原、标签与选中一致、顺序与退出前一致；空窗/Agent 窗不复活。
- 强杀（kill -9）→ 重启：恢复最近 ≤5 个有标签用户窗口；`/diag/windows`
  显示计划数/实际数/耗时；无窗时自愈路径仍可用。
- 关两扇窗 → Window 菜单逐个 Reopen Closed Window：tabs + frame 还原；
  20 次以内 cap 生效。
- Move Tab to Window：目标窗口出现该标签、history 可后退、源窗选中不跳错；
  跨窗搜索回车跳到目标窗并选中。
- organizeWindows 三模式：splitBySite 后各窗 host 单一；mergeAll 单窗含全部；
  dedupe 无跨窗重复 URL；>60 标签走 Jobs 且进度可查。
- harness 纯逻辑新增 ≥40 项；多窗 E2E 新增 ≥15 项；发版矩阵照旧
  （run.sh + release-smoke + Release clean 零警告）。

**发版**：用户说「发」才发。
