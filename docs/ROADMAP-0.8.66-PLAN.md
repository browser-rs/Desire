# v0.8.66 规划稿（2026-11-20）—— 一路顺子：打磨版 + iOS 快捷指令旗舰

> **主题叙事**：v0.8.65 规划前五连"清单≠核实"，v0.8.66 规划前再补三连核实
> ——**累计八连，存量池彻底见底**：pin tab（TabBar isPinned 分区）、复制标签
> （TabManager.duplicateTab）、自定义搜索引擎（settings.customEngines + 编辑器）、
> DPP 登录态指引（v0.8.8 A3）、DPP 跨源 iframe 穿透（`frame:` 前缀 + per-frame
> 提取）、DPP L1 扫描进 shadow（desire-protocol.js `>>>`）、iOS Remote 视图
> 面（Downloads/Jobs/Tasks/Excerpts/Files/Inbox 全有）全部已存在。**本版唯一
> 核实的新空白 = iOS DesireRemote 的 App Intents/Siri 快捷指令**（macOS 四意图
> 0.6.10 已有；DesireRemote grep AppIntent 零命中；部署目标 26.0 无版本约束）
> ——立为融合旗舰。其余全部让位：**0.8.63-65 六版新面（术语表/双语成书/产物
> 登记+预览/校准卡/同步完整性/E28/快拨收敛）进真实使用期的反馈修复**。
>
> **顺带文档清账**：docs/DPP-PROTOCOL.md 能力表"L1 属性扫描不进 shadow DOM"
> 行已过时（desire-protocol.js:99 起实现）——批内修正；DPP 记忆的"剩余=跨源
> iframe/L1"两条更正。

## 四主题

### ① 浏览器基础 = 真实使用反馈修复
- 0.8.62-65 的浏览器面（翻译 2.0/缓存/术语表/双语成书/快拨收敛/同步完整性）
  全部进使用期——**反馈修复预留**，不预规划具体项；反馈到达按
  「修复→CHANGELOG→同版打包」节奏处理。

### ② Agent 基础 = 使用期反馈修复
- 术语表注入、双语成书、校准卡、产物登记、E28 夹具的同上预留。
- **Doctor 面小补全候选（核实后按需）**：诊断卡把快拨重复组数并入
  （/sync/health 已有数据源，只加一行显示——不做则维持现状）。

### ③ 融合 = 旗舰「iOS 快捷指令 / Siri」
- **DesireRemote App Intents v1**（部署目标 26.0，AppIntents 框架直接可用）：
  - `AskAgent`（文本入 → 桌面 Agent 回答出）：复用 RemoteClient 既有
    WS prompt 通道 + 轮询收敛判据（照 macOS DesireIntents 的"新 assistant
    消息 + 不再处理中"模式）；Siri 可问。
  - `OpenSession` / `NewPrompt`：快捷指令编排"连接 Mac → 发指令"。
  - AppShortcutsProvider 注册 Siri 短语（中文/英文）。
  - 锁屏/后台约束与 macOS 版差异在批内核实（iOS 后台网络受
    BGTaskScheduler 限制——Siri 前台交互为主，诚实标注能力边界）。
- 真机联调反馈修复（0.8.63-65 的产物卡/PDF 预览/书详情帧——用户参与环节，
  预留）。

### ④ 替人干活 = 运营/文档收账
- **产品页 0.8.63-66 四轮内容扩充**（欠了三轮的手工活，本版一次结清：
  feature 行/featureList/llms.txt/sitemap 同步）+ 部署提醒。
- docs/DPP-PROTOCOL.md 能力表修正（L1 shadow 行）+ DPP 记忆更正。
- admin CLI remote stats/cleanup 已随 0.8.65 交付——**服务端部署**仍是
  手工步，本版提醒清单固定项。

### 工程（贯穿）
- 可靠性：发版闸门照例（Release 零警告 + smoke 27/27 + run.sh）；下个
  "每 3 版全量"节点 = 0.8.68。
- 可发现性：新 UI 的 VoiceOver 标签 + i18n 三语补全；WhatsNew 刷当版亮点。
- CI 双架构零警告例行。

## 批次（建议实况更新）

批 1 iOS App Intents（AskAgent 主链）→ 批 2 Siri 短语 + 编排意图 →
批 3 文档清账（DPP 表/记忆）+ Doctor 小补全（核实后）→ 批 4 反馈修复预留 +
收口（i18n/WhatsNew/产品页素材）→ **真机联调（用户）**。

## 不做

--section（0.8.64 否决维持）；passkey（等 Apple entitlement，外部依赖）；
隐私/拦截统计（数据源否决）；网络节流/pixelRatio（WebKit 无 API）；第三方
翻译引擎；书签同址去重（语义豁免）；新 Agent 大件（0.8.59-65 七版后继续
休整）；Android Remote（0.7 展望级，不进 0.8.x）；服务端大改。

## 风险

- iOS AppIntents 的后台/锁屏行为与 macOS 版差异大：Siri 交互要求前台联网，
  "结果出"的轮询在 iOS 后台会被挂起——批 1 先交付"前台问一次"的确定性形态，
  后台能力诚实标注不做（不写假 UI）。
- Siri 短语的中文本地化要在 Info.plist 的 intents 卡与 AppShortcuts 双侧
  一致（i18n 三语纪律）。
- 反馈修复预留批依赖真实使用——发版时机仍由用户按反馈攒够来定。
