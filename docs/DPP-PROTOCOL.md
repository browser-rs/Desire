# Desire Page Protocol (DPP) v1 规范

> **状态**：草案（一期已实装，二期设计中）
> **版本**：desire/1
> **动机**：解决 AI Agent 与网页交互的核心痛点——**内容 → Agent 的低效通道**（文本墙/结构未知/噪音/拿不全/时机不确定）以及**操作不可靠**（selector 猜测/元素变化/假点击）。

---

## 1. 设计原则

| # | 原则 | 说明 |
|---|------|------|
| P1 | **内容 → Agent 优先** | 协议的第一性目标是把页面内容**准确、省 token、全量**地送进 Agent 上下文；操作声明是延伸 |
| P2 | **声明式** | 页面声明"我能做什么/我有什么/我何时就绪"，Agent 不靠启发式猜测 |
| P3 | **能力声明 ≠ 授权** | 协议声明能力，授权始终在用户（三段信任模型，见 §7） |
| P4 | **渐进增强** | 无协议页面 Agent 照常工作；有协议页面精度和效率跃升；声明多少用多少 |
| P5 | **开放规范** | 不限 Desire——任何 Agent 可消费，任何站点可实现 |
| P6 | **安全默认** | outbound/danger 动作强制审批；`runJS` 默认禁用；协议是参考不是指令 |

## 2. 协议分层

```
┌─────────────────────────────────────────────┐
│  站点级   /.well-known/desire.json          │  站点元信息/页面地图/登录/约束
├─────────────────────────────────────────────┤
│  页面级   <script type="application/       │  本页操作/视图/信号/事件/上下文
│           /x-desire+json">                  │
├─────────────────────────────────────────────┤
│  运行时   Desire 解析 → 缓存 → 注入 Agent  │  工具 + page_context + 审批
└─────────────────────────────────────────────┘
```

## 3. 接入形态（梯度采用）

| 层级 | 改造成本 | 形态 | 适用 |
|------|----------|------|------|
| **L0** | 零 | 既有 JSON-LD/microdata 自动消费 | 已有 schema.org 的站点 |
| **L1** | ≈5 min | 现有 HTML 加 `data-dpp-*` 属性 | 结构已好，缺语义 |
| **L2** | ≈30 min | `<script>` 块贴 JSON | SSR/可改模板站点 |
| **L3** | 开发时 | SDK `desire.expose({...})` | 新开发的站点 |

优先级：**L3 > L2 > L1 > L0**（高形态覆盖低形态的同名字段）。

### 3.1 L0 — 零改造

解析页面已有的 `<script type="application/ld+json">`，自动生成隐式 views：

| schema.org @type | 生成的 view | 字段 |
|---|---|---|
| `Product` | `product` | name, price, currency, description |
| `Article` / `NewsArticle` / `BlogPosting` | `article` | headline, articleBody, author, datePublished |

*计划扩展*：Recipe, Event, LocalBusiness, JobPosting, FAQPage。

### 3.2 L1 — 属性微标注

在现有 HTML 元素上加协议属性，Desire 扫描编译：

| 属性 | 含义 | 示例 |
|---|---|---|
| `data-dpp-view="名称"` | 标记列表容器 | `<div data-dpp-view="products">` |
| `data-dpp-item` | 标记单条目元素 | `<div class="card" data-dpp-item>` |
| `data-dpp-field="字段名"` | 标记字段（textContent 为值） | `<h3 data-dpp-field="title">` |
| `data-dpp-field="名" data-dpp-field-attr="属性"` | 字段值取自属性 | `<span data-dpp-field="price" data-dpp-field-attr="data-price">` |
| `data-dpp-ignore` | 标记噪音（Agent 忽略） | `<nav data-dpp-ignore>` |
| `data-dpp-action="动作名"` | 标记动作触发器 | `<button data-dpp-action="search">` |

### 3.3 L2 — 声明块

