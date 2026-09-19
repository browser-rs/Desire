# 更新日志 (Changelog)

本文件记录 Desire 的所有显著变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号采用 0.x 阶段的宽松语义（次版本 = 功能主题，补丁版本 = 修复与小 UX）。

## [Unreleased]

### 0.2.7 — 修改密码检测（进行中）

### Added

- **密码生成器**：PasswordGeneratorSheet（SecRandomCopyBytes + 长度
  滑块 8–64 + 符号开关 + 复制/重新生成）。
- **CSV 导入导出**：Chrome 兼容列格式（name,url,username,password），
  面板工具栏按钮 + 文件选择器/保存面板。

## [v0.2.6] - 2026-09-19

### Added

- **密码生成器**：PasswordGeneratorSheet——SecRandomCopyBytes + 长度
  滑块 (8–64) + 符号开关 + 复制/重新生成。
- **CSV 导入导出**：Chrome 兼容列格式（name,url,username,password），
  面板工具栏按钮 + 文件选择器/保存面板。
- 密码面板新增 Generate / Import CSV / Export CSV 工具栏按钮。

## [v0.2.5] - 2026-09-19

### 0.2.6 密码中心（进行中）

### Added

- **密码生成器**：PasswordGeneratorSheet——SecureRandom + 长度滑块
  (8–64) + 符号开关 + 复制/重新生成。
- **CSV 导入导出**：Chrome 兼容列格式（name,url,username,password），
  面板工具栏按钮 + 文件选择器/保存面板。
- 密码面板新增 Generate / Import CSV / Export CSV 工具栏按钮。

## [v0.2.5] - 2026-09-19

（无）

## [v0.2.5] - 2026-09-19

### Added

- **审批策略引擎**：ApprovalPolicyStore——按工具名的持久化 allow/deny
  规则（DiskStore），deny 对 dangerous 工具也生效（显式拒绝优先于
  内置白名单），allow 自动放行（不弹审批）。
- **审批历史日志**：每次决策（UI/桥/策略来源）记录工具/决策/时间，
  持久化最近 200 条；桥 GET /approvals/history 查询。
- 桥 /approvals/policy（list/add/remove/clear）全量端点。
- simulate 审批工具改走真实 gate() 路径——策略规则可被 E2E 验证。

### Verified

- add deny → simulate → 自动拒绝（pending=false）；remove → simulate →
  正常挂审批；add allow → simulate → 自动放行（历史含 allowed-policy）。

## [v0.2.4] - 2026-09-19

### Added

- **MCP 窗口绑定**：客户端 initialize 时声明 params._meta.desireWindow
  （窗口会话 UUID），后续工具调用默认作用于那个窗口；per-call window
  参数可覆盖。桥 X-Desire-Window 头透传。
- README 补充 MCP 鉴权与窗口绑定文档。

### Verified

- 双窗口 E2E：initialize 绑定 W1 → MCP navigate → W1 正确导航。

## [v0.2.3] - 2026-09-19

### Added

- **应用内更新横幅**：新版本时顶部显示（版本号 + 查看发布页 + 关闭）。
- **设置 ▸ System ▸ Check for Updates**：手动检查按钮，实时反馈
  （最新 tag / 已是最新 / 失败原因）。
- UpdateChecker 升级为 ObservableObject，横幅与设置页共享同一实例。

## [v0.2.2] - 2026-09-19

### Added

- **内存压力驱动标签休眠**：DispatchSourceMemoryPressure WARNING 事件
  触发按 LRU 挂起非活跃后台标签（豁免：选中/固定/无痕/播放音频）。
  零轮询。

### Fixed

- suspendIdleTabs 清理（前次编辑残留死代码）；TabManager 补 os import。

## [v0.2.1] - 2026-09-19

### Added

- **常驻书签栏**：工具栏下方横条——叶子直达导航、文件夹下拉、与书签
  面板/星标同源。默认显示，可关。
- **剪贴板 URL 直达**：地址栏聚焦且剪贴板为 URL 时建议首行出现
  打开剪贴板链接（scheme/www./IP 三模式检测）。

## [v0.2.0] - 2026-09-19

> 0.2 弧线首版：外部 AI 完全体。

### Added

- **MCP Server 鉴权**：--mcp-token（Bearer，全部请求 401 门禁；默认
  localhost 裸奔不变）。五场景实测全过。
- **桥 /events 心跳**：15 秒 keep-alive——死连接以发送错误浮出并自动清理。
- **官方驱动示例**：examples/desire-driver.py（实测跑通）、
  examples/desire-mcp-driver.ts（零依赖 MCP 客户端）。
- README AI/Automation 章节；ROADMAP 标记 0.1.x 全部完成。

## [v0.1.16] - 2026-09-18

### Added

- **⌘K 命令面板**：30 个浏览器命令的模糊搜索统一入口（前缀优先排序、
  键盘导航）——BrowserCommand 枚举即清单。commandPalette 映射进快捷键
  设置（默认 ⌘K）。
