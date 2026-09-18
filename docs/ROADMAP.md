# Desire 路线图（0.1.x → 0.2）

> 基线：v0.1.0（2026-09-18）。
> 定位：**AI 原生浏览器**——浏览器本体是 Agent 的执行环境。项目重心由代码占比
> 可证：`Features/Agent/` 是最大模块（45 文件：多模型路由、20+ 工具面、MCP 客户端、
> 审批、记忆、技能、定时任务），加上 40+ 端点的自动化桥（AI 驱动的测试与操控入口）。
> 路线图凡与主线冲突的"通用浏览器功能"，一律让位或入 backlog。

## 现状基线（v0.1.0 已具备）

**Agent 执行面**（20+ 工具）：带 ref 的页面快照与元素操作、可信键入/按键、表单清单
与填充、blob→CDN 视频嗅探、Mermaid 画布、工作区文件 I/O、窗口录屏、审批制命令
执行、技能（渐进披露）、定时任务（调度器已落地）、任务中提问、剪贴板、上传武器化。

**模型接入**：Foundation Models / Ollama / OpenAI 兼容路由；MCP 客户端
（Streamable HTTP）可挂外部工具。

**浏览器本体**：多窗口（每窗独立会话+工具面）、会话恢复、标签
（分组/固定/休眠/中键）、beforeunload 保护、下载全链路（无痕隔离）、
内容/元素/视频广告三层拦截、容器隔离、按域设置、截图+标注、响应式模式、
DevTools、用户脚本。

**工程**：自动化桥 40+ 端点（本文件所有 QA 都靠它）、CI（Release 构建+产物）、
tag 发版。v0.1.0 QA 累计修复 9 个真 bug。

---

## 0.1.x 补丁线（每 1–2 周，小步快跑）

### 0.1.1 — Agent 可靠性

- **BUG-K 退出挂起**：SIGTERM 后偶发卡 exit（疑似未决 continuation/网络会话）。
  加关闭期诊断（枚举存活 URLSession 任务与未决 continuation），定位后修。
  Agent 常驻跑定时任务时这是可靠性硬伤。
- **审批/定时任务全链路桥测**：`/approvals` 已有查询与决策端点，补齐
  "定时任务触发 → 工具审批 → 桥代决策 → 任务完成"的端到端回归。
- **savePage 命令补齐**：映射已有、命令无——⌘S 保存页面；同时成为
  Agent 的存档原语。
- **密码提示条化**：`passwordSave` 已非阻塞（sheet），但 Agent 代登录时
  sheet 会抢焦点打断流程——改为地址栏下方轻提示条，且桥可代答
  （`/passwords/resolve` 已有）。
- **CI 冒烟**：产物上传前启动 app + `GET /state` 200，防止"能编译不能启动"。

### 0.1.2 — 分发质量

- Developer ID 签名 + 公证（配 secrets 则启用，否则回退 unsigned）。
- x86_64 构建检查一次（或宣布 arm64-only）。
- Release 说明模板（SHA256 校验、系统要求）。

### 0.1.3 — 桥事件流（外部驱动的基建）

- 桥目前是纯 HTTP 请求/响应，外部驱动只能轮询。加 **SSE 事件流**
  （`GET /events`）：页面就绪、下载完成、审批挂起、标签变化推送给驱动方——
  AI 驱动从"轮询"升级为"事件响应"。
- 桥自描述：`GET /` 返回端点清单（机器可读 JSON），任意 AI 无需文档即可
  学会驱动 Desire。
- 下载完成通知节流 + Dock 角标（Agent 批量下载时不再轰炸）。

---

## 0.2.0 — AI 原生深化（主题版本）

主题：**让任何 AI 都能把 Desire 当作"上网的手"**。

### 1. Desire 作为 MCP Server（反方向的补全）
现状：Desire 能**调用**外部 MCP 工具（MCPClient）；但外部 AI 客户端
（Claude Desktop、其他 Agent）无法**驱动** Desire。把桥的能力面
（导航/读取/快照/操作/下载/多标签）封装为 MCP Server（Streamable HTTP，
复用 BrowserToolProvider 的工具定义与桥的服务器骨架），外部 AI 直接连上即用。

### 2. 多窗口 Agent 联动
AGENTS.md 挂账项。`WindowToolSurface` 已按窗隔离——补上跨窗定位：
任务可指定目标窗口（"在窗口 2 执行"）、并行任务互不串台、
`/state` 与 Agent 面板按窗呈现。

### 3. 定时任务 → 无人值守作业
调度器已有。补：任务运行历史（起止/结果/失败原因持久化）、失败通知
（系统通知 + 桥事件）、"页面变化监控"预设（定时重读页面 + diff + 变更时
通知——价格/库存/公告监控是调度器的第一刚需场景）。

### 4. 页面结构化提取
在 `getPageSnapshot`/`writeFile` 之上加 `extractTable`/`extractList`：
把页面表格/列表抽成结构化 JSON/CSV 落工作区。配合定时任务 = 自动化数据
采集流水线；配 runCommand(ffmpeg/python3) 即完整的数据加工链。

### 5. 网络拦截层（Agent 测试台 + 响应式正名）
WebKit Network Interception：请求 mock/改写/真节流。首先服务 Agent
开发态（mock 第三方 API 做可复现测试），顺带完成响应式模式的真节流与
pixelRatio 模拟，拆掉假 UI（AGENTS.md 挂账）。

### 6. 媒体流水线技能化
媒体嗅探（已有）+ 下载（已有）+ runCommand(ffmpeg)（已有）串成内置
"media" 技能：'提取这个页面的视频并转 mp3' 一句话完成。技能系统就绪，
缺的是编排与内置技能包。

### 7. Passkey（服务 Agent 登录流）
Apple entitlement 流程走完（docs/ 已有申请记录）。WebAuthn 平台凭据
让 Agent 代登录免于密码短信验证码的脆弱环节。

**Backlog（浏览器本体，按需取用）**：书签栏、历史归并视图、密码中心、
per-domain JS 开关——仅当 Agent 场景需要时提前（例如书签作为 Agent 可用
的"地址簿"时再排期）。

---

## 明确不做（本阶段）

- 账号云同步、iOS 移植、多语言扩展、通用密码管理器对齐
  （CSV 导入仅作为密码中心的一部分顺带做）。

## 版本节奏与质量门

- 0.1.x：每 1–2 周一个 tag；修复 + 小 UX；CI（Release 编译 + 产物 + 冒烟）。
- 0.2.0：功能逐个落（独立 PR + 桥端点 + 桥回归），全量回归通过 → 冻结 → tag。
- 回归底座：自动化桥全链路（`/state`、`/command`、`/downloads/*`、
  `/beforeunload`、`/find`、`/shortcuts`、`/approvals`、`/passwords/*`、
  `/tabgroups` 等）。