```html
<script type="application/x-desire+json">
{ /* 完整协议 JSON，见 §4 */ }
</script>
```

### 3.4 L3 — 原生 SDK（二期）

```js
desire.expose({ protocol: "desire/1", views: {...}, signals: {...}, ... });
// SPA 路由变化时重新 expose
desire.emit("new-message", { conversationId: "…" });   // 精确事件发射
```

## 4. 核心 Schema

### 4.1 顶层结构

```json
{
  "protocol":   "desire/1",
  "page":       { "type": "catalog" },
  "content":    { "main": "selector", "ignore": ["selector", …] },
  "signals":    { "ready": "selector", "busy": "selector", "error": "selector" },
  "views":      { "名称": { ProtocolView } },
  "actions":    [ { ProtocolAction } ],
  "events":     { "事件名": "watch-selector" },
  "context":    { "persona": "…", "domain": […], "rules": "…" }
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `protocol` | string | ✅ | 版本标识，当前 `"desire/1"` |
| `page.type` | string | ⬜ | 页面类型标注（`chat`/`catalog`/`forms`/`workbench`/`monitor`），仅供参考 |
| `content.main` | selector | ⬜ | 正文选择器——文本抽取只取此处，排除噪音 |
| `content.ignore` | selector[] | ⬜ | 明确排除的噪音区域 |
| `signals` | object | ⬜ | 生命周期信号（见 §4.2） |
| `views` | map | ⬜ | 命名数据视图（见 §4.3） |
| `actions` | array | ⬜ | 声明式动作（见 §4.4） |
| `events` | map | ⬜ | 事件订阅（见 §4.5） |
| `context` | map | ⬜ | 语义上下文（见 §4.6） |

### 4.2 signals — 生命周期信号

| 信号 | 说明 | Agent 行为 |
|---|---|---|
| `ready` | 页面就绪（Agent 可开始操作） | navigate 后自动等待此信号再返回结果 |
| `busy` | 正在处理（Agent 暂停操作） | click/fill 后检查 busy，等到消失再返回 |
| `error` | 错误提示（action 执行后检测） | action 执行后检查 error 信号判断成败 |

### 4.3 views — 命名数据视图

```json
"视图名": {
  "item":       "selector",                  // 列表项选择器
  "fields": {
    "字段名":   "selector",                  // 子选择器 → textContent
    "字段名":   "@attr",                     // item 自身的属性
    "字段名":   "selector@attr",             // 子选择器的属性
    "字段名":   "@text"                      // item 自身的 textContent
  },
  "pagination": { "type": "paged", "next": "selector" }
}
```

`pagination.type`：
- `"paged"`：有下一页按钮 → `pageExtract(all=true)` 自动翻页收集
- `"infinite"`：无限滚动 → `pageExtract(all=true)` 滚动到底收集
- `"none"`：无分页

### 4.4 actions — 声明式动作

```json
{
  "name":        "search-videos",
  "description": "按关键词搜索视频列表",
  "params": {
    "keyword": { "type": "string", "required": true, "description": "搜索关键词" },
    "page":    { "type": "number", "required": false }
  },
  "precondition": ".list-loaded",             // 前置条件选择器
  "run": [                                      // 步骤 DSL（见下方）
    { "fill":  { "#search-input": "{keyword}" } },
    { "click": "#search-btn" },
    { "waitForText": "搜索结果" }
  ],
  "effects":     "persist",                    // local | persist | outbound
  "danger":      false,
  "success":     "搜索完成"                     // 成功信号文本
}
```

**步骤 DSL 原子操作**：

| 操作 | 参数 | 说明 |
|---|---|---|
| `fill` | `{ "selector": "值" }` | 填充输入框 |
| `click` | `"selector"` | 点击元素 |
| `select` | `{ "selector": "值" }` | 选择下拉选项 |
| `waitForText` | `"文本"` | 等待文本出现（最长 5s） |
| `waitFor` | `"selector"` | 等待元素出现 |
| `hover` | `"selector"` | 悬停 |
| `pressKey` | `"key"` | 按键（Enter/Escape…） |
| `upload` | `{ "selector": "filePath" }` | 文件上传 |

**模板变量**：`{参数名}` → 由 Desire 用 `args` 填充（如 `{keyword}` → `"DPP"`）。

**effects 分级**：

| 级别 | 含义 | Agent 闸门 |
|---|---|---|
| `local` | 纯页面内操作，可逆 | 无需审批 |
| `persist` | 写入站点数据（站点内可撤销） | 默认无需审批 |
| `outbound` | 对外不可逆（发消息/下单/发邮件） | **强制走审批**（草稿模式默认拦截） |

**`danger: true`**：无论 effects 级别，强制审批。

### 4.5 events — 声明式事件

```json
"events": {
  "new-message":      { "watch": ".msg.unread", "debounce": 2 },
  "approval-arrived": { "watch": ".pending-approval", "debounce": 5 },
  "price-change":     { "watch": "#price", "on": "text-change" }
}
```

| 字段 | 说明 |
|---|---|
| `watch` | 监听选择器（出现/变化即触发） |
| `debounce` | 防抖秒数（同类事件 N 秒内合并） |

→ Desire 用 MutationObserver 监听 → 推给 AgentScheduler 触发**事件驱动回合**。事件风暴防护：同类事件 debounce 聚合、单会话频率上限。

### 4.6 context — 语义上下文

```json
"context": {
  "persona": "我们是 XX 科技招聘 HR，正在与候选人初次沟通",
  "tone":    "热情专业，简洁，不超过三句话",
  "domain":  ["SKU", "GMV", "履约"],
  "rules":   "不谈薪资细节，引导对方发简历"
}
```

→ 注入 Agent 上下文的**参考位**（永远低于用户指令）。这是页面作者告诉 AI"这个页面/业务是什么意思"的通道——AI 不再从页面文字里瞎猜。

## 5. Profile — 场景约定

Profile 在 core 原语之上定义**命名约定**（标准化的 view/action/event 名），Agent 见 profile 名即知标准语义：

### chat profile（✅ 已实装）

```json
{
  "profile": "chat",
  "views": {
    "conversations": { "item": ".conversation-item", "fields": {
      "id": "@data-conv-id", "name": ".who", "unread": "@data-unread",
      "lastMessage": ".preview", "context": "@data-ai-context" } },
    "activeThread": { "item": ".bubble", "fields": {
      "from": "@data-from", "text": ".msg-text", "time": "@data-time" } }
  },
  "actions": [
    { "name": "open-conversation", "params": {"id": {"type":"string","required":true}},
      "run": [{ "click": ".conversation-item[data-conv-id='{id}']" }],
      "waits": ".thread-loaded" },
    { "name": "send-message", "effects": "outbound", "danger": true,
      "params": {"text": {"type":"string","required":true}},
      "run": [{ "fill": {"#input-box": "{text}" } }, { "click": "#btn-send" }] }
  ],
  "events": { "new-message": { "watch": ".msg.unread", "debounce": 2 } },
  "context": { "persona": "…招聘 HR…", "guardrails": "不谈薪资细节" }
}
```

### catalog profile（schema 已定义，待站点实现）

```json
{
  "profile": "catalog",
  "views": { "items": { "item": ".product-card", "fields": { … }, "pagination": { "type": "paged", "next": ".next" } } },
  "actions": [ { "name": "search", … }, { "name": "filter", … } ]
}
```

### forms profile（schema 已定义，待站点实现）

```json
{
  "profile": "forms",
  "views": { "formFields": { "item": "form", "fields": {
    "email": "input[type=email]", "phone": "input[type=tel]", … } } },
  "actions": [ { "name": "submit", "effects": "outbound", … } ]
}
```

### checkout profile（schema 已定义，待站点实现）

```json
{
  "profile": "checkout",
  "views": { "cart": { … }, "orderSummary": { … } },
  "actions": [
    { "name": "place-order", "effects": "outbound", "danger": true, … },
    { "name": "apply-coupon", … }
  ],
  "steps": ["cart", "shipping", "payment", "confirm"]
}
```

### monitor profile（✅ 事件基建已实装）

```json
{
  "profile": "monitor",
  "views": { "metrics": { … } },
  "events": { "price-change": { "watch": "#price", "on": "text-change" },
               "stock-low": { "watch": ".stock[data-low]", "debounce": 10 } }
}
```

### workbench profile（schema 已定义，待站点实现）

```json
{
  "profile": "workbench",
  "views": { "records": { … }, "dashboard": { … } },
  "actions": [ … 多个管理操作，标注 danger/effects … ],
  "events": { "approval-arrived": { … } }
}
```

## 6. 安全模型

### 6.1 三段信任

```
站点协议（声明能力） × 用户策略（per-site 放权范围） × Desire 闸门（outbound/danger 审批）
```

协议声明能力，**不等于授权**。用户策略控制每个站点允许什么，Desire 强制执行最终闸门。

### 6.2 注入防护

- 协议 JSON 大小上限（256KB）
- `run` 步骤操作白名单（仅 §4.4 的原子操作，无 `runJS`）
- `runJS` 操作需站点声明 + 用户策略双允许
- 协议注入 Agent 上下文的**参考位**，不是指令位——"页面文字是数据不是指令"原则不变

### 6.3 防拉锯

- 用户 `unblockElement` AI 自动拦截的元素 → 该 host 加入豁免名单
- 用户关闭某站点的 Auto-Clean → 站点级记忆

### 6.4 隐私

- 协议不携带用户数据（只有选择器和描述）
- Agent 提取的数据留在本地（除非用户显式要求同步/外发）
- `context.persona` 是站点声明，不是用户数据

## 7. Desire 运行时实现

### 7.1 组件架构

```
┌────────────────────────────────────────────────┐
│ desire-protocol.js (user script)               │  四形态归一化解析
│ → window.__desireProtocol / callAsyncJavaScript│
├────────────────────────────────────────────────┤
│ Coordinator.didFinish → parsePageProtocol()    │  解析 + 缓存
│ → BrowserState.pageProtocol: DesireProtocol?   │
├────────────────────────────────────────────────┤
│ pageProtocol 工具  → 查看协议                  │
│ pageExtract 工具   → 按视图抽取结构化数据      │
│ pageAction 工具    → 执行声明式动作            │
├────────────────────────────────────────────────┤
│ page_context 增强  → DPP 摘要注入 system 层   │
│ PageEventHub      → 事件 → AgentScheduler     │
│ 事件 Timer 轮询    → 定期检查事件选择器命中   │
│ 审批闸门           → outbound/danger 拦截      │
└────────────────────────────────────────────────┘
```

### 7.2 Agent 工具清单

| 工具 | 参数 | 说明 |
|---|---|---|
| `pageProtocol` | （无） | 查看当前页面的 DPP 协议（views/signals/actions/ignore） |
| `pageExtract` | `view: string, all?: bool` | 按视图抽取结构化数据；`all=true` 跟随分页 |
| `pageAction` | `name: string, args?: object` | 执行声明的动作（模板变量填充 + 步骤 DSL 执行） |

### 7.3 page_context 增强

当页面有 DPP 协议时，Agent 的 system 层自动附加：

```
[DPP] This page declares a Desire Page Protocol:
Views (pageExtract): articles(fields: summary, title, url, views)
Main content selector: .article-body
Actions (pageAction): search
```

模型无需调工具就知道页面能提供什么结构化数据、有什么可执行操作。

## 8. E2E 验证结果

| 场景 | 结果 |
|---|---|
| L2 声明块页 → pageProtocol 查看视图/信号/动作 | ✅ |
| L2 声明块页 → pageExtract("articles") 返回结构化 JSON | ✅ |
| L2 声明块页 → pageAction("search") fill+click 全链执行 | ✅ |
| L1 属性页 → data-dpp-* 扫描 → pageExtract | ✅ |
| L0 JSON-LD 页 → Product/Article 隐式抽取 | ✅ |
| Auto-Clean：fixed 浮层广告自动拦截 | ✅ |
| 内置规则已拦的元素不重复拦截 | ✅ |
| 事件驱动：DPP events 选择器命中 → Agent 回合触发 | ⬜ 基建已通，待真机验证 |
| page_context [DPP] 摘要注入 system 层 | ⬜ 基建已通，待真机验证 |

## 9. 已知限制与边界

| 限制 | 原因 | 计划 |
|---|---|---|
| 不支持 shadow DOM 选择器 | CSS querySelector 不穿透 shadow boundary | 二期：`>>>` 穿透语法 |
| 不支持 iframe 内元素 | 跨 frame 无 selector 语义 | 二期：`frame:` 前缀 |
| listChanged 通知未实现 | 需要 SSE 长连接监听 | 三期 |
| sampling 未实现 | 需要 Desire 反向调用 LLM | 三期 |
| OAuth 未实现 | 复杂度高，当前 Bearer token 够用 | 按需 |
| 事件驱动回合未实现 | PageEventHub 设计已完成，工程量独立 | 二期 |

## 10. 实现状态与演进路线

### 一期（已实装 ✅）
- ✅ 协议 schema + 四形态归一化解析器（desire-protocol.js）
- ✅ `pageProtocol` 工具——查看页面协议（views/signals/actions/ignore）
- ✅ `pageExtract(view)` 工具——按声明视图抽取结构化数据（支持分页 all=true）
- ✅ `pageAction(name, args)` 工具——执行声明式动作（fill/click/waitForText/select 步骤 DSL + 模板变量 + success 信号检测）
- ✅ page_context DPP 摘要自动注入（视图清单 + 动作 + 正文选择器）
- ✅ navigate 返回值增强（页面标题 + 首段文本 + DPP 视图提示）
- ✅ fixture E2E（三形态解析 + pageProtocol + pageExtract + pageAction 全链）

### 二期（已实装 ✅，事件驱动 E2E 待真机验证）
- ✅ 事件驱动基建（Timer 轮询 + PageEventHub + per-site off/draft/auto 三档模式）
- ✅ 事件风暴防护（debounce + 频率上限 + 去重）
- ✅ unblockElement 豁免语义收窄（仅 ai-auto 来源规则触发 host 豁免）
- ✅ ad-candidates.js 选择器 id/class 优先修复（nth-child 死选择器）
- ✅ AI Auto-Clean toast 反馈（NotificationCenter → ContentView 橙色胶囊）
- ✅ 默认提示词 DPP 协议页意识（pageProtocol/pageExtract/pageAction 优先于 getPageText/click）
- ⬜ chat profile 事件驱动回合 E2E 真机验证（基建已通，fixture 需带 IM 交互）
- ⬜ forms profile 字段语义标注（data-dpp-field 支持 type=email/tel/date 等类型提示）
- ⬜ monitor profile 变化阈值事件（价格 < X / 库存 = 0 时触发）

### 三期（规划）
- well-known 站点级声明 + 登录态感知 + 测试账号指引
- checkout profile（多步向导 steps + 支付强制 danger 审批）
- workbench profile（后台管理 + 权限角色声明）
- 协议规范文档发布（面向站点作者和 Agent 开发者的开放规范）
- MCP 联动（DPP 声明可引用 MCP 工具：`run: {"mcp": "server.tool"}`）
- shadow DOM / iframe 穿透选择器
