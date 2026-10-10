# Desire Page Protocol (DPP) v1 规范

> **定位**：**DPP for AI agents** —— 网页的能力声明协议。与 llms.txt 互补
> （llms.txt 向 LLM 声明内容，DPP 向 Agent 声明能力）。命名消歧：本规范的
> DPP 与欧盟 Digital Product Passport（数字产品护照）无关。
> **状态**：v1.1 规范——页面级/站点级/事件/审批全链实装（本版新增：§4.0 版本与
> 演进、§4.7 站点级完整行为、§5 Profile 契约运行时化、§11 自检工具）
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
| P7 | **容错演进** | 单字段失败只丢该字段、未知字段一律忽略、新能力按"存在即启用"——任何声明错误都不得让整份协议失效（§4.0） |
| P8 | **求值隔离** | Agent 的选择器求值运行在隔离世界，不依赖页面可变的全局——协议声明不能被页面在运行时篡改（§6.2） |

## 2. 协议分层

```
┌─────────────────────────────────────────────┐
│  站点级   /.well-known/desire.json   ✅     │  站点元信息/页面地图/登录/约束
├─────────────────────────────────────────────┤
│  页面级   <script type="application/       │  本页操作/视图/信号/事件/上下文
│           /x-desire+json">            ✅    │
├─────────────────────────────────────────────┤
│  运行时   Desire 解析 → 缓存 → 注入 Agent  │  工具 + page_context + 审批
└─────────────────────────────────────────────┘
```

> 站点级声明仅在**页面自己声明了协议**时拉取（渐进原则——不把每次导航
> 升级成站点指纹探针），页内同源 fetch，host 级缓存 10 分钟。合并语义：
> 页面级优先；views/signals/events/context 逐键共存，actions 按名去重。

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

**schema.org potentialAction 消费（✅ 实装）**：JSON-LD 里的 `potentialAction`
（SearchAction / ViewAction / OrderAction…）自动映射为 DPP 动作——`@type`
去 Action 后缀即动作名（可被 `name` 覆盖）、URL target（含 `{占位符}`）映射为
`navigate` 步骤 + params。与 llms.txt 互补：llms.txt 管**内容**发现，
DPP 管**能力**发现与执行。

*计划扩展*：Recipe, Event, LocalBusiness, JobPosting, FAQPage。

### 3.2 L1 — 属性微标注

在现有 HTML 元素上加协议属性，Desire 扫描编译：

| 属性 | 含义 | 示例 |
|---|---|---|
| `data-dpp-view="名称"` | 标记列表容器 | `<div data-dpp-view="products">` |
| `data-dpp-item` | 标记单条目元素 | `<div class="card" data-dpp-item>` |
| `data-dpp-field="字段名"` | 标记字段（textContent 为值） | `<h3 data-dpp-field="title">` |
| `data-dpp-field="名" data-dpp-field-attr="属性"` | 字段值取自属性 | `<span data-dpp-field="price" data-dpp-field-attr="data-price">` |
| `data-dpp-ignore` | 标记噪音（✅ pageExtract 跳过其子树内条目、快照不列其内交互元素；正文文本不扣减——正文噪音用 content.main） | `<nav data-dpp-ignore>` |
| `data-dpp-action="动作名"` | 标记动作触发器 | `<button data-dpp-action="search">` |

### 3.3 L2 — 声明块

> **CSP 兼容**：声明块是**数据块**（非可执行 script），不受 CSP `script-src`
> 限制——严格 CSP 的站点也可用 L2（L3 外链 SDK 则需要把本域加入白名单）。

```html
<script type="application/x-desire+json">
{ /* 完整协议 JSON，见 §4 */ }
</script>
```

### 3.4 L3 — 原生 SDK（✅ 已实装）

```html
<script src="https://desire.mankong.icu/desire-sdk.js"></script>
<script>
  desire.expose({ protocol: "desire/1", views: {...}, signals: {...}, ... });
  // SPA 路由变化时重新 expose（Desire 自动重新解析）
  desire.emit("new-message", { conversationId: "…" });   // 精确事件发射
</script>
```

> SDK 公开地址：`https://desire.mankong.icu/desire-sdk.js`（随产品页部署）。

## 4. 核心 Schema

### 4.0 版本与演进