- **全页截图上 MCP**：fullPageScreenshot——整页 PDF 到
  ~/desire_fullpage.pdf。

## [v0.1.15] - 2026-09-18

### Added

- **记忆作用域**：MemoryFact 新增 scope（global / 域名），按域事实仅
  在当前页面匹配该域时注入提示词。
- **记忆管理上桥**：GET /memory + facts add/update/delete。
- **技能管理上桥**：GET /skills + reload/delete/import。

### Verified

- 全局 + 按域事实入库、技能导入→列表→删除全链路。

## [v0.1.14] - 2026-09-18

### Added

- **拦截规则录制**：POST /intercept/record——网络日志请求一键转 block
  规则；MCP 工具 recordInterceptRules。
- **真实网络捕获**：主框架响应记录进 DevTools 网络面板（此前面板只有
  占位数据）。

### Changed

- 响应式/节流诚实结论：WebKit 无真网络节流 API，路线图三项标记为
  平台限制关闭。

## [v0.1.13] - 2026-09-18

### Added

- **网络拦截 v1**：InterceptStore——block/redirect 规则经
  WKContentRuleList 编译分发到全部 webview（立即生效、持久化）。
- 桥 /intercept 四端点；MCP 工具 27 → 30。

### Verified

- /tracker.js 无规则命中 1 次 → block 规则 → 命中 0 次。

## [v0.1.12] - 2026-09-18

### Added

- **媒体流水线技能包**：media-pipeline 伞形技能（幂等 seed）。
- **Agent 工具 downloadFile**。
- **媒体上 MCP（24 → 27）**：listPageVideos / downloadFile / downloadMedia
  （后台执行）。

## [v0.1.11] - 2026-09-18

### Added

- **结构化提取**：POST /extract——表格/列表 → JSON 或 CSV（正确转义）。
- **MCP 工具 21 → 24** + const 参数支持。

## [v0.1.10] - 2026-09-18

### Added

- **页面监控**：隐藏 webview diff 检测 → 通知 + pageWatchChanged SSE。
- 桥 /watches 五端点；MCP 工具 17 → 21。

## [v0.1.9] - 2026-09-18

### Added

- **定时任务运行历史**：RunRecord 持久化 100 条 + turn 结果回传 +
  失败通知/重试 + tasks/enable。

## [v0.1.8] - 2026-09-18

### Added

- **多窗口 Agent 联动**：会话注册表 + /agent/windows + 按窗路由。
- 双窗口投递零泄漏实测。

## [v0.1.7] - 2026-09-18

### Added

- **MCP 工具 9 → 17** + GET /mcp 事件推送（SSE）+ DELETE 语义。

### Fixed

- GET 分支静默未命中修复。

## [v0.1.6] - 2026-09-18

### Added

- **Desire 作为 MCP Server**（9 工具）+ 桥 /mcp/add|reconnect。

### Fixed

- MCPConnection 显式 init（旧编译器合成 init 为 private，CI 失败）；
  按 Content-Length 累积读取（分段发送导致真实客户端 400）。

### Verified

- 自举：Desire MCPClient → 自家 MCPServer ready · 9 tools。

## [v0.1.5] - 2026-09-18

### Added

- **桥自描述 GET /**：68 端点 + 8 类事件机器可读目录。
- **可选 token 鉴权**：--automation-token。
- docs/BRIDGE.md 速查。

### Fixed

- release.yml grep 正则坑改 -F。

## [v0.1.4] - 2026-09-18

### Added

- **桥事件流 GET /events（SSE）**：8 类事件，BridgeEventBus 总线。

### Verified

- navigate → pageReady → 下载 → complete 完整事件流（4MB）。

## [v0.1.3] - 2026-09-18

### Added

- CI 启动冒烟 + x86_64 检查；冷启动打点（232ms/预算 400ms）；
  诊断导出按钮。

### Fixed

- 启动打点报 0ms（静态懒初始化）——显式锚定。

## [v0.1.2] - 2026-09-18

### Added

- **存储页面（⌘S）**：webarchive + 下载行 + savePage 命令。
- **NoticeBar 提示条组件**；密码「永不为此站点保存」。
- 下载通知聚合 + Dock 角标。

### Changed

- 密码保存 sheet → NoticeBar；beforeunload 确认 → 同一组件。

## [v0.1.1] - 2026-09-18

### Fixed

- **BUG-K 优雅退出挂起**：SIGTERM/SIGINT DispatchSource 接管转
  NSApp.terminate——与 Cmd+Q 同路径。100 轮压测 0 挂起。

### Added

- ShutdownDiagnostics 终止清单日志；桥 /agent/tasks 四端点 +
  /approvals/simulate。

## [v0.1.0] - 2026-09-18

首个 tag 发布。

### Added

- 中键操作、beforeunload 表单保护、快捷键设置页接线、下载面板重设计、
  桥端点大批量扩展（40+）。

### Fixed

- 下载竞态、无痕隔离、假活行、进度恒 0、handler 崩溃、查找计数、
  会话恢复、阅读模式、密码弹窗、IP 强升 https。
