# DPP 运营适配包（ops/1）

运营工作台（日历、Runbook、回复台、指标采集、竞品监测、账号健康）优先读 **DPP 运营契约**：
站点或适配包用一组稳定的 `ops*` 名字声明能力，工作台据此确定性读取/执行；没有声明就明确
降级，不猜、不伪造。

这是 **profile 约定**，不是 `desire/1` 的新 major——格式仍是普通的 `desire/adapter-1`
JSON，纯声明、零代码，动作照常走 `pageAction` 审批链。

## 契约（ops/1）

| 类型 | 名字 | 说明 |
|---|---|---|
| views | `opsAccount` | 账号/粉丝/认证 |
| | `opsPosts` | 内容列表（id/title/url/publishedAt/views/likes/comments） |
| | `opsMetrics` | 指标（日期区间 + views/likes/comments） |
| | `opsComments` / `opsMentions` | 评论 / 外部提及（author/text/url/createdAt） |
| | `opsSearch` | 搜索结果列表 |
| | `opsComposer` | 发布器（标题/正文/提交按钮/登录提示） |
| | `opsAnalytics` | 平台侧点击/转化（可选） |
| | `opsCompetitor` | 竞品价格/功能/changelog 条目 |
| actions | `opsCompose` | **只填表**：`effects=local`，不得 `danger` |
| | `opsPublish` | 提交发布：`effects=persist/outbound` 或 `danger=true`，必须人工批准 |
| | `opsReply` | 回复：`effects=outbound` 或 `danger=true`，必须人工批准；可以只填不提交 |
| | `opsSearch` / `opsRefresh` | 站内搜索 / 刷新数据（local） |
| signals | `opsReady` / `opsLoginRequired` / `opsBusy` / `opsPosted` / `opsError` | 生命周期与登录态 |
| context | `channelSlug` / 标题正文上限 / 语气 / 建议节奏 / 数据日期口径 | 渠道元信息 |

**硬规则**

1. 填表与提交必须是两个动作；`opsCompose` 只填，`opsPublish` 才提交。
2. `opsPublish` / `opsReply` 永远人工批准；不提供"总是自动发布"。
3. 适配包是纯 JSON、零代码；导入默认禁用，启用是用户的显式动作。
4. 只声明核对过的视图/动作；站点改版时宁可失败并报出选择器，不假装成功。

## 包清单（按真实公开页面核对）

| 包 | 站点 | 覆盖 | 状态 |
|---|---|---|---|
| `v2ex-ops.json` | v2ex.com 主题页 | `opsComments` / `opsMentions`（回复读取） | 2026-10-23 公开 DOM 核对 |
| `hackernews-ops.json` | news.ycombinator.com 条目/用户页 | `opsComments` / `opsMentions`（只读） | 2026-10-23 公开 DOM 核对 |
| `juejin-ops.json` | juejin.cn 文章页 | `opsComments` / `opsMentions` + `opsReply`（只填） | 复用 2026-10-11 核对选择器 |
| `juejin-compose-ops.json` | juejin.cn 创作页 | `opsComposer` + `opsCompose`（只填） + `opsPublish`（批准） | 复用 2026-10-11 核对选择器 |

**未包含的渠道**：X / 小红书 / 微博 / 公众号等需要登录的创作后台——公开页面看不到真实的
指标/评论结构，按"只声明核对过的"原则不预置。用 **DPP Studio**（设置 › AI › DPP 协议 ›
第三方适配 › Author…）在你已登录的页面上现场生成：Studio 会做只读抽取测试，保存为禁用
草稿，你过目后再启用。

## 安装

- **设置** › AI › DPP 协议 › 第三方适配 › URL：粘本目录包的 GitHub raw 链接，例如
  `https://raw.githubusercontent.com/browser-rs/Desire/main/docs/dpp-adapters/ops/v2ex-ops.json`
- 或文件导入 / 直接放 `~/Library/Application Support/Desire/DPPAdapters/<name>.json`
- 安装后在列表里**手动启用**（默认禁用）。

## 验证（不发布任何内容）

1. 打开目标页面（如 V2EX 主题页），等页面加载完。
2. 对智能体说「pageProtocol，然后 pageExtract opsComments」。应当返回评论作者/正文。
3. 有 `opsCompose` 的渠道：`pageAction opsCompose` 只填表；检查后由用户自己点发布。
4. 运营页的 **DPP Ops** 段会显示该渠道的 `ops/1` 能力与健康度；连续失败会标 suspect/autoDisabled。

## 新增渠道

1. 在 **DPP Studio** 里载入模板，替换 `REPLACE_ME_*` 选择器；
2. 用「Test extraction」只读验证字段；
3. 保存为禁用草稿 → 设置页启用；
4. 真实页面跑一轮 `pageExtract`/`pageAction`，把 `notes` 写成"YYYY-MM-DD 真实 DOM 核对"。