| 规则 | 说明 |
|---|---|
| 版本标识 | 顶层 `protocol: "desire/1"`（major/minor 语义：**major 变更 = 破坏既有语义**；minor 变更 = 只增不改） |
| 消费者义务 | 未知 major → 降级到核心原语消费；未知字段 → **忽略**；未知枚举值 → 当作未声明 |
| 生产者义务 | 新能力**存在即启用**（Agent 用能力探测代替版本判断）；不假设消费者认识新字段 |
| 容错解码 | 单字段结构不符只丢该字段并记入 warnings（页面作者经 pageProtocol / `/protocol/inspect` 自查）；**绝不因一处错误失败整份协议** |
| 字段移除 | desire/1 内不移除已发布字段；废弃走"文档标注 deprecated"→ 下一个 major 才删 |
| 正式 Schema | `docs/dpp-schema.json`（JSON Schema 2020-12），自检见 §11 |

> 这条演进规则是 2026-10 审计的产物：此前 events 对象形态 / context 数组会让
> 整份协议静默丢弃——**健壮性必须内建于协议，而不是指望站点永远写对**。

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
  "context":    { "persona": "…", "domain": […], "rules": "…" },
  "pages":      { "/product/*": { "profile": "catalog" } }
}
```

> `pages` 仅站点级（well-known）使用——页面地图：路径模式（精确或 `前缀*`）→
> 页面提示（type/profile）。页面自身声明 `profile` 时优先。

**选择器穿透（shadow DOM）**：所有协议选择器（views/signals/actions/events）支持
**`>>>` 穿透语法**——`"app-grid >>> product-card >>> .price"` 按段下钻 `shadowRoot`
（WebKit 的 querySelector 不穿透 shadow boundary，Desire 在宿主侧逐段解析）。
字段相对 item 的 shadowRoot 用前导 `>>>`：`{ "price": ">>> .p" }`。

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `protocol` | string | ✅ | 版本标识，当前 `"desire/1"`（兼容读取 `protocolVersion`） |
| `profile` | string | ⬜ | 场景约定名（§5：chat/catalog/forms/checkout/monitor/workbench）——✅ 运行时解析并透传给 Agent；页面未声明时可由站点级页面地图（`pages`）按路径补全 |
| `page.type` | string | ⬜ | 页面类型标注（`chat`/`catalog`/`forms`/`workbench`/`monitor`），仅供参考 |
| `content.main` | selector | ⬜ | 正文选择器——文本抽取只取此处，排除噪音 |
| `content.ignore` | selector[] | ✅ | 噪音区域：抽取跳条目、快照不列元素、**正文文本扣减**（clone 剔除 + 块级换行） |
| `signals` | object | ⬜ | 生命周期信号（见 §4.2） |
| `views` | map | ⬜ | 命名数据视图（见 §4.3） |
| `actions` | array | ⬜ | 声明式动作（见 §4.4） |
| `events` | map | ⬜ | 事件订阅（见 §4.5） |
| `context` | map | ⬜ | 语义上下文（见 §4.6） |

### 4.2 signals — 生命周期信号

| 信号 | 说明 | Agent 行为 |
|---|---|---|
| `ready` | 页面就绪（Agent 可开始操作） | navigate 后自动等待此信号再返回结果 |
| `stable` | **数据完整**（懒加载/增量拉取结束）——与 ready 区分：ready 是首屏渲染，stable 是"再读不会变" | navigate 在 ready 之后继续等 stable（有声明时，6s 超时如实报告），避免读到骨架屏 |
| `busy` | 正在处理（Agent 暂停操作） | click/fill 后检查 busy，等到消失再返回 |
| `error` | 错误提示（action 执行后检测） | action 执行后检查 error 信号判断成败 |

> **实现状态（2026-10-02 晚，已接线；stable 2026-10-04）**：`navigate` 在页面声明
> `signals.ready` 时等就绪信号出现再返回（6s 超时如实报告）；声明 `signals.stable`
> 时 ready 后**继续等 stable**（结果注明是否观察到）；`pageAction` 完成步骤后等
> `signals.busy` 消失再判成败（持续 5s 会在结果里注明）。signals 同时在
> `pageProtocol` / `/protocol/inspect` 中展示。

### 4.3 views — 命名数据视图

```json
"视图名": {
  "item":       "selector",                  // 列表项选择器
  "fields": {
    "字段名":   "selector",                  // 子选择器 → textContent
    "字段名":   "@attr",                     // item 自身的属性
    "字段名":   "selector@attr",             // 子选择器的属性
    "字段名":   "@text",                     // item 自身的 textContent
    "字段名":   { "selector": ".price", "type": "price" }   // 对象形态（可带类型）
  },
  "pagination": { "type": "paged", "next": "selector" }
}
```

**类型化字段（✅ 实装）**——对象形态的字段可声明 `type`，抽取时强转，
Agent 直接拿到类型化数据（失败回退原始字符串，宁可不转不可丢数据）：

| type | 语义 |
|---|---|
| `string`（默认） | 文本（连续空白折叠） |
| `number` / `price` | 数值；`price` 额外剔除货币符号与千分位（`¥1,299` → 1299） |
| `url` | 相对地址按页面解析为绝对 URL |
| `date` | 解析为 ISO 8601 字符串 |
| `bool` | `"true"` / `"1"` → true |

```json
"fields": {
  "title": ".name",
  "price": { "selector": ".price", "type": "price" },
  "link":  { "attr": "href", "type": "url" }
}
```

`pagination.type`：
- `"paged"`：有下一页按钮 → `pageExtract(all=true)` 自动翻页收集 ✅
- `"infinite"`：无限滚动 → `pageExtract(all=true)` 滚动到底收集（序列化去重、连续两轮无新增即到底） ✅
- `"none"`：无分页

#### 4.3.1 content.sections — 命名分区读取（2026-10-04）

痛点：智能体读网页只能"整页文本"或"main 正文"——评论区、资费表、FAQ、
标签页面板等**语义区块**无法单独读，长文页面整页读浪费 token 且精度差。

```json
"content": {
  "main": "#doc",
  "sections": {
    "overview": "#g-overview",
    "pricing": "#g-pricing",
    "faq": "#g-faq",
    "changelog": "#g-changelog"
  }
}
```

- 智能体侧：`getPageText(section: "faq")` 只返回该分区文本；未知分区**明确失败**
  并列出可用分区名（引导模型改参，绝不静默猜）。
- 声明侧：名字用语义名（智能体可读），值为 CSS 选择器；站点级 well-known 可
  整表提供，页面级逐键覆盖。
- 实现状态：✅ 已实装（解码/合并/pageText/hints/inspect 全链）。

#### 4.3.2 表格数据声明约定

大表格（对账单/比价表/资费表）文本化后列对齐全丢——智能体读 HTML 表格是知名
痛点。DPP 不需要新机制：**用 views 把行声明成条目**，每列是一个字段：

```json
"views": {
  "plans": {
    "item": "#pricing tbody tr",
    "fields": {
      "plan": "td:nth-child(1)",
      "monthly": { "selector": "td:nth-child(2)", "type": "price" },
      "devices": { "selector": "td:nth-child(3)", "type": "number" }
    }
  }
}
```

约定：`item` 指向 `tbody tr`，字段用 `td:nth-child(n)` 按列取值并标注类型；
表头行用 `thead` 的字段名单独声明或省略。`pageExtract("plans")` 即得结构化
行数据，列对齐由选择器保证。

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

**步骤 DSL 原子操作**（✅ = 已实装；未列的写法会明确报错，不会静默假成功）：

| 操作 | 参数 | 说明 | 状态 |
|---|---|---|---|
| `fill` | `{ "selector": "值" }` | 填充输入框（补发 input+change 事件） | ✅ |
| `click` | `"selector"` | 点击元素 | ✅ |
| `select` | `{ "selector": "值" }` | 选择下拉选项 | ✅ |
| `waitForText` | `"文本"` | 等待文本出现（最长 5s，超时=步骤失败） | ✅ |
| `waitFor` | `"selector"` | 等待元素出现（最长 5s） | ✅ |
| `hover` | `"selector"` | 悬停（派发 mouseover/mouseenter/mousemove） | ✅ |
| `pressKey` | `"key"` | 向 activeElement 派发 keydown/keyup | ✅ |
| `upload` | `{ "selector": "filePath" }` | 文件上传（复用 UploadIntent：arm + 点击选择器自动提交） | ✅ |
| `navigate` | `"url"` | 跳转（支持 `{占位符}` 模板；等待主框架完成 ≤8s；potentialAction URL target 的映射形态） | ✅ |

**模板变量**：`{参数名}` → 由 Desire 用 `args` 填充（如 `{keyword}` → `"DPP"`；选择器与值都填充）。
**required 参数**缺失、**precondition** 选择器 3s 内未出现 → 工具失败（带 `Error:` 前缀；水合中的页面不会秒判失败）。
**任一步骤失败** → 动作中止并报告失败步骤与已完成步骤（绝不假报成功）。

**模板变量**：`{参数名}` → 由 Desire 用 `args` 填充（如 `{keyword}` → `"DPP"`）。

**effects 分级**：

| 级别 | 含义 | Agent 闸门 |
|---|---|---|
| `local` | 纯页面内操作，可逆 | 默认 sideEffect 档审批 |
| `persist` | 写入站点数据（站点内可撤销） | 默认 sideEffect 档审批 |
| `outbound` | 对外不可逆（发消息/下单/发邮件） | **强制审批**（升级 dangerous 档，白名单/自动编辑不放行） |

**`danger: true`**：无论 effects 级别，强制审批。
**闸门实现**（2026-10-02 审计修复）：`AgentSessionStore.effectiveRisk` 在审批闸门处读取
当前页协议中该动作的 `danger/effects` 声明并升级风险档——协议声明能力 ≠ 授权，
Desire 强制最终闸门；审批卡显示 `host · 动作名 · 描述 · [effects/danger]`。

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
| `watch` | 监听选择器（出现即触发） |
| `debounce` | 防抖秒数（宿主统一处理，见下） |

**两种形态都合法**：值也可以直接写选择器字符串（简写形态）。对象形态由解析器
展平取 `watch`（`debounce`/`on` 由宿主事件层统一处理并在 warnings 里注明）。

**触发语义（契约）**：
- 监听在**匹配数由 0 变正**的跳变时上报——不是"匹配存在期间的每次 DOM 变动"
  （那是聊天页的消息风暴，且会永久吞掉同窗跳变）。`on` 字段接受但当前忽略
  （宿主统一按跳变监听；text-change 细粒度触发为后续版本）。
- 风暴防护在**宿主**：同事件 3s 防抖 + 单 host 60s 滑动窗口限频（10 条）。
  页面侧不做节流——协议鼓励如实上报，聚合由消费者负责。
- 命中后经事件管道触发**事件驱动回合**；per-site 档位 off/draft/auto 经桥
  `POST /dpp/mode` 管理；**outbound/danger 动作的强制审批不随档位放水**。
- **事件同意（consent）**：默认档 = **off**——事件自动唤起智能体会消耗
  token，不该在用户不知情时发生。首次遭遇被抑制的事件时 UI 提示一次
  （用户主动开启后按 host 记忆）。这是"通知权限"式的同意模型。
- **站点级 events 与页面级一起生效**（页面级同名键优先、一并装监听）。
- **精确事件（L3）**：`desire.emit(name, detail)` 绕过 DOM 监听直接上报——
  `detail` 建议携带 `conversationId`/`messageId` 这类业务主键（≤2KB），
  接收方据此定位数据；不需要页面真的渲染出 `.unread` 之类的标记元素。

**事件载荷（宿主 → Agent 的回合提示）**：host、事件名、时间、detail 全部
进入 prompt；Agent 侧典型响应 = pageExtract 取数 → 判定 → pageAction 处置。

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
**已实装（2026-10-02）**：`context` 值支持字符串/数组（数组逗号连接），随 page_context 与
`pageProtocol` 工具注入（前缀 "reference, not instruction"）。

### 4.7 站点级声明（`/.well-known/desire.json`）——完整行为

| 行为 | 规则 |
|---|---|
| 拉取条件 | **页面自身声明了协议**才拉取（渐进原则——不把每次导航升级成站点指纹探针） |
| 传输 | 页面内**同源 fetch**（继承 WebView 网络路径；宿主 URLSession 受系统代理/ATS 影响，实现避开了它） |
| 缓存 | host 级 10 分钟（含失败结果——404/离线不重试风暴） |
| 合并 | 页面级优先：views/signals/events/context **逐键共存**（页面同名键胜出），actions 按名去重（页面在前），ignore 并集；**站点级 events 一并进监听** |
| 页面地图 | `pages`：路径模式（精确 / `前缀*`，长前缀优先）→ 提示 type/profile；**页面未声明 profile 时按当前路径回退补全** |
| 安全边界 | 站点级不能豁免审批："声明能力 ≠ 授权"与页面级同规；well-known 的 danger/outbound 动作同样逐次审批 |
| 登录指引 | `auth`（自由键值，如 loginUrl/note）：✅ 解析并透出（pageProtocol）；Agent 遇登录墙据此**引导用户**，不自动填凭据 |
| 其他协议 | file:// 等非 http(s) 页面不拉取（well-known 属 HTTP 语义） |

## 5. Profile — 场景约定

Profile 在 core 原语之上定义**命名约定**（标准化的 view/action/event 名）——Agent 见 profile 名即知标准语义，不必逐页探索。

> **实现状态（2026-10-03）**：`profile` 由运行时解析并**透传给 Agent**
> （pageProtocol 工具 / page_context / `/protocol/inspect` 均可见），
> 页面未声明时经站点级页面地图（`pages`）按路径回退补全。约定本身靠
> **必选原语表**约束——站点照表声明，Agent 照表消费。

**Profile 契约**（站点声明 profile = 承诺这些原语存在；Agent 可依赖它们）：

| Profile | 必选原语 | 说明 |
|---|---|---|
| `chat` | views.conversations（id/name/unread/lastMessage）、views.activeThread（from/text/time）、actions.send-message（**outbound**）、events.new-message | IM/客服/招聘沟通 |
| `catalog` | views.items（+ pagination）、actions.search | 商品/视频/文章列表 |
| `forms` | views.formFields、actions.submit（**outbound**） | 表单/申请/注册 |
| `checkout` | steps（cart→shipping→payment→confirm）、views.cart/orderSummary、actions.place-order（**danger**） | 多步结算 |
| `monitor` | events（变化监听为核心）、views.<指标> | 价格/库存/状态监控 |
| `workbench` | views.records/dashboard、actions.<管理操作>（按 danger 标注）、events.approval-arrived | 后台管理 |

> 校验：`desire.validate()`（SDK 内置轻量检查）+ `tools/dpp-validate.py`
> （完整校验，见 §11）都会提示 profile 缺失的原语。

### chat profile（✅ 运行时透传；按 §5 契约表消费）

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
      "run": [{ "click": ".conversation-item[data-conv-id='{id}']" },
              { "waitFor": ".thread-loaded" }] },
    { "name": "send-message", "effects": "outbound", "danger": true,
      "params": {"text": {"type":"string","required":true}},
      "run": [{ "fill": {"#input-box": "{text}" } }, { "click": "#btn-send" }] }
  ],
  "events": { "new-message": { "watch": ".msg.unread", "debounce": 2 } },
  "context": { "persona": "…招聘 HR…", "guardrails": "不谈薪资细节" }
}
```

