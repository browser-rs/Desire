# v0.8.69 规划稿（2026-11-21）—— 掌上指挥：DesireRemote 专项 + 反馈修复版

> **主题叙事**：0.8.67-68 连续两版做 Remote（Siri 意图 / Handoff 接力 / 扫码
> 授权入口修复），用户真实使用反馈正在进来（扫码入口缺失已修 2f243c9d）。
> 本版专项 = **DesireRemote 打磨**（融合旗舰），旗舰特性 = **手机发图给
> Agent**（多模态指挥：拍照/相册选图 → 桌面 Agent 视觉分析）。规划前核实
> （2026-11-21）：① iOS ChatView **无任何附件能力**（无 PhotosPicker，grep
> 零命中——真空白）；② Remote 通道**无图片上行**（Mac↔iOS 只有文本帧 REST
> push + sendToPhone 单向下载；Mac 端 Agent 的 lookImage 吃本地路径，图片
> 必须先落到 Mac 工作区）；③ Live Activity（灵动岛/锁屏回合进度）**无**
> （ActivityKit 零命中，部署目标 26.0 可用）；④ iPad NavigationSplitView
> 已有（0.8.38）；⑤ 语音输入已有。反方向（Mac→手机）0.8.38 已交付
> （sendToPhone）——本版补的是**指挥侧的多模态输入**。

## 四主题

### ① 浏览器基础 = 真实使用反馈修复
- 0.8.62-68 的浏览器面继续使用期：翻译 2.0/术语表/双语成书/快拨收敛/
  同步完整性/独立窗口三修复——反馈到达即修，不预规划。

### ② Agent 基础 = 使用期反馈修复
- 校准卡/产物登记/E28/独立窗口新 UI 的后续反馈预留。
- **多选交互统一评估结论落档**（0.8.68 批 2：历史页整行点击 vs 侧栏
  ⌘/Shift——保持现状，场景不同；不再重复评估）。

### ③ 融合 = DesireRemote 专项（旗舰）
- **手机发图给 Agent（旗舰）**：
  - 通道：Remote 上行加**图片帧**（拍照/相册选图 → JPEG 压缩 → base64
    分片或专用 REST 端点；大小闸 ~8MB 起批内定）——Mac 端接收后落盘
    到 Agent 工作区（`RemoteUploads/时间戳.jpg`）→ 自动附进当前会话
    （system 备注带路径，Agent 可直接 lookImage 处理）。
  - iOS UI：ChatView 输入栏加 PhotosPicker（相册多选）+ 相机拍照按钮；
    发送 = 图片 + 可选说明文字一起上。
  - 安全/边界：图片经端到端密文通道（与指令同密级）；Mac 端落盘白名单
    内（agent workspace）；失败明示（离线 → 提示"Mac 在线后再发"）。
- **Live Activity（Agent 回合进度）**：回合发起 → 灵动岛/锁屏实时显示
  （"Agent 工作中 · 已用时"）；完成 → 通知收尾（复用 RemoteNotifications
  既有完成通知）。ActivityKit + Widget extension（**0.8.67 砍掉的
  WidgetKit 基建在此复活**——Live Activity 必须带 widget extension，
  一次性补齐两件事）。锁屏更新频率遵守系统预算（update 频率节流）。
- **扫码授权入口**（已修 2f243c9d，随本版发布）：设置 ▸ 连接常驻
  "扫一扫登录 Mac" + mac 配对区三态引导。
- 真机联调反馈修复（Handoff 路由归属 / Siri / 扫码授权——用户验收中，
  预留；Handoff 被抢路由时 defaults 一键切已就绪 0.8.68）。

### ④ 替人干活 = 运营/部署收账
- 产品页 0.8.68-69 扩充 + 部署（固定手工步）。
- 服务端 desire-admin remote 子命令部署提醒（固定）。

### 工程（贯穿）
- iOS 构建零警告纪律（clean build 才算）；i18n（iOS 端文案中文硬编码为
  既有惯例，不引入本地化体系）；190 全量回归节点 = 0.8.71。
- 例行：run.sh / smoke / Release 零警告 / WhatsNew。

## 批次（建议实况更新）

批 1 图片上行通道（Mac 接收/落盘/进会话）→ 批 2 iOS 发图 UI（PhotosPicker
+ 相机）→ 批 3 Live Activity（widget extension + 回合进度）→ 批 4 反馈修复
预留 + 收口（WhatsNew/i18n/产品页素材）→ **真机联调（用户）**。

**实况（2026-11-21）**：批 1+2 完成（721f7923——手机发图全链：PhotosPicker
≤3 张 → 压缩 2048/0.8 → base64 切 24KB 片走加密 push 帧分片 → Mac 端按 id
聚齐落盘 RemoteUploads/ → system 备注（模型可见）+ photo-saved 回执手机；
双端构建绿）。**批 3 Live Activity 砍除**（同 0.8.67 条款）：widget
extension 是全新 target（数百行 pbxproj + App Group 门户注册 + entitlements），
手工编辑风险高且价值依赖真机反馈——留待 SwiftUI 正式加 target 后再评估
（活动数据管线可复用既有完成通知）。批 4 = 反馈预留 + 收口。
**剩余 = 真机联调（发图/Handoff 路由/Siri/扫码授权，用户）→ 发版指令**。

## 不做

站点 Web Notification / 浏览器内代理 / 节流 / 第三方翻译 / 书签同址去重 /
新 Agent 大件 / Android Remote / 服务端大改 / iOS Watch / 独立 iOS App /
云端渲染——全部维持既有否决或超范围。

## 风险

- 图片上行大小：base64 膨胀 1.37x + WS/REST 帧预算（32KB 教训）——
  **走 REST 上传端点不走 WS 帧**；JPEG 重压缩到长边 ~2048px（质量 0.8）
  控制在 1-2MB，多图分条发送。
- Live Activity 的 widget extension 加入 iOS 工程会影响构建产物结构
  （新 target + App Group）——App Group 用于 activity 数据传递（
  UserDefaults(suiteName:) 或共享文件）；工程改动量批 3 评估，超预算
  再砍（同 0.8.67 条款）。
- 手机发图的会话路由：发到"当前选中会话"——手机与 Mac 的选中会话可能
  不一致（手机切换会话 Mac 跟随是既有语义，风险低）。
