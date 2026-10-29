# Desire as an MCP server — 让编程工具与浏览器 Agent 对话

Desire 内置一个 **Model Context Protocol 服务器**（Streamable HTTP），外部编程
工具（Claude Code / Cursor / Codex 等）可以把 Desire 当成一个 MCP server 挂上去：
既能**驱动浏览器**（导航、读页面、执行 JS、截图、看日志），也能**和浏览器
Agent 对话**（发任务、读回复、看轨迹），从而形成一个改进闭环。

> 服务器默认关闭。只有带 `--mcp-server` 启动时才监听，端口 **8798**，
> 只绑定 `127.0.0.1`。

## 启动

```bash
# 开发构建（DerivedData 路径按需替换）
open <Desire.app> --args --mcp-server

# 可选：要求 Bearer token（与 --automation-token 同款）
open <Desire.app> --args --mcp-server --mcp-token <token>
```

端点：`http://127.0.0.1:8798/mcp`（JSON-RPC 2.0，协议版本 `2025-06-18`）。
`GET /mcp` 是 SSE 事件流（把应用内 BridgeEventBus 事件按 JSON-RPC 推给客户端）。

## 接入客户端

**Claude Code（HTTP）**
```bash
claude mcp add --transport http desire http://127.0.0.1:8798/mcp
```

**Cursor / 其他支持 HTTP 的客户端**（`.cursor/mcp.json` 等）
```json
{ "mcpServers": { "desire": { "url": "http://127.0.0.1:8798/mcp" } } }
```

**只支持 stdio 的客户端**——用仓库里的垫片（转发到本机 MCP 端点）：
```json
{
  "mcpServers": {
    "desire": {
      "command": "python3",
      "args": ["/path/to/Desire/tools/desire-mcp-stdio.py"],
      "env": { "DESIRE_MCP_URL": "http://127.0.0.1:8798/mcp" }
    }
  }
}
```

## 工具面

**浏览器原语**：`navigate` `getPageText` `getPageInfo` `listTabs` `newTab`
`closeTab` `switchTab` `findInPage` `executeJs` `fullPageScreenshot`
`startDownload` `listDownloads` `pauseDownload` `resumeDownload`
`listHistory` `listBookmarks` `addBookmark` `watchPage` `listWatches`
`crewDispatch` `crewStatus` `crewCancel`、记忆/拦截/媒体下载等。

**Agent 对话与自省**（v0.8.22 新增）：

| 工具 | 作用 |
|------|------|
| `askAgent` | 给浏览器 Agent 发任务并等回合结束，返回 `{reply, busy, timedOut, newMessages}` |
| `getAgentMessages` | 读实时会话最近 12 条消息（role/content/toolCalls/model/tokens/busy） |
| `getAgentTrace` | 每回合派生的轨迹 JSONL（步骤/工具/耗时/失败原因/回答/自评/反馈） |
| `getAgentStats` | 历史用量统计（总量/峰值/按日/按模型） |
| `getAgentCost` | 当前会话成本拆解（只按用户填过的单价计） |
| `getAgentBudget` / `setAgentBudget` | 会话 token 预算的读/写 |
| `getAgentDoctor` | Agent 自检（端点可达性/Key/MCP/ffmpeg/hooks/技能/通知/心跳） |
| `addAgentNote` | 往会话追加系统备注（不进聊天，折叠进下一轮系统提示词） |
| `setAgentDirective` | 设置/清除会话级指令（如"用英文回答""更简短"） |
| `rateAgentMessage` | 给助手消息 👍/👎（落盘并驱动 eval 导出） |
| `searchConversations` | 搜历史会话（字面/语义两档） |
| `semanticSearch` | 端上语义检索历史正文/书签/摘录/高亮 |
| `exportEval` | 把 👍 回合导出成 eval JSONL |

## 改进闭环（推荐用法）

1. **跑任务**：`askAgent { text: "<用户会说的话>" }`
2. **看过程**：`getAgentTrace` —— 哪一步失败、哪个工具返回 `Error:`、耗时多少
3. **下诊断**：`getAgentDoctor`（端点/Key/MCP/hooks）、`getAgentMessages`（上下文）
4. **喂上下文**：`addAgentNote`（把外部观察交给 Agent）、`setAgentDirective`（改口径）
5. **打标**：`rateAgentMessage { vote: "down" }` 标记坏回合
6. **固化回归**：`exportEval` → `tests/agent-eval.py --fixtures <dir>`
7. 改代码/提示词/工具定义 → 重跑 1–6

> 轨迹里 `threwError` 只认应用自己写的两种失败（拒绝执行、JS 异常 `Error:` 前缀）；
> 普通工具失败没有统一约定，别用关键词猜（AGENTS.md「可观测性」条）。

## 安全边界

- 只监听回环地址；`Host`/`Origin` 非本机一律拒绝；可选 Bearer token。
- 服务器**默认关闭**，只有 `--mcp-server` 才开；开启后本机任何进程都能驱动
  浏览器（与自动化桥同一边界）。
- 没有 App Sandbox（Agent 需要执行系统命令）；不要把这个端点暴露到公网。

## 排错

- `initialize` 无响应：确认 Desire 是带 `--mcp-server` 启动的；`lsof -nP -iTCP:8798`.
- 客户端连上但工具报 `No live agent session`：先打开一个 Desire 窗口并展开 Agent 面板。
- `askAgent` 超时：任务仍在跑；用 `getAgentMessages` / `getAgentTrace` 继续看。
- 想同时用自动化桥：再加 `--automation`（8799，curl/CI 用）。