### catalog profile（✅ 契约已定义；原语全链可用）

```json
{
  "profile": "catalog",
  "views": { "items": { "item": ".product-card", "fields": { … }, "pagination": { "type": "paged", "next": ".next" } } },
  "actions": [ { "name": "search", … }, { "name": "filter", … } ]
}
```

### forms profile（✅ 契约已定义；上传步骤已实装）

```json
{
  "profile": "forms",
  "views": { "formFields": { "item": "form", "fields": {
    "email": "input[type=email]", "phone": "input[type=tel]", … } } },
  "actions": [ { "name": "submit", "effects": "outbound", … } ]
}
```

### checkout profile（✅ 契约已定义；place-order 走 danger 强制审批）

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

### workbench profile（✅ 契约已定义）

```json
{
  "profile": "workbench",
  "views": { "records": { … }, "dashboard": { … } },
  "actions": [ … 多个管理操作，标注 danger/effects … ],
  "events": { "approval-arrived": { … } }
}
```

### 5.1 可视化到白板（宿主能力约定，2026-10-04）

页面**不需要**为可视化声明新原语：声明好 views 即可被智能体提取并渲染到
宿主白板（思维导图/流程图/数据图表，Mermaid + ECharts 本地引擎）。可选引导：

```json
"context": { "visualization": "metrics 视图适合柱状图；relations 适合思维导图" }
```

