# Desire Browser 发布文案（SEO / 外链用）

> 用途：Google 收录与排名里"外链 + 真实点击"权重最大；下面每段都可以直接
> 粘贴发布。**发布前先部署网站最新版**（线上至少要有 `/en/`），发布时链接
> 统一指向 `https://desire.mankong.icu/`（英文渠道用 `/en/`）。
>
> 纪律：不刷票、不求互赞；发布当天尽量守在评论里；每个渠道只发一次；
> 同一天别多平台齐发（间隔 ≥1 天，Google 更认"自然增长"的链接曲线）。

## 目标与预期（现实口径）

| 关键词 | 可达性 | 说明 |
|---|---|---|
| `Desire Browser` | 高（2–6 周） | 品牌词，无强势同名产品 |
| `Desire Agent Browser` | 高 | 同上，靠 GitHub + 本站 + 发帖 |
| `AI agent browser macOS` | 中（1–3 个月） | 类目词，竞品是云厂商与 Chromium 系 |
| `agentic browser` / `AI browser macOS` | 中低 | 大厂在打，靠长尾与内容页慢慢起 |
| `Desire` | 不现实 | 重名产品极多；只求"搜 Desire Browser 能到本站" |

英文一句话（所有英文渠道同源）：

> **Desire Browser** is a native macOS browser (SwiftUI + WebKit) with an AI
> agent built into the browser itself — 100+ real browser tools, approval
> policy, memory, MCP, offline toolbox, and end-to-end encrypted sync.
> Open source, free: https://desire.mankong.icu/en/

中文一句话：

> **Desire**（Desire Browser）是 macOS 原生 AI 智能体浏览器：内置 Agent 驱动
> 100+ 真实浏览器工具，带审批策略、记忆、MCP 与端到端加密同步；另有 81 个
> 离线小工具。开源免费：https://desire.mankong.icu/

## Show HN（英文，建议首发）

标题（择一，HN 喜欢朴素直给）：

- `Show HN: Desire – an AI agent browser for macOS (SwiftUI + WebKit, not Chromium)`
- `Show HN: A browser where the AI agent drives 100+ real browser tools`

正文模板：

```
Hi HN — I built Desire Browser, a macOS browser in which the AI agent is the
browser's execution environment rather than a chat sidebar.

What that means concretely: the agent reads the page the way a person does
(text, HTML, DOM tree, screenshots, network log), acts the way a person does
(click, type, scroll, fill, upload), and every side effect goes through an
approval policy you control (confirm each action / auto-edit page ops while
shell commands stay gated / full access).

Some things I'd highlight because they were the hard parts:
- 100+ browser tools, with a grouped index and a `listTools` meta-tool instead
  of dumping every schema into every request (the tool surface is the biggest
  part of the app).
- A full trace per turn: plan, tool steps, durations, token usage, cost — and
  a "verify after acting" step so the agent checks its own work.
- MCP both ways (client + server), plus a 60+ endpoint local automation bridge.
- Everything runs against Apple WebKit; it is not a Chromium shell.
- Sync is end-to-end encrypted (bookmarks, settings, memory… keys derived from
  your password; the server stores ciphertext).

It is free and open source. Happy to answer anything about the agent runtime,
WebKit automation, or the MCP/plugin layers.

https://desire.mankong.icu/en/
```

> 注意：HN 反营销，**不要**用形容词堆砌；自称不可验证的"最好"会被喷。
> 发布后 24h 内回复每一条评论。

## Product Hunt

- Name: `Desire Browser`
- Tagline（≤60 字符）：`The AI agent browser for macOS — not a chat sidebar`
- Topics: macOS, Developer Tools, Artificial Intelligence, Privacy, Open Source
- Description：

