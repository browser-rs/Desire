# v0.8.68 规划稿（2026-11-21）—— 各就各位：独立窗口打磨版 + Handoff 路由预案

> **主题叙事**：0.8.67 发版后首批真实使用反馈三条（对话列表批量操作不便 /
> 侧栏换设置页风格 / 聊天列放开固定限宽）**已全部修复**（a76da11c/b60dab36，
> 在 `[Unreleased]`）——本版以这三条为锚，定位**独立 Agent 窗口打磨版**；
> 旗舰小件 = **Handoff 路由预案实施**（activityType 支持 defaults 覆盖——
> 真机实测若被 Safari 强路由，`defaults write` 一键切换，不用改代码发版）。
> 规划前核实（2026-11-21）：① 历史列表多选**已有更完整形态**
> （AgentHistoryListView 显式多选模式：整行点击=勾选）——侧栏新多选与其
> 交互微差（⌘/Shift 点选 vs 整行点击），批内评估是否统一；② 独立窗口
> destinations 页复用既有视图（Inbox/Tasks/Stats 各自限宽逻辑合理——Stats
> 的 1100 上限是热力图可读性，保持）；③ Doctor 同步完整性检查已随 0.8.66
> 交付。

## 四主题

### ① 浏览器基础 = 真实使用反馈修复
- 0.8.62-67 的浏览器面（翻译 2.0/术语表/双语成书/快拨收敛/同步完整性卡）
  继续使用期——反馈到达即修，不预规划。

### ② Agent 基础 = 独立窗口打磨（主轴）
- **已落地锚点**（`[Unreleased]`）：对话列表多选 / NavigationSplitView 侧栏 /
  聊天列通栏（独立窗口传 nil，内嵌保持 960）。
- **Handoff 路由预案**（批 1）：HandoffRelay.activityType 支持 UserDefaults
  覆盖（`handoff.activityType`）——真机实测被 Safari 强路由时
  `defaults write me.siwi.Desire handoff.activityType me.siwi.Desire.browsing`
  一键切换（Info.plist 两端同步维护说明进注释与 AGENTS）。
- **多选交互统一评估**（批内核实后定）：历史页显式多选（整行点击=勾选）
  vs 侧栏多选（⌘/Shift 点选）——两处入口场景不同（历史页是全量列表、侧栏
  是常驻导航），交互是否要一致由实测手感定；倾向保持现状（侧栏常驻列
  单选导航优先、多选是低频管理动作）。
- 反馈修复预留（独立窗口新 UI 使用的后续反馈）。

### ③ 融合 = Handoff/Siri 真机验收闭环
- 真机实测三项（用户参与）：① Handoff 接力卡路由归属（→ 预案切换）；
  ② 接力卡三动作端到端；③ 0.8.66 的 Siri「问 Desire Remote」。
- 验收暴露的修复进本版（预留）。

### ④ 替人干活 = 运营收账
- 产品页已扩至 0.8.67（c4a66bb8）——部署提醒（固定手工步）。
- 服务端 desire-admin remote 子命令（0.8.65 交付）——**生产部署**固定提醒。

### 工程（贯穿）
- **全量回归节点**：execution-e2e 190 项（0.65→0.68 正好三版）在批 4 跑。
- i18n 三语 / WhatsNew / smoke / Release 零警告 / CI 双架构例行。

## 批次（建议实况更新）

批 0 已完成：三条反馈修复（a76da11c/b60dab36）。
批 1 Handoff activityType defaults 覆盖 → 批 2 多选交互统一评估 + 独立窗口
小件（实测反馈驱动）→ 批 3 真机验收闭环（用户）→ 批 4 190 全量回归 + 收口
（i18n/WhatsNew）→ 发版（用户指令）。

**实况（2026-11-21）**：批 1 完成（15413641，defaults 覆盖 live 验证 +
测试值清理）；批 2 评估结论 = 多选交互保持现状（历史页整行点击 vs 侧栏
⌘/Shift——场景不同，侧栏常驻列单选导航优先）；批 3 真机闭环待用户；
批 4 完成：190 项全量 ALL PASS（EXIT=0）。剩余 = 真机 Handoff/Siri 验收
（用户）→ 收口（WhatsNew 发版时刷）→ 发版指令。

**收口完成（2026-11-21，同日）**：WhatsNew 刷三条亮点（三语）——独立窗口
打磨 / Handoff 一键切换 / 体检管到同步。v0.8.68 内容收官：`[Unreleased]`
= 三条反馈修复 + Handoff defaults 覆盖 + Doctor 同步检查（0.8.66 已带）+
回归里程碑；190 全量 ALL PASS。**发版等用户**（真机验收 + 指令）。

## 不做

站点 Web Notification（WebKit 公开 API 缺口）；浏览器内代理（WebKit 无
per-view API）；--section（依赖图成本否决）；passkey（等 Apple）；隐私统计
（数据源否决）；节流/pixelRatio；第三方翻译；书签同址去重（语义豁免）；
新 Agent 大件（休整等反馈）；Android Remote；服务端大改；WidgetKit
（0.8.67 超预算砍除维持——除非真机反馈强烈要求）。

## 风险

- defaults 覆盖键生效时机：HandoffRelay 是 @MainActor 单例、activityType
  在每次 update 时读——运行中改 defaults 下一页导航即生效（无需重启；
  UserDefaults 标准域读取便宜）。
- 三条新 UI 的后续反馈可能引出连带打磨（如多选模式下搜索框行为、
  NavigationSplitView 在极窄窗口的表现）——预留批承接。