约束：白板是**用户的**画布——页面只能建议（context 提示），不能直接写入；
智能体是否采纳、用户是否放行（outbound 审批不适用——白板写入是本地纯 UI，
但仍是显式的用户可见动作）由宿主闸门决定。

## 6. 安全模型

### 6.1 三段信任

```
站点协议（声明能力） × 用户策略（per-site 放权范围） × Desire 闸门（outbound/danger 审批）
```

协议声明能力，**不等于授权**。用户策略控制每个站点允许什么，Desire 强制执行最终闸门。

### 6.2 求值隔离（2026-10-03 审计后确立）

**工具求值不得依赖页面可变的全局。** Agent 的全部页面 JS 求值（DPP 选择
器、`__desireSnapshot`/`__desireClick` 等 dom-tools 函数、`eval` 帮手）
运行在隔离 content world `desireAgentTools`——**dom-tools.js 只注入该世
界**（第三轮指导 4：页面世界不再注入，页面覆盖/猴补从根上不可达）。DOM
跨世界共享，click/fill/scroll 语义不变。
**留页面世界的例外**（各自有独立脚本/语义）：协议解析器（读页面的
`window.desire` / `__desireProtocolExposed`）、**executeJS**（语义就是
页面上下文执行）、**dpp-route-watch.js**（包装页面自己的
history.pushState/replaceState + popstate/hashchange → 触发重解析，
SPA 路由变化后 L1 锚点与声明缓存随之刷新）、**network-tools.js**
（`__desireWaitForNetworkIdle` 猴补页面 XHR/fetch——隔离世界的补丁
拦不到页面请求；getNetworkLog 已原生化改读 DevToolsStore）。
**配套约定**：`callAsync` 以**按键对象**传参（`fn({a: a, b: b})`），
dom-tools 宿主直调函数一律解构形参（键名守卫：非 JS 标识符直接报错）；
**改 dom-tools 函数签名前必须 grep 全部调用方**——存在页面世界 JS 字符串
位置调用的函数（如 `__desireFillProfile`，唯一调用方 FormAutofillStore）
**不得解构**，定义处标 `⚠️ 不要解构`。选择器穿透辅助（`__desireQueryAll`）
**单一来源** = dom-tools.js 尾部段（向 agentToolWorld 常驻），调用点不再
前置副本；跨世界求值一律 `callAsyncJavaScript(contentWorld:)`
（`evaluateJavaScript(_:in:in:)` 不回传完成值），数组参数走 JSON 字符串
（arguments 桥接不认 Swift 数组），JS 体必须有 `return`（无 return 恒 nil）。