```
Desire Browser is a native macOS browser (SwiftUI + WebKit) where a built-in
AI agent drives 100+ real browser tools: it reads pages, clicks, types,
uploads, downloads, runs commands and verifies its work — under an approval
policy you control.

• Approvals: confirm each side effect, auto-edit page ops, or full access
• Plans, memory, skills, subagents, scheduled tasks, token/cost traces
• MCP client + server; 60+ endpoint automation bridge
• 81 offline toolbox utilities (JSON/CSV, regex, hashes, crypto, media)
• Reader mode, PDF annotation, ebook reader, video player & downloader
• Chrome MV3-style plugin loader, ad blocking, containers, DevTools
• End-to-end encrypted sync; bring your own model key (OpenAI-compatible,
  Anthropic, Ollama, or Apple on-device)

Free and open source. Apple Silicon & Intel, macOS 26.5+.
```

- First comment（发布者自评，放链接与背景）：

```
Maker here. I wanted a browser where the agent isn't a sidebar but the user:
same page channels (DOM, screenshots, network log) and same actions (click,
type, upload), with every side effect behind an approval policy. Everything
above is shipped — happy to answer questions about the agent runtime or the
WebKit automation stack. Source: https://github.com/browser-rs/Desire
```

## Reddit（r/macapps 或 r/MacOS，英文）

标题：`Desire Browser – a native macOS browser where the built-in AI agent actually drives the browser (open source)`

正文：

```
I've been building a macOS browser (SwiftUI + WebKit, not Chromium) where the
AI agent is the execution environment:

- It reads pages like a user (text/HTML/DOM/screenshots/network log) and acts
  like one (click, type, scroll, fill, upload).
- Every side effect passes an approval policy (confirm / auto-edit / full).
- 100+ browser tools, plus plans, memory, skills and a full trace with token
  usage and cost.
- Boring-but-useful extras: reader mode, PDF annotation, ebook reader, video
  player + HLS-to-MP4 batch download, 81 offline toolbox utilities.
- Sync is end-to-end encrypted; models are BYOK (OpenAI-compatible, Anthropic,
  Ollama, Apple on-device).

Free, open source, Apple Silicon & Intel. Screenshots in the link.
https://desire.mankong.icu/en/
```

## V2EX（分享创造）

标题：`[分享创造] Desire：把 AI 智能体装进 macOS 浏览器的内核（SwiftUI + WebKit，非 Chromium）`

正文要点（口语化，不贴超长功能表）：智能体不是侧栏聊天，而是"像人一样看页面、像人一样动手"，副作用逐次审批；100+ 真实浏览器工具 + 分组工具索引；全程轨迹与成本核算；端到端加密同步；81 个离线小工具。附仓库与产品页，欢迎拍砖。

## 少数派 / 掘金 / 即刻

- 角度一（效率）："用智能体把重复的网页操作跑通：从登录到导出，全程留痕可审计"。
- 角度二（技术）："把 100+ 浏览器工具塞进系统提示词：分组索引 + listTools 把每回合成本压到 6%"。
- 角度三（隐私）："端上加密同步怎么做的：密钥由密码派生，服务器只见密文"。
- 各写 1500–2500 字长文，配 3–5 张截图；文末自然带产品页与仓库链接。

## 收录目录（需要账号，一次性提交）

- AlternativeTo：`https://alternativeto.net/`（搜同类如 Arc/Brave，提交新条目）
- Slant / MacUpdate / Softpedia：同上，提交 SoftwareApplication 条目
- awesome-macos / awesome-browser：向仓库提 PR（README 一行链接 + 一句话）
- 开源中国 / Gitee 镜像：可选，提升中文搜索与国内曝光

## 截图清单（发帖前准备，建议 3 张）

1. 主窗口 + 智能体面板：计划清单 + 工具轨迹 + 审批条（体现"像人一样干活"）
2. 工具箱页（81 工具网格或批量工具页）
3. 隐私/同步页或白板（二选一，体现差异化）

> 需要的话可以从应用里直接抓真实截图（桥/离屏快照），比摆拍可信。

## 时间表（建议）

- D0：Show HN（美西上午）
- D1：Reddit r/macapps
- D2：Product Hunt（00:01 PT 上线，全天回评论）
- D3–D4：V2EX / 少数派 / 掘金
- D5+：目录提交与 awesome-list PR
- 每周：Search Console 看「已编入索引」数量与查询词；有查询词无点击就改标题/描述
