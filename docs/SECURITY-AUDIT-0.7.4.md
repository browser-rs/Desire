# 0.7.4 安全迭代 · 第一轮审计（2026-10-07）

范围 = 路线图 0.7.4 的五个面：**桥 / 提示注入 / 工具闸门 / 下载 / 插件面**。
本轮修复三件（P0×1、P1×2），确认健康四处，挂起四处（下一轮候选）。

## 修复

### 1. 桥：DNS rebinding 与浏览器跨站驱动（P0）

`--automation` 模式的桥（127.0.0.1:8799）此前不校验 Host/Origin。两条实弹攻击链：

- **跨站 no-cors POST**：浏览器里打开的恶意页面可
  `fetch('http://127.0.0.1:8799/agent/send', {method:'POST', mode:'no-cors', ...})`
  ——no-cors 允许 text/plain 简单请求、**不预检**，桥不挑 Content-Type，
  攻击者的指令直接作为 user 消息进 Agent（readonly 工具即时执行，
  其余走审批卡赌用户不在场）。`/navigate`、`/execute`、`/downloads/*` 同打。
- **DNS rebinding**：攻击者域名 A 记录改指 127.0.0.1 → 浏览器视其为同源
  → 不只驱动，还能**读到响应**（GET /page/text / /downloads 变成内幕读取）。

**修复**：请求进入 route 前过 `passesOriginGuard`——① Host 必须是
127.0.0.1/localhost（可带端口）；② 带 Origin 的请求必须源自本机
（curl/CI/MCP 客户端不带 Origin，不受影响；`Origin: null`（file:// 源）拒绝）。
拒绝回 403 并打 fault 日志（`automation bridge rejected: …`）。

**实测**（重建后六例）：

| 用例 | 结果 |
|---|---|
| 正常 curl（无 Origin） | 200 |
| Host: evil.example.com（rebinding） | **403** |
| POST + Origin: https://evil.example.com | **403** |
| POST + Origin: null（file:// 源） | **403** |
| Origin: http://127.0.0.1:8799（本机同源） | 200 |
| Host: localhost:8799 | 200 |

注意：桥只在 `--automation` 模式启动——普通使用无此面；本轮把"自动化模式的
localhost 信任"收紧为"本机源信任"。

### 2. 窗口标题进系统提示的结构逃逸（P1）

`<environment>` 段的多窗口清单直接拼 `windowTitle ?? displayLabel`——标题是
**页面可控的**（`<title>`），可带换行与 `</environment>` 伪边界，在系统提示
里伪造段/条目。围栏化的 page_context 不受影响；这是"页面文本混进结构段"的散点。

**修复**：`AgentTextSanitizer.pageText`（Foundation-only，进 harness）——
换行压平、尖括号换 ‹›、长度封顶 120；PromptBuilder 窗口清单接入。

### 3. 下载文件名路径穿越（P1）

`suggestedFilename` 来自远端（Content-Disposition / URL 末段）。`resolveDestination`
的 `.replace` 策略直接 `appendingPathComponent(filename)`——`../../.zshenv`
这类名字把文件写出 Downloads（写配置投毒/覆盖任意用户文件）。rename/ask
策略的 `uniqueURL` 同样不设防。

**修复**：`FilePathing.sanitizeFileName`（取 lastPathComponent 吃掉全部 `..`
段、`.`/`..`/空名兜底 `download`、隐敓名加前缀）——`resolveDestination` 与
`uniqueURL` 统一收口。**附带收获**：截图落盘共用此路径，顺带设防。

## 确认健康（勿过度修复）

- **page_context 围栏**（2026-09-23）：UNTRUSTED 声明 + BEGIN/END 标记；
  **DPP site context**（0.6.10）：UNTRUSTED 元数据框 + 600 字封顶——两条主
  注入面均有显式围栏。
- **ToolRisk 默认档**：未知工具（含 MCP）默认 `.sideEffect`（保守中间档，
  不会静默放行也不会拉黑新工具）。
- **高危下载类型确认**（0.2.15）：安装器/脚本/镜像扩展名 + MIME 双查，
  页面自动发起需用户确认。
- **桥基础面**：只绑 127.0.0.1、`--automation-token` 可选 Bearer、请求按
  Content-Length 攒齐（17a3089）。

## 挂起（下一轮 0.7.5+ 候选，按优先级）

1. **插件 RPC 的 ext 身份是声明式的**（`dict["ext"]` 取自消息体）——跨插件
   冒名理论可行，影响限于存储桶污染（用户主动安装的半信任面）。正修 =
   per-webview 世界→id 映射由宿主侧注入，不信消息体。
2. **DPP action/view 名进工具消息未消毒**——工具消息是结构性数据位，
   模型侧规则已声明页面文本是数据；低危，可与 1 同轮处理。
3. **桥 token 默认关**——可设计为 automation 模式默认生成一次性 token
   打印到 stdout（要动 CI 与全部 E2E 的启动协议，需单独立项）。
4. **MCP 工具定义注入面**——用户配置的服务器属半信任；工具描述会进系统
   提示的 `<tools>` 段。方向：`<tools>` 段声明"工具描述由第三方服务器提供"。

## 回归

- harness：428 项全绿（新增 8 项消毒单测：FilePathing ×5、AgentTextSanitizer ×3）。
- 桥六例实测上表。
- E2E 套件（agent-eval）未跑本轮（纯桥闸+消毒变更，CI 会全量跑）。