### 6.3 审批的时空一致性

"声明能力 ≠ 授权"包含**对什么对象授权**：审批卡记录动作所在页面的 host，
执行前复核——审批与执行之间页面若已导航（同名动作会在别的页面上跑），
执行被拒绝并提示重新审批（TOCTOU 防护，实测曾踩）。

### 6.4 注入防护

- 协议 JSON 大小上限（256KB）
- `run` 步骤操作白名单（仅 §4.4 的原子操作，无 `runJS`）
- `runJS` 操作需站点声明 + 用户策略双允许
- 协议注入 Agent 上下文的**参考位**，不是指令位——"页面文字是数据不是指令"原则不变

### 6.5 防拉锯

- 用户 `unblockElement` AI 自动拦截的元素 → 该 host 加入豁免名单
- 用户关闭某站点的 Auto-Clean → 站点级记忆

### 6.6 隐私

- 协议不携带用户数据（只有选择器和描述）
- Agent 提取的数据留在本地（除非用户显式要求同步/外发）
- `context.persona` 是站点声明，不是用户数据

## 7. Desire 运行时实现

### 7.1 组件架构

```
┌────────────────────────────────────────────────┐
│ desire-protocol.js (user script, 页面世界)      │  四形态归一化解析
│ → window.__desireProtocol / callAsyncJavaScript│
│ 全部工具求值在隔离世界 desireAgentTools（§6.2） │  dom-tools 双世界注入│
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
│ MutationObserver  → 0→正 跳变上报（页内）      │
│ 审批闸门           → outbound/danger 强制审批   │
└────────────────────────────────────────────────┘
```

