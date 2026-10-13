# DPP 实现状态与演进（维护者文档）

> 从 DPP-PROTOCOL.md 拆出（2026-10-12 设计评审 #9）：规范文档保持 normative
> （协议语义/安全模型/schema），实现进度与 E2E 结果在此跟踪。
> 规范：DPP-PROTOCOL.md · 自检工具见规范 §11。

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

