# 更新日志 (Changelog)

本文件记录 Desire 的所有显著变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号采用 0.x 阶段的宽松语义（次版本 = 功能主题，补丁版本 = 修复与小 UX）。

## [Unreleased]

### 计划中（见 [ROADMAP](ROADMAP.md)）

- 0.1.3 质量门：CI 启动冒烟、启动性能基线、MetricKit 诊断导出、x86_64 检查
- 0.1.4 桥事件流（SSE）…

## [v0.1.2] - 2026-09-18

### Added

- **存储页面（⌘S / File ▸ 存储页面…）**：当前页存为 webarchive 到下载文件夹，
  并在下载列表记录为完成行；快捷键设置里的 `savePage` 映射由此接线；
  桥新增 `savePage` 命令。
- **NoticeBar 提示条组件**：工具栏下方全宽非阻塞条（图标 + 标题 + 最多三个操作），
  取代抢焦点的 sheet——Agent 代操作时不再被打断。
- 密码保存提示的「**永不为此站点保存**」：按域持久化（UserDefaults）。
- 下载完成通知 **2 秒窗口聚合**：批量完成只弹一条（"已下载完成 N 个文件"）。
- **Dock 角标**实时显示活动下载数，空闲时清除。
- 操作 toast 通用化（图标 + 文案，1.8 秒自动消失），书签/存页共用。
- 桥：`savePage` 命令。

### Changed

- **密码保存提示**：sheet → NoticeBar（保存 / 暂不 / 永不为此站点）；
  桥 `/passwords/resolve` 代答链路不变。
- **beforeunload 离开确认**：sheet → 同一 NoticeBar 组件；
  桥 `/beforeunload` 流程不变。

### Fixed

- 本 SDK 的 `createWebArchiveData` 仅有 completion-handler 变体（无 async 形式），
  实现按此适配。

## [v0.1.1] - 2026-09-18

### Fixed

- **BUG-K 优雅退出挂起（挂账最久的已知问题）**：SIGTERM 默认处置是硬终止，
  WebKit 分线程拆除时竞态导致偶发卡在 exit。AppDelegate 安装 DispatchSource
  信号处理器，SIGTERM/SIGINT 转发 `NSApp.terminate(nil)`——与 Cmd+Q 同路径
  （applicationShouldTerminate → 会话 flush → 干净退出）。
  **100 轮 SIGTERM 压测：0 挂起**。

### Added

- **ShutdownDiagnostics**：终止时同步输出存活清单（URLSession 任务、活动/暂停
  下载、Agent 循环状态），fault 级日志；若复发可对照排查。
- 桥 `/agent/tasks`（list / create / remove / **fire**）：`fireNow` 立即投递
  定时任务提示词，无需等待调度周期。
- 桥 `/approvals/simulate`：在活会话上挂起一个**真 continuation** 的审批
  （不跑模型），外部驱动可确定性验证审批管线。

### Verified

- 审批全链路：simulate → pending → allow_once / deny → continuation 复归。
- 定时任务全链路：create → fire → 会话收到 `[定时任务]` 消息 → lastResult 更新 → remove。

## [v0.1.0] - 2026-09-18

首个 tag 发布（自 v0.1.0 起建立 CI 与发版流水线）。

### Added

- **中键操作**：中键关标签（TabMiddleClickMonitor：NSEvent 监视器 + 胶囊帧注册表，
  按 tab.id 实时解析关闭）；中键开链接（middle-click.js auxclick → 新标签）。
- **beforeunload 表单保护**：本版 WebKit 对无手势卸载不派发事件，故在
  decidePolicyFor 合成派发页面的监听器，拒绝离开时弹确认。
- **快捷键设置页接线**：共享 KeyboardShortcutStore + AppCommands 观察式菜单；
  补 newWindow/bookmarkPage/findNext/findPrevious/toggleAgentPanel 映射与
  forceReload/showDownloads 命令。改键持久化，重启生效（macOS 26 不支持
  实时重绑，已验证并记录）。
- 下载面板重设计：卡片行、文件类型色块、hover 渐显操作、修复头部裁切与
  类型筛选挤压；优先级移入右键菜单；新增复制链接。
- 桥端点大批量扩展：`/downloads/pause|resume`、`/execute`、`/panel`、
  `/panel/snapshot`（进程内渲染，捕获遮罩下可用）、`/beforeunload(/resolve)`、
  `/reader`、`/shortcuts(/update)`、`/site-settings(/darkmode,/zoom)`、
  `/quickdial(/add,/delete)`、`/elements(/add,/remove)`、`/command`（驱动全部
  BrowserCommand）、`/find`、`/tabs/pin`、`/reading-list*`、`/search-history*`、
  `/tabgroups*`、`/passwords*`、`/containers/remove`、`/bookmarks/add|remove`、
  `/suggest`；`/page/url` 增加 zoom、`/state` 增加 isActive/hasKeyWindow。

### Fixed

- **下载暂停→秒恢复竞态**：恢复请求先挂起，checkpoint 落地后触发；服务器
  不支持 Range 时删残件、复用原文件名重启。
- **无痕下载写入共享历史**：DownloadItem.isPrivate 隔离，面板带徽标。
- **暂停行跨重启变假活行**：HistoryItem.isPaused 持久化 + 暂停/恢复即时落盘。
- **URLSession 下载进度恒 0**：改 delegate 会话实时回传字节。
- **脚本消息 handler 重复注册崩溃**：observe/stopObserving 名单收敛 +
  先移除再注册（重复 add 在布局期抛 NSException）。
- **查找匹配计数恒 0**：TreeWalker.nextNode() 只返回布尔，文本在
  currentNode.nodeValue——旧代码必然抛异常被吞。
- **会话恢复断链**：macOS 不写 SwiftUI 窗口值，还原侧永不触发；首窗口
  现采纳退出索引中最近会话并重绑身份（尊重 startupBehavior 设置）。
- **阅读模式永远转圈**：先切视图再提取导致页面被挂起；改为提取完成后再切换。
- **密码保存阻塞式 runModal**：冻结主线程（含桥）；改 PendingPasswordSave
  非阻塞决策模型。
- **新书签永不进地址栏建议**：BookmarkStore.add 漏调 rebuildURLIndex。
- **地址栏 IP 字面量被强升 https**：IPv4 与 localhost 同样保持 http。
- **响应式模式 MQ bar 数组越界崩溃**（承接此前修复）。

### Security

- 沙盒移除后的 Keychain 域切换（容器 → login keychain，API key 需重存一次，
  预期行为）。