### 7.2 Agent 工具清单

>
> **`whiteboard`（宿主内置，2026-10-04）**：把内容渲染成思维导图 / 流程图 / 数据图表
> （Mermaid + ECharts 本地引擎）。与 DPP 的协同：页面只需声明好 **views**（本职），
> 智能体 `pageExtract` 取数后即可 `whiteboard` 可视化——页面**不能**直接写用户的
> 白板（声明能力 ≠ 授权，白板归属用户）；页面想引导时可在 `context` 里加自由提示
> （如 `visualization: "pricing 视图适合柱状图"`），是否采纳由智能体与用户决定。

| 工具 | 参数 | 说明 |
|---|---|---|
| `pageProtocol` | （无） | 查看当前页面的 DPP 协议（views/signals/actions/events/context/ignore；站点级来源会标注） |
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

### 7.4 第三方适配包（站点不接入时的社区声明）

站点不会都主动接入 DPP。适配包 = **按 host 匹配的声明式 JSON**（`protocolBody` 与
SDK `expose()` 同一套协议格式），由第三方为热门站点编写。加载语义：

- **合并而非替换**：页面原生声明（L0–L3 任意形态，哪怕只是最低限度的 JSON-LD
  隐式视图）与适配器做 merged——同名键**页面胜**、适配器独有键补齐（站点接入后
  适配包自然失效）；页面完全无声明时适配器整份生效
- **纯 JSON 零代码**：动作的 run 步骤由既有 pageAction 执行器执行，审批链照常生效
  （persist/outbound/danger 照旧强制审批）——适配包不引入任何新执行面
- 每包独立启停；来源标记进 `warnings`（`adapter: <name>`，inspect/面板可见）

**安装**：设置 › AI › DPP 协议 › 第三方适配（文件导入 / **URL 安装**），或目录直放
`~/Library/Application Support/Desire/DPPAdapters/<name>.json`，桥端点
`GET /dpp/adapters`、`POST /dpp/adapters/install {url}`（http(s) 直链即包源——本仓库
`docs/dpp-adapters/*.json` 的 GitHub raw 链接就是一个可用的社区源）。

**编写**：格式与守则见 [`docs/dpp-adapters/README.md`](dpp-adapters/README.md)
（selectors 保守多候选、只声明核对过的动作、`ignore` 排噪音、`auth` 给登录态指引）；
现成示例 `juejin.json`（文章页）与 `juejin-compose.json`（创作页），全部经真实页面核对。

## 8. E2E 验证结果

> 2026-10-02 审计修复后全量复验（离屏 WKWebView 探针 + 真实解析器/解码器/抽取器）。
> 修复前 L0/L1 两行是**假绿**：抽取返回了 JSON 但字段全空/条目是错元素。

| 场景 | 结果 |
|---|---|
| L2 声明块页 → pageProtocol 查看视图/信号/动作 | ✅ |
| L2 声明块页 → pageExtract 返回**正确字段值** JSON | ✅ |
| L2 声明块页 → pageAction fill+click 全链执行 | ✅ |
| L1 属性页 → data-dpp-* 扫描 → pageExtract（**全部条目**、字段值正确） | ✅ |
| L1 容器自身即条目（view+item 同元素）→ 单条目抽取 | ✅ |
| L0 JSON-LD 页 → Product 字段经逗号回退选择器抽取 | ✅ |
| 规范原文形态：events 对象 {watch,…} / context 数组 | ✅ 展平/连接 + warnings |
| ignore-only L1 页面 / 多 class ignore 选择器 | ✅ |
| Auto-Clean：fixed 浮层广告自动拦截 | ✅ |
| 内置规则已拦的元素不重复拦截 | ✅ |
| page_context [DPP] 摘要（含 context）注入 system 层 | ✅ 代码接线，真机回合待验 |
| 事件驱动：0→正 跳变 → PageEventHub → Agent 回合 | ⬜ 基建已通，待真机验证 |
| 审批闸门真机 E2E：danger 动作强制审批（挂起/未执行/deny/allow 全链 20 项） | ✅ |
| signals 接线：navigate 等 ready、pageAction 等 busy 消失 | ✅ 真机 E2E |
| shadow DOM 穿透：`>>>` item/字段选择器抽取 | ✅ 探针实证 |
| 事件驱动全链：跳变 → PageEventHub → auto 回合 → 模型收到 | ✅ 真机 E2E 8 项 |
| 站点级 well-known 合并 + upload 步骤交付 | ✅ 真机 E2E 7 项 |
| 线上 SDK（desire.mankong.icu）第三方站点全链 | ✅ 真机 E2E 5 项 |
| 审批时空一致性 + upload 摘 arm + signals.error | ✅ 第二轮审计后全量回归 |

## 9. 已知限制与边界

| 限制 | 原因 | 计划 |
|---|---|---|
| 跨源 iframe 不可穿透 | 同源已自动搜索；跨源需宿主 frame API | 后续：`frame:` 前缀 |
| infinite 分页只滚 window | 容器内滚动的站点无效（静默返回已收集部分） | 按需 |
| L1 属性扫描不进 shadow DOM/iframe | 解析器只扫 light DOM（L2/L3 声明可用 `>>>`，选择器自动搜同源 iframe） | 按需 |
| well-known 仅同源 http(s) 页面 | 经页面内 fetch；file:// 等协议跳过 | 设计内 |
| 审批白名单粒度 = 工具名 | outbound/danger 已强制逐次审批兜底 | 后续：per-(host, action) 放行 |
| SDK 部署依赖产品页 | website/desire-sdk.js 随站点发布 | 用户部署时带上 |

（listChanged / sampling / OAuth 属 MCP 客户端能力，不在 DPP 范围——见 MCP 章节。）

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
- ✅ signals 行为接线（navigate 等 ready / pageAction 等 busy）+ infinite 分页 + SPA 重解析
- ✅ 审批闸门真机 E2E（20 项全过；抓到并修掉 autoEdit 放行 danger 动作、callAsyncJavaScript 布尔检查缺 return、挂起页冻结 DOM 三个真缺陷）
- ⬜ chat profile 事件驱动回合 E2E 真机验证（基建已通，fixture 需带 IM 交互）
- ✅ **审计修复轮（2026-10-02）**：审批闸门接线（outbound/danger → dangerous 强制审批）、
  容错解码 + warnings、L1/L0 选择器修复（探针实证）、pageAction 失败可见 + required/precondition、
  事件滑窗限频 + 0→正 跳变、导航竞态清理、context 注入、contentMain 生效、模式持久化对齐
- ⬜ forms profile 字段语义标注（data-dpp-field 支持 type=email/tel/date 等类型提示）
- ⬜ monitor profile 变化阈值事件（价格 < X / 库存 = 0 时触发）

### 三期（剩余规划）
- well-known 登录态指引 + 测试账号声明（站点级 schema 扩展）
- MCP 联动（DPP 声明可引用 MCP 工具：`run: {"mcp": "server.tool"}`）
- 跨源 iframe 穿透（`frame:` 前缀，宿主经 frame API 跨源查询）
- L1 属性扫描进 shadow DOM / iframe
- 规范与 Schema 公开托管于产品页（文档/Schema/校验器已就绪，待部署）

### 已提前落地（原三期项）
- ✅ shadow DOM 穿透（`>>>` 语法，全链：views/字段/actions/信号/事件命中）
- ✅ SDK 公开分发（`website/desire-sdk.js` → https://desire.mankong.icu/desire-sdk.js）
- ✅ well-known 站点级声明（页面声明才拉取 + 页内同源 fetch + host 缓存 + 合并进单测）
- ✅ `upload` 步骤（UploadIntent 原语）+ 同源 iframe 穿透（自动搜索 + `>>>` 中段）
- ✅ SPA 路由变化全级重解析（dpp-route-watch 包装 history + popstate/hashchange）
- ✅ precondition 轮询等待（3s）；`ignore` 正文文本扣减；`pageProtocol` 列出事件；
  `getNetworkLog` 原生化（读 DevToolsStore，页面世界网络依赖只剩 WaitForNetworkIdle）
- ✅ **协议设计层升级（v1.1）**：§4.0 版本与演进规则、§4.7 站点级完整行为、
  §5 Profile 契约运行时化（含站点级页面地图 pages 回退）、§11 自检工具
  （JSON Schema + 零依赖校验器）

## 11. 自检工具（站点作者闭环）

| 工具 | 用法 | 覆盖 |
|---|---|---|
| 正式 Schema | `docs/dpp-schema.json`（JSON Schema 2020-12） | 一切声明形态（页面块 / well-known / SDK）共用一份 schema |
| 命令行校验 | `python3 tools/dpp-validate.py [文件\|URL]`（默认校验产品页自己） | schema 规则 + **运行时陷阱提前预警**（未知 run 操作会当场失败、空选择器、outbound 未标 danger、events `on` 被忽略等）；零依赖 |
| SDK 内校验 | `desire.validate()`（L3） | 开发期 console 提示（缺 signals.ready、缺 views、action 缺 run） |
| 运行时自查 | `pageProtocol` 工具 / `GET /protocol/inspect` | warnings 数组（被降级/丢弃的字段逐条可见） |

> 推荐流程：写完声明 → `dpp-validate.py`（或 SDK validate）→ 浏览器里
> `pageProtocol` 看运行时解析结果 → `pageExtract` 抽查数据 → `pageAction` 走一遍动作。
> **产品页自身即按此流程接入**（L2 声明块，校验零警告）。
