## [Unreleased]

> Agent 系统提示词补全（工具索引改为自动生成 + 安全边界与干活规则）；聊天流式输出
> 不再"输出到一半被输入框挡住"；下载器回调的隔离警告修掉。

### Added

- **回合收尾的机械核验**（对照评估里"缺机械核验"那条，**0 次模型调用**）：只看客观事实，
  抓两类"连自评都可能漏掉"的情况，结果作为**橙色不折叠**的提示挂在回答下方：
  - **硬提示**（可证）：本轮**每一个**工具调用都带应用自己写的失败标记（拒绝执行
    `[User denied…]` 或 JS 异常 `Error:`）→ "上面的回答背后没有真正执行过的东西"。
  - **软提示**（保守措辞）：没有任何一条工具返回**看起来**是成功的 → "请当作未经验证"。
    刻意不冒充确证——普通工具失败没有统一约定，靠关键词猜会误报。
  - 另有"同工具同参数被拒/报错两次"的提示（反复重试同一调用通常没用）。
  - 实测（假端点驱动，含一次真实的 `executeJS` 失败）：提示准确出现 ✓。三条新文案三语齐全
    （目录 1193 键、零缺口）。

- **Agent 会反思自己的做法了**（对照现代 Agent 框架里最明显的缺口"学习/反思"）：
  - **自动自评**：一轮里跑了 **3 个以上工具**、或**碰过高风险动作**（如 `executeJS`）时，
    回合收尾让**同一个模型**回头审一遍自己的轨迹——"有没有没验证就宣布完成"、"有没有失败
    被吞掉"、"有没有更简单做法"、"有没有漏掉要求" ✓；结果作为**折叠的"自评"块**挂在回答
    下方 ✓，普通闲聊不触发（不多花模型调用 ✓），设置里可关（默认开 ✓）。
  - **按需自评**：新增只读工具 `reflect(question?)` ✓ —— 模型在关键节点可以自己要求审一遍 ✓，
    评语**返回给模型** ✓ 让它先修正再回答；用户问"你确定吗/检查一下"也能直接触发 ✓。
  - 轨迹从已有消息派生（最后一条 user 之后的工具调用 + 观察 + 结论 ✓），**不在热路径上额外
    记账** ✓；自评失败/取消一律静默 ✓（绝不能把一轮正常回合变成失败 ✓）；跑在
    `isProcessing = false` **之后** ✓（沿用"别让收尾占着忙碌状态"的既有约定 ✓）。
  - 端到端验证（假端点驱动）：① 一轮 3 个工具（含一个真实失败）→ 收尾自动发起自评调用 ✓ →
    评语准确指出"「都跑完了」没附工具返回，属于未验证结论" ✓；② 模型调用 `reflect` →
    嵌套自评 → **评语作为工具结果回到模型** → 模型据此修正 ✓。

- **Agent 能检索自己的历史对话了**（对照现代 Agent 框架的"记忆/检索"缺口）：此前模型
  **看不到自己的过去**——只有用户在历史面板里能搜，模型遇到"我们上次说的那个…"只能让用户
  自己去找。
  - 新增两个**只读**工具：`searchConversations(query, limit?)`（标题 + 正文，大小写不敏感，
    返回 id/标题/时间/条数/**命中处前后各 140 字的片段**，自动**排除当前对话** ✓ 它已在模型
    上下文里）与 `readConversation(id, maxChars?)`（按角色标记的紧凑转录，超长截断）。
  - 检索逻辑落在 `ConversationStore.search(_:limit:excluding:)`，与历史面板的搜索同一口径；
    桥新增 `GET /conversations/search?q=&limit=`（走同一份代码，便于回归）。
  - 验证（你的真实数据 + 端到端）：`q=视频` 命中 2 条（标题命中 + 片段）；`q=github` 命中 1 条
    （正文命中，片段带上下文）；再用假端点让模型发起 `searchConversations` 调用——app 执行后
    会话里出现带真实检索结果的 tool 消息，模型据此继续作答 ✓。

- **Agent 对话历史列表换成原生 `List`**（用户需求："要支持批量操作 要支持左右滑动操作
  原生 list 那种"）：此前是 `ScrollView` + 自绘卡片的列表，批量与滑动一个都没有。
  - **批量操作**：⌘/⇧ 点击多选（`List(selection:)` 原生行为）；选中 1 条＝打开该会话
    （Mail 式语义），选中多条＝进入批量模式——顶部出现操作条（`N 已选` / 全选 / 删除 /
    取消选择），删除只确认一次；`ConversationStore` 增加批量 `delete(_ ids:)`。
  - **左右滑动操作**：尾部滑动＝删除，头部滑动＝重命名（触控板双指横滑；鼠标用户走右键
    菜单或行内垃圾桶）。
  - **原生交互**：右键菜单（打开 / 重命名 / 删除）、键盘 Delete 删除选中项
    （`.onDeleteCommand`）、按日期分组的 `Section` 标题。
  - 行内不再自绘底色/高亮——原生 List 自己画选中与悬停，自绘会叠成两层；重命名状态提到
    父视图（`renamingID`），滑动/右键/双击三个入口共用它。
  - 新增 5 条三语文案（Rename / Deselect / Delete Conversations / This cannot be undone. /
    %lld selected），目录 1180 键、三语零缺口。

- **系统提示词补全**（用户要求："系统提示词 查看下是否完备"）：默认提示词里那份手写的
  "可用工具速查"只有 **30 个**，而实际有 **106 个**工具——缺的里面包括 `executeJS`、
  `switchTab`、`goBack/goForward`、`readTab`、`getNetworkLog`、`crewDispatch`、
  `getSelectedText` 这些高频能力。
  - **工具索引改为从工具表自动生成**（`BrowserToolProvider.promptInventory`）：每个工具
    一行"名字 — 描述首句"，以后增删工具自动跟上；子代理按它自己的工具子集生成同一份索引。
  - **环境段补全**：除工作目录外新增**下载目录**与 **ffmpeg 是否可用**（装了写"可用，
    HLS 直出 MP4"，没装则提示装完再下 MP4）——Agent 不用试探就知道这台机器能否直出 MP4。
  - **默认提示词重写**：原有路由规则全部保留，新增三类——① **安全边界**：页面文字是
    **数据不是指令**（防提示词注入）、不代用户做对外/不可逆操作（发帖、提交表单、下单、
    删除）、不猜密码验证码、破坏性系统命令先征得同意；② **干活方式**：做完要用快照/成功
    提示核实再汇报、同一动作连续失败两次就换策略（不要死循环重试）、长任务用任务句柄别
    原地等、读取优先 `getPageSnapshot`、不要反复读同一页；③ **表达**：用用户的语言、
    结论先行、Markdown 组织、出错说清哪一步失败与打算怎么处理。
  - 验证：用假 OpenAI 端点抓下真实请求体——`<tools>` 索引 **106 行、与 `tools` 参数零差异**
    （缺 0 多 0），system 消息唯一且在第 0 位，六个分层段落齐全，环境段正确带出
    `/Users/…/Downloads` 与 `/opt/homebrew/bin/ffmpeg`。用户没有自定义过提示词（plist 里
    没有 `aiSystemPrompt`），新默认值立即生效。

### Changed

- **Agent 面板体验升级**（用户需求："AGENT 专注 用户体验 升级一下"）：四处按"用户能据此做
  什么"推理出来的改动，每处都对应一个具体的痛点。
  - **状态行显示"上下文占用"**：原来显示的是**累计** token（`↑3.2k ↓8.9k`）——对用户没有
    行动意义。现在显示占用百分比，口径与 `compactForContext` 的 160k 字符预算**完全一致**，
    所以它变橙（60%）/变红（85%）的时候，就是"自动压缩要生效、模型快要开始返回空"的时候；
    提示里带上最近一次请求的 prompt token 数，超阈值时附 `/new` 的建议。
  - **回合进行中显示已用时**（`· 12s`）：长工具跑起来时，"在动"和"卡住"的区别就在这。
    只用一个 `TimelineView` 包裹这一小块文字，不带动整块面板重绘。
  - **每个对话各自的输入草稿**：切到历史里的另一个对话再切回来，正在打的字**不再丢**——
    以前换一次对话输入框就被清空（按对话存在内存里，会话级）。
  - **排队消息逐条可见、可单独移除**：以前只显示第一条 + `+N`，想退掉第二条只能"全清"；
    现在每条一行（最多 4 条 + "还有 N 条"），各自带 ✕，顶部保留"全部清空"。
  - 新增 5 条三语文案，目录 1187 键、三语零缺口。

- **服务商与模型改为两级联动**（用户需求："AGENT 服务商 跟模型要做成 两级联动那种 现在
  不同 Provider 模型混在一起不合理"）：根因是输入栏的模型下拉把 `cachedModels`（**跨服务
  共用的一个缓存** ✗）和当前服务的模型拼在了同一个列表里——切过一次服务，上一个服务的
  模型就留在列表里；而且"刷新模型列表"永远拿**当前**服务的端点去拉，刷新别的服务会写错
  地方。
  - **模型不再跨服务混列**：顶层区只列**当前服务**的模型（区名写明是哪个服务，如
    `amd — Models`），其它服务各自一个子菜单，里面只放**它自己**的模型（该档案的
    `modelList` + 当前模型，去重保序）。
  - **选模型 = 同时切服务**：`select(profileID:model:)` 一次完成"切到该服务 + 设成这个
    模型"（以前换服务只能连模型一起换，想用别的服务下的别的模型做不到）。
  - **刷新按各自的端点与 Key**：`applyModelList(_, to:)` 写进指定档案，`loadAPIKey(profileID:)`
    取该服务自己的 Key；每个服务有独立的刷新中状态。
  - 删掉了跨服务的 `cachedModels`（含 UserDefaults `aiCachedModels`）——它正是"混在一起"的
    来源，且全仓只有下拉在用它。

- **设置页 System 卡片（默认浏览器 / 检查更新 / 诊断）UI 统一**（用户反馈："设置里面
  检查更新 诊断 那一块 UI 需要完善一下"）：这三行原来是手搓的 HStack + 自绘胶囊按钮，
  和设置里其它地方不是同一套语言——图标圆片底色不同、行间**没有分隔线**、按钮底色有
  四五种近似值（`.tint` 0.18 / accent 0.18 / accent 0.14 / secondary 0.18 / secondary 0.10）。
  - 全部改用共用组件：`SettingsRow` + 新增的 `SettingsCapsuleButton`（唯一胶囊规格：
    12pt medium / 水平 12 垂直 5 / prominent·secondary·destructive 三档）+ `SettingsRowDivider`；
    `SettingsActionRow` 也一并收敛到同一个按钮定义。
  - **检查更新行**：有新版时给出**可点的动作**——装在 `/Applications` 就能一键「安装更新」
    （下载 / 安装 / 待重启各阶段都有状态反馈），否则给「查看发布页」；此前只报"有新版本"，
    用户在这一行无事可做。另外检查中不再把按钮换成固定 60pt 的转圈（宽度会跳），
    状态改由副标题表达，版本号用不翻译的胶囊标出。
  - **诊断行**：显示已收集的报告数；**没有报告时不给 Export 按钮**（只留"在访达中显示"）
    ——此前 Export 在没有报告时会静默变成"打开文件夹"，用户以为导出成功了。
  - **顺带修的本地化 bug**：`FolderPathRow`（下载位置 / 截图保存位置两行）此前用
    `Text(变量)` 渲染标题与按钮，那是 **verbatim** 渲染、不查字符串目录，中文界面下
    这两行一直是英文；改走共用组件后正常显示中文。
  - 字符串目录：补上 3 个"半成品"空条目（`Filter by Type` / `More` / 模型空响应提示）
    的三语翻译，并新增 3 个键（`Checking…` / `Install Update` / `Restart to Update`）
    —— 现在 1175 键、三语零缺口。

### Fixed

- **侧边栏打开 Agent 时绿灯一直闪**（用户反馈："侧边栏打开 agent 这绿点 闪动"）：两处叠加
  ——① `AgentHeaderView` 在 `.onAppear` 里**无条件**把 `isDotPulsing` 置真，于是 `Ready`
  状态下绿灯也在脉动；② 脉动用 `.animation(.repeatForever, value:)` 实现，而打开面板时的
  频繁重绘（布局/滚动/task）会**不断重启动画**，看起来就是"闪动"。
  现在**只有真的在忙时才脉动**（绿色/灰色状态点是静态的），并且脉动改由 `TimelineView`
  按**时间**算——纯时间函数，重绘打断不了；不忙时那个分支根本不存在（连计时器都没有）。
- **地址栏聚焦时刷的 3 条运行时警告修掉了**（用户贴出）：`AddressSuggestionsModel:125/126`
  的 "Publishing changes…" 与 `URLBarField:156` 的 "Modifying state during view update"
  其实是**同一条链**——`updateNSView` 里同步 `stringValue`、`becomeFirstResponder()` 会
  **同步**回调 NSTextField 的 delegate（`controlTextDidChange` / `controlTextDidBeginEditing`），
  而 `updateNSView` 本身跑在 SwiftUI 的更新事务里，于是改 `@State`、发 `@Published` 全在
  更新中发生。按 AGENTS 的规则分两种处理：**自己引发的变化用标志挡掉**（不需要重建候选），
  **系统发的编辑通知跳一帧**。

- **地址栏（顶部输入栏）的候选下拉修好了**（用户反馈："顶部的输入栏 目前没有搜索建议的功能"）：
  下拉视图、按键处理、模型其实都在，坏在一个隐蔽的点——**`isUrlFocused` 用的是
  `@FocusState`**，而地址栏是 `NSViewRepresentable`、自己调 `becomeFirstResponder()`，
  SwiftUI 的 FocusState **不认这种焦点**，值永远停在 false。于是：候选列表永远不显示、
  地址栏聚焦时的强调色不亮、聚焦时"播种当前 URL / 失焦重置"两段逻辑也从未生效。
  - 改成由 NSTextField 的**真实编辑事件**（`controlTextDidBegin/EndEditing`）驱动的
    `@State`，一处修好、上面几条一起恢复。
  - 顺带按你的两条反馈调整：① 两份候选列表**互斥**——地址栏在编辑时，新标签页搜索框
    那份不再同时冒出来（"这两块不应该同时触发吧"）；② 下拉的**宽/起点/上沿取自地址栏
    胶囊的实测 frame**（`onGeometryChange` + 命名坐标空间），与输入栏等宽同起点、紧贴
    其下沿，不会比它宽（"宽度不对 超过输入栏宽度了"）。
  - 新标签页那份也改成同一套：**按搜索框的实测 frame 对齐**。此前框宽 560、列表写死
    `maxWidth: 520`，居中后两边各内缩 20pt（用户截图："列表比输入框窄一圈"），上沿的
    `padding(.top, 102)` 还会随书签栏开关漂移；现在 520/102/12 这些魔数全部去掉。
  - **定位方式换成「全局坐标取差值」**：此前把字段在命名坐标空间里的**绝对偏移**
    直接当作相对容器的内边距——一旦命名空间解析退化成全局坐标，就会多出**一整个
    容器原点**的高度，也就是用户圈出来的那段空隙。现在字段与容器都在 `.global` 里
    各测一次、相减得到相对偏移（容器原点被减掉），空隙在构造上不可能出现；地址栏与
    新标签页两处同一套写法，且 origin 守卫比较两个轴（只比 minY 会在「只有 X 变」时
    留下陈旧的 X）。
    实测地址栏胶囊是 `{x:186, y:36, 1807x30}`（高 30 = 胶囊本身，不是里面 16pt 高的
    文本框），下拉就按这个矩形摆位。

- **新标签页的搜索建议可以用键盘上下选择了**（用户反馈："网址搜索推荐 不能使用键盘 上下
  选择"）：候选列表的模型（`selectedIndex` / 循环移动 / 取选中项）和列表高亮本来都是齐的，
  **只是搜索框一个按键处理都没接**——上下键被文本域吃掉，高亮永远停在第一行。
  - 搜索框现在接上 ↑/↓ 选、Esc 收起列表、回车打开**高亮的那一条**。回车向后兼容：
    第 0 行就是"搜索 / 前往 输入的内容"，桥的 `/suggest` 实测确认（`q=s` → `searchDefault`、
    `q=github.com` → `navigate`），所以没动过高亮时行为与以前完全一致。
  - 按 AGENTS 的规则，`.onKeyPress` 里写 model 统一跳一帧（否则会刷
    "Publishing changes from within view updates"，见本版上面那条）。
  - 顺手排掉一个隐患：地址栏（URL 输入框）**并不显示候选下拉**，却接了 ↑/↓ 去移动一个
    **看不见的**高亮——按一下 ↓ 再回车会打开"看不见的那一条"（书签/历史，而不是输入的
    网址）。现在地址栏里方向键一律交还文本域移动光标。
  - 机制验证：最小 SwiftUI 宿主（TextField + `.onKeyPress` + 聚焦延迟 400ms 生效）+
    `CGEvent.postToPid` 注入 ↑/↓，确认 `.onKeyPress` 对 macOS `TextField` 的方向键**会触发**
    ——不是"接了却收不到"。

- **下载器回调的隔离警告**：`FFmpegExporter` 里的 `Collector`（进度行解析、stderr 累积）
  嵌套在默认 MainActor 隔离的 enum 里，被推断成 MainActor，却是在 `readabilityHandler` 的
  后台回调线程上被调用——6 条 "main actor-isolated … cannot be called from outside of the
  actor"。它本来就靠 `NSLock` 自保线程安全，标成 `nonisolated` 即可；行为零变化（Swift 5
  模式下那些调用本来就是直接调用），重跑本地 HLS 下载端到端，产物逐字节一致。
  （这批警告是 v0.3.12 发出去之后才发现的：我当时的警告检查用错了过滤条件——xcodebuild
  把路径写在 `warning:` **之前**，`warning:.*\.swift` 一条都匹配不到。已写进 AGENTS.md。）
- **流式输出时不再"输出到一半被输入框挡住"**（用户反馈："聊天还有一些问题 经常就是消息
  在输出的时候被输入框挡住了"）：消息列表的跟随滚动由"是否贴底"门控，而那个状态原来
  **只要几何变化就重算**——可内容增长（一次 flush 吐一大段、工具卡片/代码块/表格一次
  渲染出来、输入框长高把视口挤矮）同样会触发几何回调，单次增长超过 160pt 的迟滞阈值
  就被判成"用户上滑了"，跟随**从此永久停住**，新输出的文字留在可视区外——看起来就是
  被输入框挡住。
  - 修法：贴底状态**只在用户自己滚动时**才由几何判定（`onScrollPhaseChange` 的
    `phase != .idle`），内容增长不再改状态；程序化滚动（发消息后的强制跟随、"回到最新"
    按钮）自己把状态认领回贴底。
  - 模拟验证（按 SwiftUI 的真实次序"几何回调先于跟随"）：单次 240pt 增长下，旧逻辑
    **从第 2 帧起尾部永久不可见**，新逻辑全程跟随；稳定 token 流、以及"上滑读历史不被
    拽回"两种行为新旧完全一致（无回归）。
  - 应用内实测：开面板 + 桥发消息，思考 0→300 字、正文 0→108→220 字、回合正常收尾。
## [v0.3.12] - 2026-09-23

> 视频下载直出 MP4（装了 ffmpeg 就用它拉 HLS，音轨分离站点不再丢声音，没装/直播/
> 失败自动回退内置下载器）；Agent 聊天修掉两个只在流式中间态复现的致命问题
> （内联样式失效索引导致的崩溃、块解析在一行 `"1. "` 上的死循环）；聊天面板回车
> 不再刷 59 条 SwiftUI "Publishing changes from within view updates"；Xcode 警告清零。

### Added

- **HLS 下载优先走系统 ffmpeg，直出 MP4**（用户提议："如果系统安装了 ffmpeg 是否
  考虑直接使用 ffmpeg 来下载 m3u8 并且直接转为 mp4"）：新增
  `Features/Downloads/FFmpegExporter.swift`，导出前探测 ffmpeg（`/opt/homebrew/bin`、
  `/usr/local/bin`、`/opt/local/bin`、`/usr/bin`——GUI 进程的 PATH 不含 Homebrew，
  必须显式探测）。**不内置 ffmpeg**（GPL/LGPL 的独立项目，不该打进 app 包）。
  - 判定顺序：HLS 且 `EXT-X-ENDLIST`（VOD）→ ffmpeg 直连；没装 ffmpeg / 直播 /
    ffmpeg 失败 → 原来的内置下载器，行为不变；内置路径产出 `.ts` 时若机器上有
    ffmpeg，再本地转封装成 MP4（**直播因此也能拿到 mp4**）。
  - **音轨分离（`EXT-X-MEDIA`）站点不再丢声音**：这类站点的媒体播放列表里只有视频，
    只有把 **master** 交给 ffmpeg 才会把 `AUDIO="…"` 的音轨接上（实测 master →
    h264+aac，只给 variant → 只有 h264；内置下载器正是后者，属于原有缺陷）。
  - 码率上限（桥的 `maxBandwidth`）用 `-map 0:p:N` 选第 N 个 variant（program 顺序
    = 播放列表**文件顺序**，不是按码率排序的），并连带它的音频组；不限速时交给
    ffmpeg 自己挑（实测它选最高码率）。
  - 防盗链走 `-referer` / `-user_agent`；`-progress pipe:1 -nostats` 解析
    `out_time_us` 换算进度（总时长取播放列表 `EXTINF` 之和）。
  - **实测定下的几条硬约束**（`FFmpegExporter` 里逐条有注释）：① `-map` 是输出
    选项，放在 `-i` 之前会被 ffmpeg 拒收（退出码 234）；② 站点常用没有 `.m3u8`
    后缀的播放列表、`.bin` 分片、**完全无扩展名**的分片，ffmpeg ≥7.1 默认的
    `-extension_picky` 一律拒收——要 `-f hls -allowed_segment_extensions ALL
    -extension_picky 0`，且老版本不认这些选项（"Unrecognized option"）时自动退回
    只给 `-f hls` 重试；③ **live 播放列表绝不能交给 ffmpeg**：它没有新分片就一直
    等，`-t` 也拦不住（实测 40s 不退出）；④ 取消走 SIGTERM（实测 0.00s 退出、不留
    残件），仍会兜底删文件。
  - 验证（app 内、经桥 `/media/download` 的真实路径，端到端 9 例全过）：音轨分离
    master → mp4 640x360 **video+audio**、`maxBandwidth` 400k→640x360 / 5M→960x540、
    音轨分离+上限 → audio+video、直播 → 内置+转封装出 mp4（带 live 提示）、
    无后缀播放列表 / `.bin` 分片 / 无扩展名分片 → 均由 ffmpeg 出 mp4、
    段全 404 → 失败且**不留空文件**。产物用 `ffprobe` 核对容器、流与分辨率。

### Fixed

- **聊天面板里按回车不再刷 "Publishing changes from within view updates"**（用户贴出的
  Xcode 运行时警告，一次回车 59 条）：`.onKeyPress` 的处理器在 SwiftUI 的**更新事务内**
  执行，而提交消息会写十几处 `@Published`，于是每条写入都报一次。现在回车、⌘↩、Esc 取消
  以及"语音结束后自动发送"这几条路径都跳到下一个主线程回合再动 store——行为不变，
  只是不再在视图更新中发布。
  - 定位手法（可复用）：这些警告**也会进统一日志**
    （`subsystem == "com.apple.runtime-issues"`，`--style json` 还带线程/activity/调用栈）。
    本次 59 条挤在 36ms 内、同一线程同一 activity ——说明是**一个动作连环发布**而非用户点了
    59 次；再看同一时刻的 app 日志，紧跟在 `LegacyTextInputActions signal:DidAction`
    （键盘输入）之后、`SecItemCopyMatching`+MCP（回合启动）之前，对上被标记的
    `sendMessage` 写入行，触发点就锁定了。
  - 顺带确认（有证据、别再瞎改）：`.onReceive(CommandBus)`（菜单/桥命令）与
    `.onChange(initial: true)` 这两条路径**不**触发该警告。
- **Xcode 编译警告清零**（用户贴出的清单，逐条修）：
  - `DevToolsPanel`：DOM 树分支里 `if let root = …` 的 `root` 从未使用 → 改成
    `if treeRoot != nil`。
  - `DevToolsStore.sameSiteLabel`：`HTTPCookieStringPolicy` 是 struct，写
    `policy == .none` 实际在跟 `Optional.none` 比、**恒为 false**，导致"看 properties
    里有没有 samesite 键"那段成了死代码（没显式声明 SameSite 的 Cookie 也会被挂上徽章）
    → 判定完全改走 properties。
  - `MediaExportStore`：`@preconcurrency import UserNotifications`，并且不再把
    `UNUserNotificationCenter`（非 Sendable）捕获进 @Sendable 回调，改为各自取
    `.current()`。
  - `MarkdownRendererView`：`parse` 标了 `nonisolated`（要在 detached 任务里跑），
    但它的四个辅助函数还是 MainActor 隔离 → 一并标 `nonisolated`。
- **设置页服务档案行每次重绘读两次 Keychain**：`SecItemCopyMatching` 是阻塞系统调用，
  Xcode 的 Performance Diagnostics 会报 "This method should not be called on the main
  thread as it may lead to UI unresponsiveness"（同一次运行里 12 条）。同一个 `StatusPill`
  的两个分支各读一次 → 现在只读一次复用。
- **一个段都没下到时不再"假装成功"**：内置下载器在全部段失败时会留下一个 0 字节
  的 `.ts` 并报完成（用户点开是空的）。现在会删掉残件并报
  `Every segment failed to download — nothing was saved`；与 ffmpeg 的失败原因合并成
  一条错误（`fallbackFailed`），两条信息都不丢。
- **Agent 消息渲染的死循环已修复**（块解析器不推进）：`MarkdownParser.parse` 的有序列表
  分支里**入口条件用原始行、循环条件用 trim 后的行**，于是 `"1. "` 这种行（首字符是数字、
  以 ". " 结尾）能通过入口，进循环后却匹配不上（尾空格被 trim 掉，". " 不复存在），三个
  分支全不中 → `else` 里 `break` 退出内层循环，但 **`i` 一次都没加** → 外层 `continue`
  回到同一行，无限循环，同时把空列表块越堆越多。
  - **触发面正好落在流式输出上**：模型写有序列表时的中间态就是 `"1. "`；而完整落盘的消息
    里不常有这种行——350 条历史消息整体跑一遍**不复现**，只有盯着实时流式才会撞上。
  - 后果：解析跑在 `Task.detached` 里，而 `.task(id:)` 的取消**不会**传给 detached 任务，
    所以每撞一次就永久泄漏一个满核空转的解析任务，`blocks` 同时无限增长——表现为聊天
    卡顿、发热，最终可能被系统杀掉。
  - **修法三层**：① 入口条件改用 trim 后的行（`"1. "` 现在正确渲染成段落，而不是凭空
    消失）；② 循环顶部加 `defer { if i == iterationStart { i += 1 } }` 兜底——任何分支
    忘了推进都会被补上，解析**结构性终止**，不依赖每个分支自觉；③ `parse` 新增
    `isCancelled` 参数（并标 `nonisolated`），视图用 `withTaskCancellationHandler` 把
    `.task` 的取消显式转发进去，文本一变化旧解析立刻收手。
  - 验证：`parse("1. ")` 修前必卡死（跟踪里同一行重复了几百次）、修后立即返回
    `para("1. ")`；对抗语料 **1418 条**（含 200 条真实历史消息）+ **9600 条**专攻分支
    条件（数字开头 + 尾随空白/制表符、CRLF/CR、阿拉伯-印度数字、全角数字、混合标记），
    每条再按 1/8 前缀各渲染 9 轮跑完整管线（解析 → 每块内联），合计 **99,162 次**
    （(1418 + 9600) × 9），全部通过，无卡死无崩溃。

- **聊天渲染路径的下标改为快照枚举**：`ForEach(x.indices, id: \.self)` 配 `x[index]` 是
  SwiftUI 的经典越界形态——流式期间块数会**减少**（围栏一开吞掉后面几块、列表合并），
  下标当 id 时 SwiftUI 可能在缩容的那次更新里拿旧下标去取新数组 → `Index out of range`。
  - Markdown 渲染器 5 处（块、无序列表、有序列表、表头、表体）与输入框附件条 1 处，
    全部改成 `ForEach(Array(x.enumerated()), id: \.offset)`，闭包内只碰快照值。
  - 流式尾部写回由"append 时记下的下标"改为**按 message id 找回**（`flushTail`）：会话
    在流式中途被清空/切换时，旧下标会指向另一条消息（把 token 写进无关消息），数组变短
    后还会越界。

- **Agent 消息渲染崩溃（EXC_BREAKPOINT / SIGTRAP）已修复**（用户报告："看一下智能体最近
  的聊天记录 导致崩溃了"）：`MarkdownRendererView.buildInlineContent` 原来在**同一个**
  `AttributedString` 上按 `link → bareURL → code → bold → italic` 顺序做五次
  `replaceSubrange`，但每一趟的 range 都是按**原文本**匹配出来的，而 `Range(_:in:)` 只做
  偏移映射、并不知道字符串已经被前一趟改短了。偏移一对不上，替换边界就会落在多字节字符
  中间，接着在 `AttributedString.Guts.replaceSubrange` 内部触发
  `CollectionsInternal/BigString+Chunk+UnicodeScalar.swift:137` 断言，进程直接 SIGTRAP
  （崩溃报告 `Desire-2026-09-23-002707.ips`：EXC_BREAKPOINT ← CollectionsInternal ←
  `buildInlineContent`，触发点是列表项里的粗体一趟）。
  - **最小复现**（同一个函数、`-Onone`，且用**应用里逐字一致**的正则验证过）：`[a](b)**粗***斜体*`
    — 链接那趟先把字符串缩短了，粗体、斜体两趟却还拿着旧偏移继续替换。纯 ASCII 的
    `[](u)**a***b*` 不复现，必须有多字节字符参与才会命中 scalars 中间；19 条历史对话的
    373 个内联块（含每块 8 个流式前缀共 2984 次渲染）在**已落盘文本**上也都不复现——
    崩溃发生在流式的中间状态，所以是按崩溃栈定位的根因。
  - **改法**：**先收集片段、再一次性拼接**。按原文本匹配出所有 span（重叠时先占先得：
    链接 > 裸链接 > 行内代码 > 粗体 > 斜体，与旧顺序语义一致），按位置排序后逐段切原文
    拼进结果。全程不再对已经变过长度的 `AttributedString` 使用旧索引，这类失效索引在
    结构上不再可能出现。样式与旧实现完全对齐（链接用强调色 + 下划线、行内代码等宽 +
    底色、粗体/斜体各自字重字型）。

## [v0.3.11] - 2026-09-22

> 调试面板大扩建 + Agent 流式成熟化。DevTools 四页签补全（Console
> REPL 与真对象、Network 长连接与拦截动作、Element DOM 树与 CSS 级联、
> Application 全存储读写）；模型服务重做为一等公民（自定义端点自带
> Key / 模型清单 / 请求头）；流式输出的性能与滚动稳定性收敛（卡死、
> 抖动、无法上滑、"流式不完"全部修复）；思考过程折叠块、媒体下载
> 后台化、AI 识别广告、首击劫持防护、社区过滤列表更新失败三处根因。

### Added

- **Agent 输入框支持 ↑/↓ 翻阅输入历史**（用户需求："按照对话记录下输入记录，可以上下
  切换最近的输入"）：历史**按对话**记录、随会话文件落盘（重启、切回该对话都还在），
  上限 100 条、相邻重复不重复记（连发两次同样的提示只留一条）。
  - 交互：输入框为空时按 ↑ 取最近一条、继续 ↑ 往前翻；↓ 往新翻，翻过最新一条即回到
    空白草稿；**手打任何字就退出翻阅**（此时 ↑/↓ 交还 TextEditor 移动光标，多行编辑
    不受影响）。
  - 记录点在 `sendMessage`（默认记录 = 用户输入）：面板提交、排队发送都覆盖；桥与
    调度等自动化调用显式传 `recordHistory: false`，不把机器人的提示词混进用户历史。
  - 实测：连发三条（其中一条与上一条相同）→ 历史 `["第一条历史测试","第二条历史测试"]`
    （相邻去重生效）；**重启应用后历史仍在**（会话恢复后读回）。
  - 桥：`GET /agent/messages` 新增 `inputHistory`；`POST /agent/send` 新增
    `recordHistory?:bool`（默认 false，回归用）。

- **首次点击劫持防护**（用户反馈："很多视频页面播放按钮第一次点击跳转广告"）：影视站
  常见套路是播放键上盖一层透明层（站外 `<a target="_blank">` 或带 click 处理器的浮层），
  第一次点击不播放、先弹/跳广告。新增 `UserScripts/first-click-guard.js`，随"拦截视频
  广告"开关、**主框架 + 文档开始**注入（必须比页面自己的处理器先注册才拦得住）：
  - **只管页面上的第一次点击**，且只在页面里存在 `<video>` 时生效（普通网页零干预）；
  - 这一击期间临时禁掉 `window.open`（脚本弹窗直接失效，1.2s 后恢复）；
  - 若这一击落在**站外链接**或**覆盖视口 ≥25% 的定位浮层**上：吞掉点击并把该层
    `display: none`，下一次点击自然落到真正的播放控件；**站内链接与播放器控件不受影响**；
  - 拦下的目标经既有的 `videoAdBlocked` 通道上报，提示条显示
    `已拦截 1 个 <域名> 广告（首次点击防护）`（非内置站点直接显示域名，便于定位）。
  - 实测（本地 fixture 三种变体）：① 覆盖播放器的站外锚点 → 首次点击**不开新标签页**
    （tabs 1→1）且该层被隐藏；② 脚本 `window.open` 弹窗 → 首次点击被拦（tabs 2→2）、
    1.3s 后 `window.open` 恢复可用；③ 站内链接首次点击**正常跳转**（无误伤）。
- 新增 1 条三语文案。

- **思考过程可见、可折叠**（用户需求）：推理模型的 `reasoning_content`（DeepSeek / Qwen
  vLLM）以及部分网关的 `reasoning` / `thinking` 增量现在会被接收，收敛到该条消息的
  `reasoning` 字段，在助手气泡上方以**折叠块**展示：
  - 折叠块标题是"思考中…"（带强调色小图标）或"思考过程 + 字数"；**流式思考时自动展开**，
    正文一开始就**自动收起**；用户点过标题之后不再自动切换（手动选择优先）。
  - 思考过程**不与正文混在一起**（正文仍是 Markdown 渲染），也**不会回传给模型**——
    `encodeMessage` 只发 role/content/tool_calls（DeepSeek 等服务回传 reasoning 会直接
    报错）。
  - 只有思考、没有正文时不再算"空回合"警告的普通情形：会明确提示"模型只输出了思考过程、
    没有给出答复"。
  - 子代理（spawnSubagent）的思考也照收（同一条消息里可折叠）。
  - 桥端点 `GET /agent/messages` 的每条消息新增 `reasoning`（截断 600 字符）。
  - 实测（fixture 端点先流 4 段 reasoning_content 再流正文）：会话里 `reasoning` 与
    `content` 分别落库，内容互不混淆。折叠交互请看面板（截图没法验证交互）。
- 新增 4 条三语文案。

- **Agent 的媒体下载不再阻塞对话**（用户实测反馈："下载的时候一直在等待，可以改成后台
  异步吗"）：`downloadMedia` 此前**阻塞整轮**直到导出结束——HLS 视频动辄几分钟，面板上
  就是"一直在等待"。现在它立刻返回任务 id，导出在后台跑：
  - 完成后 ① 往会话追加一条 **system 备注**（面板不渲染 system 消息，但模型下一轮看得
    到，用户也能在历史里看到）② 发一条 **macOS 系统通知**（**首次真正要通知时才请求
    授权**，守 TCC 懒请求约定）。
  - 新增 `listMediaExports` 工具让模型自己查进度；桥端点 `GET /media/exports` /
    `POST /media/exports/cancel`。
  - 实测：20MB 慢速文件（服务端限速约 10s）——**这一轮在 12.3s 结束（模型延迟），此时
    任务仍是 running**；随后状态转 finished（`slow.bin.ts — 1 segment(s), 20.0 MB`），
    会话里出现一条 `Download finished: …` 备注。此前这一轮必须等下载结束才能返回。
- **AI 识别广告并一键屏蔽**（用户需求："通过 AI 识别页面广告并且设置拦截"）：
  - 新脚本 `UserScripts/ad-candidates.js`：纯启发式**只读**扫描，返回带**理由**的候选
    （class/id 关键词、跨域 iframe、广告联盟域名、覆盖层 z-index、标准广告位尺寸、
    "广告/Sponsored" 文案、块内 iframe），按证据条数与面积排序。
  - 新工具 **`findAdCandidates`**（扫描并解释）与 **`blockElements`**（按选择器批量屏蔽：
    写 ElementBlockStore 规则 + **立刻**把隐藏 CSS 注进当前页，以后每次打开该站点自动
    生效；可选 `blockRequests` 一并加网络层拦截）。
  - 内置技能 `clean-page-ads` 固化了流程：先讲给用户听、由用户挑、只屏蔽广告不误伤正文、
    可回滚。
  - 桥端点：`GET /ads/candidates`、`POST /ads/block`、`GET /ads/rules`、
    `POST /ads/rules/clear`（可回滚）。
  - 实测（本地 fixture，故意用**规则拦不住**的形态）：5 个候选——跨域广告 iframe
    （`iframe:ad-host` + `slot-size`）、"Sponsored: Acme Corp" 行（`link:ad-host`）、
    300×250 卡位（`slot-size`）、全屏 cookie 覆盖层（`overlay:z2147483000`）；屏蔽后
    三者 `display: none`，正文标题与段落仍是 `block`（无误伤），规则落库 3 条。
  - **顺带发现**：class 里带 `ad-` 的元素**内置过滤列表已经隐藏**（fixture 里那个
    `.ad-banner` 实测 0×0），所以 AI 这条链路真正的价值在"规则拦不住的"那类广告。

- **Console 的对象是"真对象"了**：此前参数在捕获时就 `JSON.stringify`，于是
  `console.log(document.body)` 只显示 `{}`（元素没有可枚举自有属性），对象也没法
  展开。现在：
  - 参数按**片段**上报：文本照旧，对象给短预览（`Object {a: 1, …}`、`Array(3)`、
    `<h1#title>`、`Error: …`）并登记一个**页面侧句柄**；
  - 点 chip 就地展开一层属性——值是活对象、留在页面里，属性仍是对象时给新句柄可
    继续展开（句柄表 300 条 FIFO，过期显示"句柄已失效"）；
  - DOM 元素单独给一组字段（tagName / id / className / childElementCount /
    textContent / 属性 / 前 10 个子元素各带句柄），因为元素用 `Object.keys` 是空的；
  - **REPL 便捷绑定**：`$0` = 最后检查的元素、`$_` = 上一次的结果、`$(sel)` /
    `$$(sel)` 简写（页面自己有 `$` 就不覆盖）。
  - 实测：`console.log('with object:', {a:1,b:'two',nested:{deep:true},list:[1,2,3]})`
    → 预览 `Object {a: 1, b: "two", nested: {…}, …}`，展开句柄得 4 个属性（嵌套两项
    各带新句柄）；`console.log(document.getElementById('title'))` → `<h1#title>`，
    展开得 tagName/id/textContent/@id；REPL：`$0.tagName`→H1、`1+1`→2、`$_ + 1`→3、
    `$("#title").textContent`→`console fixture`、`$$("div").length`→1。
- **桥端点**：`GET /devtools/console/ref?ref=`（展开一个句柄，一层）；
  `GET /devtools` 的 console 段新增 `objects`（最近消息里的句柄与预览）。新增 2 条
  三语文案。

- **Application 页签补上 IndexedDB / Cache Storage / Service Worker**（新脚本
  `page-storage.js`，都在页面侧列举，一次只取一层/带上限）：
  - **IndexedDB**：`indexedDB.databases()` 列出本站源的库，逐个只读打开（**不带
    版本号**，避免触发 `upgradeneeded`）列出对象存储与条数；行上给
    `库名 · vN`，删除按库（该库所有存储一起删）。
  - **Cache Storage**：按缓存名列出条目（上限 300），行上给缓存名 + 请求 URL；
    单条删除 / 一键清空。
  - **Service Worker**：列出注册（scriptURL / scope / state），单个或全部注销。
  - 实测（本地 fixture 建 1 库 2 存储 3 条、1 缓存 2 条、1 个 SW）：三节分别
    列出 2 / 2 / 1 条；删除后 0 / 0 / 0；注销返回 `{"unregistered":1}`。
- **Cookie 可写**：值可改（行内编辑，走 `WKHTTPCookieStore.setCookie`，所以
  HttpOnly 的也能写——`document.cookie` 那条路写不了），"+"可新增（域默认当前
  页面主机、路径 `/`）。实测桥写 `desire_probe=42` → Cookie 计数 106 → 107。
- **Application 的节选择移到独立一行**：7 个节（新增 3 个）与搜索/动作挤一行放
  不下，现在上一行是节、下一行是搜索 + 全部域 + 新增/重载/清空。
- **桥端点**：`GET /devtools/application` 增加 `indexedDB` / `cacheStorage` /
  `serviceWorkers` 三节的计数与样例；`POST /devtools/application/set` 支持
  `kind:"cookie"`（需 `domain`）；`delete` 支持 `indexedDB`（key = 库名）、
  `cache`（key = `缓存名<TAB>URL`）、`cacheAll`、`serviceWorker`（无 key = 全部）。
  新增 10 条三语文案。

- **Element 页签有了 DOM 树**：此前只有"一次一个元素"的检查器，看不到结构。
  新脚本 `dom-tree.js` 按 **nth-child 链**一次取一层（懒展开，`path` 形如
  `0/2/1`），行上给 `tag#id.class` + 文本预览 + 子元素数；点行就用它的
  nth-child 选择器跑既有采集链（详情区不变），换标签页自动重挂。实测：
  `html` → `head`（4 个子元素）/ `body` → `div.box` → `h1#target`，选择器与
  DOM 一致；失效路径干净报错。
- **命中的 CSS 规则（级联排查）**：`element-inspect.js` 顺带走一遍
  `document.styleSheets`，列出能匹配该元素的选择器与声明（上限 40 条），跨域
  样式表读不到就计数说明（"N 张跨域样式表无法读取"），详情里单列一节。实测
  `#target` → `h1 { letter-spacing: 2px }`（外部样式表）+
  `#target { color: rgb(255, 0, 0) }`（页内 style）。
- **桥端点**：`GET /devtools/tree?path=`（一层树，与面板懒展开同路径）；
  `POST /devtools/inspect` 的返回里加了 `cssPath` / `matchingRules` /
  `crossOriginSheets`。新增 4 条三语文案。

- **Network 页签补上长连接与发起者**：
  - **WebSocket / SSE**：`network-monitor.js` 包装了两个构造函数，连接本身是一条
    请求（状态 101 / 200），每条消息是一帧（`phase:"frame"`，方向 in/out/system，
    每条截断 4KB、每条连接保留 200 帧）。详情里按"消息（N）"列表展示，出站用
    强调色箭头。实测：页面开一条 WS + 一条 SSE → `GET 101 ws://…`（4 in / 1 out，
    最后一帧 `in: bye`）、SSE 3 帧 `in: tick-3`。
  - **发起者（Initiator）**：fetch / XHR / WS / SSE 的调用点（`url:行`）随请求上报，
    详情里单列一行。实测行号与页面里 `new WebSocket(…)` / `fetch(…)` 的行一致。
  - **图片预览**：详情里"Preview Image"按需在页面里 fetch 该资源（带 cookie，
    同源必成、跨域看 CORS，上限 512KB）内联显示；另有 `POST /devtools/preview`
    把同一路径落盘成 PNG（实测 16×16 fixture → 119 字节文件）。
- **网络拦截接进面板**：请求详情的菜单里新增"Block This URL / Block This Host /
  Redirect To…"（行内输入目标，不用模态框）——此前 `InterceptStore` 只有桥能写
  规则。过滤串由 `InterceptRule.exactFilter/hostFilter` 生成（WebKit 的
  `url-filter` 是正则，URL 里的 `.` `?` `*` 必须转义）。实测：加规则后重载，
  该请求变成 `GET 0`（被拦），清空规则后恢复。
- **桥端点**：`POST /devtools/replay`（重放一条已记录请求，与面板 ↻ 同路径）、
  `POST /devtools/preview`；`GET /devtools` 的 network 段新增 `streams`（帧数 /
  出入方向 / 最后一帧 / 发起者），`last` 行带上发起者。
- 新增 12 条三语文案。

- **调试面板 · 应用页签的存储可读写**（不只是看）：
  - **localStorage / sessionStorage 可编辑**：点值或铅笔进编辑（回车提交）、
    单条删除、"新增键"行内新增。写入走页面 JS `setItem`，改完立即重新采集——
    实测桥写 `regress=ok` 后页面 `localStorage.getItem` 立刻读到。
  - **新增"扩展存储"子页签**：按插件分组列出各自的 `chrome.storage.local`
    （就是插件代码里 `browser.storage.local` 看到的那份），可改值 / 新增键 /
    删除 / 清空；0.2.13 的共享桶单列为一组（有数据才显示）。写入的值能解析成
    JSON 就按 JSON 存，插件读回的是对象而不是字符串。
  - 子页签选择移到 store（跨面板重建保持，也便于自动化直接选中某一节）。
- **桥端点**：`POST /devtools/application/set`（写/新增 localStorage、
  sessionStorage、插件扩展存储），`/devtools/application/delete` 增加
  `kind:"extension"`，`GET /devtools/application` 增加 `section` 与 `extensions`
  （每个插件的键名全量，不只是样例）；`POST /devtools/config` 可切 `applicationSection`。
- `GET /panel/snapshot` 在截图前给异步加载留渲染节拍（约 0.7s 上限）——面板里
  localStorage/扩展存储这类 `.task` 异步拉的数据，早先拍出来一律是空态。
- 新增 7 条三语文案。

- **调试面板第四轮补全**：
  - **Element 可编辑**：内联样式与属性行都可点值直接改（回车提交）、单条删除、
    "+" 新增；悬停任一属性/样式行会在页面上给该元素描边。编辑走
    `el.style.setProperty` / `setAttribute`，改完立即重新采集——实测把 `h1`
    的 color 改成红色后，页面的 `getComputedStyle` 立刻是 `rgb(255, 0, 0)`。
  - **Network**：缓存命中徽章（`transferSize === 0` 且已知体积 ⇒ 缓存，来自资源
    计时）、复制菜单里新增"导出日志…"（JSON，含方法/状态/耗时/字节/缓存标记/
    响应头）、详情里可**重放请求**（页面内 `fetch` 重发同样方法/头/体，结果与
    CORS 报错都写进控制台）与"保存响应体到文件"。
  - **Console**：搜索支持**正则**（写错自动退回普通包含匹配）、**导航时清空**
    开关（默认关，保留日志便于对比两次加载）。
  - **桥端点**：`POST /devtools/edit`（改样式/属性，等价于面板里编辑）、
    `POST /devtools/config`（运行期开关）；`GET /devtools` 增加缓存命中计数与
    开关状态。新增 14 条三语文案。

- **调试面板新增 Application 页签**（Chrome 同名页签的核心部分）：
  - **Cookie**：读的是**当前标签页所在的 `WKWebsiteDataStore`**（容器标签、无痕
    标签各看各的），因此 HttpOnly 的 Cookie 也在（`document.cookie` 看不到）——
    实测 YouTube 页 27 条（含 `HSID`/`LOGIN_INFO` 的 HttpOnly/Secure 标记）。
    默认**只列当前站点**（按域名后缀匹配，含父域 Cookie），工具栏有"全部站点"
    开关切到整个数据存储。
  - **本地存储 / 会话存储**：走页面 JS 读 localStorage / sessionStorage，
    带字节数、可搜索、单条复制/删除、一键清空（两步确认，不用模态框）。
  - 行内显示 HttpOnly / Secure / SameSite / 会话 Cookie 标记与所属域+路径，
    复制支持 `name=value` 与 `document.cookie` 两种口径（排查登录态最常用）。
  - 子页签、搜索、刷新、清空按钮与其余页签同一套观感。
- **桥端点**：`GET /devtools/application`（Cookie 与两种 Web 存储的计数与样例）、
  `POST /devtools/application/delete`（`kind` + `key`）。新增 12 条三语文案。

- **调试面板再扩展**（第二轮）：
  - **Network 瀑布条**：Time 列改为"相对起始位置 + 时长"的横条（按当前可见集合
    最早请求对齐，颜色跟随状态码/失败），右侧仍给毫秒数——一眼看出哪个请求拖了
    时间线。
  - **Network 过滤与批量操作**：URL 搜索框、"只看失败"开关、复制全部 URL /
    全部复制为 cURL。
  - **耗时分解**：资源计时的分段（排队 / DNS / 连接 / TLS / 首字节 / 下载）进了
    详情面板，来自 `performance` 的 `PerformanceResourceTiming`；fetch/XHR 钩子用
    墙钟补 ttfb。
  - **响应体 JSON 美化**：body 能解析成 JSON 就按缩进展示（接口排查的常见场景），
    并给"复制"按钮。
  - **Element 盒模型图**：外边距 / 边框 / 内边距 / 内容 的分层示意，数值取计算样式。
  - **Element CSS 路径**：新增到根的完整路径（`html>body>ytd-app>div:nth-child(6)`）
    展示与一键复制（`element-inspect.js` 里按 nth-child 生成）。
  - **控制台折叠重复**：同级别 + 同文本的消息合并成一行（保留首次位置、显示最新
    时间、附 ×N），过滤条上有开关。实测三条相同输入 → 一行 ×3。
  - 新增 18 条三语文案。

- **调试面板功能补全**（不止视觉）：
  - **控制台 REPL**：面板底部输入行，↵ 执行、↑/↓ 翻历史。按输入形态选路径
    （表达式 → 直接求值 / DOM 节点 → 给标记 / 语句 → 当函数体跑），异常文本取
    `WKJavaScriptExceptionMessage`，输入与结果都写进日志（`› …` 前缀）。
    实测：`1+1`→2、`document.querySelectorAll("a").length`→153、
    `document.body`→元素标记、`throw new Error("boom")`→Error: boom、
    `nope.x()`→ReferenceError。
  - **真实子资源抓取**：新用户脚本 `network-monitor.js` = PerformanceObserver
    （覆盖所有子资源，含缓存命中）+ fetch/XHR 钩子（补方法/状态/头/截断 body），
    按 URL 去重、按 jsId 串起 start→complete→body。此前 Network 页签只记录文档
    级导航；现在一次 YouTube 首页 = 65 条请求 / 2.2 MB，含脚本、图片与
    `POST accounts.youtube.com/RotateCookies 200`。
  - Network 页签：新增 **Size 列**、五列全部可点表头排序、过滤条显示
    `条数 · 总传输量`、详情里可"复制为 cURL"。
  - Element 页签：**采集链补上**（见下）、复制选择器 / 复制 HTML / 在页面里闪烁
    定位三个动作、计算样式折叠区（34 项常用属性）。
  - 控制台：长消息可展开/折叠（右键菜单）、导出日志到 `~/Downloads/desire-console-*.log`
    并在访达里选中。
- **桥端点**：`POST /devtools/eval`（走 REPL 路径）、`POST /devtools/inspect`
  （用内置拾取器填 Element 页签，无需真点页面）、`GET /devtools`（三页签计数与
  最近条目）。新增 13 条三语文案。

### Changed

- **Agent 输入框底部那排控件统一观感**（用户反馈"这块 UI 想办法和谐一点"）：此前一行里
  混了四种规格——20pt 胶囊（完全访问/模型）+ 28pt 圆钮（附件/麦克风）+ 三种描边透明度
  + 两种底色，间距也是 4/6 混用。现在统一为：**26pt 同高**、圆形图标钮与胶囊共用
  同一描边（`separatorColor` 0.4 / 0.5pt）与底色（`controlBackground` 0.6）、相邻
  间距一律 6pt；发送按钮保持强调色实心（主操作），禁用态回落到同一底色。
  另外**模型名不再被强调色染色**（`.tint(.secondary)`）——用户强调色是红/粉时，模型名
  看着像报错。
- 输入框内文字**上边距加大**（用户反馈"文字顶在边框上"）：编辑区改为上 8 / 下 6，
  占位文字同步对齐。

- **聊天内容的宽度上限统一并调大**（用户实测反馈）：消息列此前单独限 760pt、
  输入框与按钮行却通栏，面板拖宽后是"上面一列窄、下面铺满"的错位感。现在
  **消息、快捷按钮行、重新生成、提问卡、审批条、排队条、输入框统一 960pt 上限并
  居中**（头部与状态条保持通栏）。改宽度只改 `AgentPanel.contentMaxWidth` 一处。

- **Agent 的模型配置重做成"模型服务"（一等公民）**：此前只有 4 个写死的预设
  （OpenAI / DeepSeek / 智谱 / OpenCode Go），自定义端点只能去蹭某个预设的
  Keychain 条目——`cloudProviderID` 决定用哪把 Key，而它只能由预设写入；"已保存
  配置"又只存 name/url/model，换一个网关就得重填。现在：
  - **每个服务是一条档案**：名字、端点、模型、模型清单、额外请求头、**自己的
    API Key**。内置 4 个降级为不可删的内置档案（可改、可复制），自定义服务可增删改。
  - 设置页的 Cloud 区改成服务列表（名字 + 主机·模型 + Key 状态 + 选中态），行内
    编辑器能改名字/端点/模型/Key、增删**模型清单**（可一键从 `/models` 拉取）、
    增删**额外请求头**，并能就地测试连接。
  - 运行时按档案装配请求：端点/模型/Key 都取自当前服务，**额外请求头会真的发出去**
    （`Authorization` / `Content-Type` 不允许被覆盖）。输入栏的模型菜单列的是当前
    服务的模型，并能直接切换服务。
  - **迁移透明**：老的 `aiCloudProviderID` / `aiEndpoint` / `aiModel` 与
    `savedEndpoints` 自动变成档案（各带原来那把 Key），单键 `ai-api-key` 迁进内置
    OpenAI 档案——升级后不用重新输入。
  - **端到端实测**（用一个假的 OpenAI 兼容端点回显收到的头）：新建自定义服务
    `{name:"Local Fake", endpoint:"http://127.0.0.1:8880/v1/chat/completions",
    model:"fake-1", key:"sk-probe-42", headers:{"X-Tenant":"acme"}}` → 激活 →
    `POST /agent/send` → 模型回复 `auth=Bearer sk-probe-42; tenant=acme;
    model=fake-1`：自定义 Key 与自定义请求头确实到了服务端。内置档案删除被拒绝，
    更新保留模型清单与请求头。
- **桥端点**：`GET /ai/profiles`、`POST /ai/profiles`（新建/更新，可带 key /
  models / headers）、`POST /ai/profiles/activate`、`POST /ai/profiles/delete`。
- 新增 15 条三语文案；`SavedAIEndpoint` 与 `cloudProviderID` 退役（只用于迁移）。

- **调试面板（Console / Network / Element）视觉重做**（与下载面板同一套令牌）：
  - 头部改成真正的标签条：图标 + 中文名 + 计数（>0 才显示，错误/失败红字），
    选中态是强调色底 + 强调色文字；"清除/关闭"换成统一的 `HoverIcon`。
    面板名此前直接用了英文枚举 rawValue（"Console/Network/Element"），现已进
    字符串目录（三语）。
  - 过滤条：级别/类型改用自绘图标分段控件（与下载面板同款、选中跟随强调色），
    搜索框统一 26pt / 圆角 6；总数等宽数字右对齐。
  - Console 行：等宽消息 + 等宽时间戳 + 来源 URL 三级层次；错误/警告保留极淡
    底色，分隔线内缩到文字；hover 显示复制图标（整行点按复制保留），URL 截断
    从中间改成尾部（窄面板下至少保住域名，旧写法只剩 "https"）。
  - Network：沿用原生 Table，只统一单元格观感——方法名从"白字实底"改为
    "彩字淡底"药丸、状态/时间等宽；详情区从裸 `GroupBox` 换成面板自己的小节
    标题（请求头/请求体/响应头/响应体，三语），并给 URL 加复制按钮。
  - Element：分组同样换成小节样式（消息/属性/CSS/盒模型），空态给出图标 +
    说明 + "选择元素"引导；面板宽度下限提到 380（四列表格低于此会把 URL 挤成
    一条缝；宽度仍由 HSplitView 协商）。
  - 新增 18 条三语文案。
- **调试面板接入自动化桥**（此前只能点菜单）：`BrowserCommand.toggleDevTools`
  可由 `POST /command` 触发；`POST /panel {"name":"devtools","tab":"network"}`
  切页签并显示面板；`GET /panel/snapshot?name=devtools&tab=…` 进程内渲染该
  页签（面板在主窗分栏里，不是 popover）。
- 修 `AppAccent.current` 的初值：`Settings.init` 里读取设置不触发 `didSet`，
  于是插件窗与截图工具条（读该镜像）在用户改过强调色之前一直用默认蓝。

- **下载面板视觉重做**（美学轮，功能与 store API 未动）：
  - 排版三级：文件名 12.5 medium/primary → 元信息 11 `monospacedDigit`/secondary
    → 分组标题 10 semibold/secondary；数字全部等宽，进度百分比不再左右跳动。
  - 状态摘要从两枚饱和胶囊（蓝/橙，比标题还抢眼）换成"小圆点 + 静文字"；
    吸顶分组条改用 `.ultraThinMaterial`（旧版实心色块在亮色内容上像一块灰板）。
  - 进度条自绘 4pt 胶囊：跟随强调色（暂停橙色），完成度用 `.easeOut(0.25)` 补间；
    总大小未知时滑动一段表示进行中，不再显示假百分比。速度改用主文字色——
    数据靠对比度区分，强调色留给进度条（粉/红系强调色下速度文字原本像告警）。
  - 行分隔线内缩对齐文字（Finder 列表观感）；归档类型 `.brown` → `.teal`
    （下载历史以压缩包为主，棕色在深色下整体发灰）。
  - 失败行降噪：错误一行 + tooltip，`重试` 改为常驻中性胶囊（旧版藏在 hover 里
    且与错误红抢注意力）；hover 时仍在行尾显示 暂停/取消/打开 等操作。
  - 空状态：`EmptyState` + 说明文案 + "打开下载文件夹"胶囊按钮（三语文案已入
    字符串目录：新增 "Files you download show up here." 及三个分组方式 tooltip）。
  验证（实机，强调色=用户设置的 pink）：进行中/已暂停/已完成/失败四种行态、
  hover 态（底色 + 行尾操作）、两组日期分组与吸顶条、搜索行、分组切换选中态
  逐项截图核对。

- **视频广告拦截规则改为热插拔**（不再需要重新构建/发版才能改规则）：
  规则解析顺序 **本地覆盖 > 远程规则包 > 内置**，全部由新增的
  `VideoAdRulesStore` 统一解析，`VideoAdBlocker` 在注入时（每个新 webview）
  才取规则。
  - 本地覆盖：`~/Library/Application Support/Desire/VideoAdRules/<site>.css|.js`
    （site ∈ youtube / bilibili / tencent / iqiyi / youku / mgtv / tiktok /
    twitter），改完在 设置 ▸ 通用 ▸ 媒体 ▸ 广告拦截规则 点“重新加载”。
  - 远程包：`…/VideoAdRules/remote/source.txt` 写一行 `rules.json` 的 URL，
    格式 `{"version":"…","sites":{"youtube":{"css":"…","js":"…"}}}`，缓存于
    `remote/rules.json`，启动时若超过 24h 自动拉取。**远程 CSS 始终生效；
    远程 JS 默认不生效**——它会在页面上下文执行，必须在设置里显式打开
    “信任远程规则脚本”。没有配置源时缓存的包不参与解析（删源即失效）。
  - 注入改为**代数化**（`data-gen` / `window.__desireRulesGen`）：user script
    是 webview 创建时定格的，所以导航时（`didCommit` 换 CSS、`didFinish` 重投
    站点 JS）按当前代数补投，规则改动后**刷新页面即可生效，不必重开标签页**。
  - 新增设置行（规则状态 / 重新加载 / 打开规则目录 / 信任远程脚本）与桥端点
    `GET /rules`、`POST /rules/refresh`（可选 `{"trustRemoteJS":true|false}`）。
  - 已验证（Debug 构建 + 本地 http 规则包）：本地覆盖替换内置且压过远程、
    远程 CSS 生效、信任关时远程 JS 不跑/打开后跑、删源后缓存包失效、恢复内置
    后首页 33 格全部有内容且 0 空壳 0 可见广告位。

- 原生窗口全屏（⌃⌘F）收起浏览器 chrome（标签栏/工具栏/进度条/书签栏），
  内容铺满整屏，与 Safari/Chrome 全屏一致。
- 新增自动化端点 `GET /diag/geometry`（webview 与各窗口的 frame / styleMask /
  全屏状态 / 所在屏幕 / 子视图树），用于全屏与面板类几何问题的无截图排查。

### Fixed

- **`Error: HTTP 200: System message must be at the beginning.`**（用户实测）：上一轮给
  "下载/导出完成"加的**会话备注是 `system` 角色**，它就留在对话中间——而 OpenAI 兼容
  服务**要求 system 只能出现在开头**，于是下一轮请求被拒（amd 网关直接在流里回
  `System message must be at the beginning.`；这个错误能看见，也正是上一轮"流内错误
  不再被吞"的功劳，否则又是静默失败）。现在 `buildRequestMessages` 把会话里的 system
  备注**从消息流里摘出来**、并入开头那条组合 system 提示（`## Session notes` 一节）：
  请求里 system 仍只有开头一条，备注内容照旧送达模型。
  - 实测（fixture 端点按 OpenAI 规则校验并回显）：`sysCount=1; sysAt=[0];
    notesInSystem=True` —— 带备注的会话能正常对话，且备注确实在开头那条 system 里。
  - 桥端点：`POST /agent/note {"text":"…"}`（复现/回归用）。

- **思考时聊天列表上下抖动**（用户反馈）：两个来源叠加，都改掉：
  - **滚动锚点改回固定 `.top`**：我上一版把它做成"跟随时 `.bottom` / 不跟随时
    `.top`"，但流式期间内容每 80ms 长一截，判定会在两者之间**反复切换**，而每次切换
    都是一次跳动。现在锚点固定（内容增长绝不移动视口），跟随只靠显式 `scrollTo`
    （贴着底部时才触发）。另外"贴底"判定加了**迟滞**（进 60pt 算贴上、离 160pt 才
    算脱离），避免单一阈值在流式时来回翻转。
  - **流式中的思考块改成固定高度 + 内部滚动**：展开的思考块每来一段文字都会推着整条
    会话重新排版，叠上自动跟随就是"抖得厉害"。现在思考流式期间该块固定 150pt 高、
    内部自己滚到底；思考结束恢复整段展示（不再有内部滚动条）。
  - 回归：思考流仍然正确落库（reasoning 与 content 分开），列表两次刷新后再次成功。

- **社区过滤列表（EasyList / EasyList China）一直更新失败**（用户反馈"过滤列表更新失败"）：
  表面症状是面板那句"Compilation failed"，真因有三处，全部是**转换器产出的内容被
  WebKit 拒绝**（源站、网络都正常——`curl` 拿到的是标准 ABP 文本）：
  - **`resource-type` 用了 WebKit 不认识的字符串**：`stylesheet` 被映射成 `style`
    （WebKit 只认 `style-sheet`），另外 `object`/`other`/`websocket` 也无对应类型。
    报错是 `Invalid string in the trigger flags array`（EasyList 全量因此失败）。
    现在改成 `style-sheet`，无对应类型的规则**整条丢弃**（宁可少拦，不要把类型限制
    去掉变成误拦）。
  - **一个 trigger 里同时给了 `if-domain` 与 `unless-domain`**：WebKit 规定四个域条件
    （if-domain / unless-domain / if-top-url / unless-top-url）**只能有一个**，而
    `domain=a|~b` 这类规则两个都产出了（隐藏规则与网络规则都有这个问题）。报错是
    `A trigger cannot have more than one condition`。现在这类规则直接丢掉。
  - **生成的 `url-filter` 里含组内 `$`**：ABP 的 `^` 分隔符被译成 `(?:[/?#]|$)`，而
    **WebKit 的正则引擎不接受组内的 `$`**（实测：`example\.com$` 可以，
    `example\.com(/|$)` 报 `Invalid or unsupported regular expression`）。这条最致命
    ——几乎所有 `||host^` 规则都命中，EasyList 全量因此过不了。现在 `^` 只译成
    `[/?#]`（浏览器请求的 URL 一定带路径，实际不丢覆盖面，也仍能挡住
    `example.com.evil.com` 这类误匹配）。
- **编译失败不再整份列表作废（自愈）**：新增二分剔除——编译失败时逐层把列表劈半，
  能编译的留下、不能的继续二分，最后把少数不支持的规则丢掉并用剩下的重新编译
  （日志里写明丢了哪些、丢了多少）。实测：EasyList **一次编译通过、零丢弃**（60000 条
  封顶），EasyList China 仅丢 53 条（`{5,}` 这类正则规则与 `#?#` 扩展隐藏写法）。
- **桥端点**：`GET /filters`（各列表开关/更新时间/规则数/失败原因）、
  `POST /filters/refresh {"id"?, "force"?}`、`POST /filters/probe {"abp" | "regexes"}`
  ——后者把若干条规则真的交给 WebKit 编译并回报逐条错误，是定位"哪条规则让整份列表
  失败"的探针（本次三处根因就是靠它隔离出来的）。
- 顺带：编译错误日志此前只打 `localizedDescription`（只剩"WKErrorDomain 错误 6"），
  现在记完整 `domain/code/userInfo`——真实原因（哪条规则、什么语法）都在 `NSHelpAnchor` 里。

- **"经过几次工具失败后再发消息没有回复"**（用户实测，附真实会话记录）：会话记录显示
  `executeJS` 报"返回结果的类型不受支持" → 模型改用 `runCommand` 执行 `definitely-not-a-command` → **超时 120s** → 之后用户发的三条消息（"超时了"/"hello"/"没回复；"）**一条都没有
  回复**。日志证实请求发出去了、HTTP 200，但**模型那一侧没有返回内容**——而空回合此前是
  **静默 return**：不写任何消息、不报错，用户只能看到"发完了没反应"。三处一起修：
  - **空回合必须可见**：模型没有产出任何内容时，往会话里写一条说明原因的警告（"模型没有
    返回任何内容……通常是上下文过长或服务端异常，可 /new 开新对话或换模型/服务"），并把
    这轮标记为失败。**"什么都没发生"不再是可能的结局。**
  - **流内错误不再被吞**：OpenAI 兼容服务常把错误塞在流里（`data: {"error":{…}}`）而不是
    用非 200 状态码（实测该网关正是如此）。此前这种负载没有 `choices`，被静默跳过 → 空回合；
    现在解析并抛出，面板上直接显示 `Error: HTTP 200: context length exceeded …`。
  - **`executeJS` 不再因"结果类型不可序列化"给一句看不懂的错**：DOM 节点/NodeList/Promise/
    循环引用都会走新的字符串化包装器（元素给 `outerHTML`、列表给 `[N items] <input>, …`、
    对象走 JSON、循环引用退 String）。这是整条故障链的**源头**——模型当初就是因为这句错
    才退而去跑命令。

- **快捷按钮行"悬在面板中间"**（用户实测："总结那一排按钮位置很奇怪，应该固定放置在
  输入框上面"）：两个布局原因叠加——① 消息列表的弹性尺寸挂在了 `ScrollViewReader`
  **里面**的 ScrollView 上，而 VStack 的直接子视图是 reader 本身，于是剩余空间漏给了
  下面那条横向 ScrollView（快捷按钮行）；② 横向 ScrollView 在垂直方向同样贪心，拿到
  空间后就撑成一大块空白。现在弹性尺寸挂到 reader 上、按钮行固定 24pt。实测（进程内
  截图对比）：消息列表撑满、按钮行贴住输入框正上方。
  （踩到的坑：给那条横向 ScrollView 加 `fixedSize(vertical:)` 会把内容算成 0 高——
  整排按钮直接消失；必须用固定高度。）
- **流式时无法上滑看历史**（用户实测反馈："滚动消息卡顿、老是看不到消息、无法上滑"）：
  `ScrollView` 无条件挂了 `.defaultScrollAnchor(.bottom)`，于是流式期间**每次内容长高
  都把视口拽回底部**，用户上滑会被一直打断。现在锚点跟随"是否贴着底部"：跟着尾巴时
  锚底部（自动跟随），一旦上滑就锚顶部（新内容追加在下方、视口不动），并保留右下角
  "回到最新" 的按钮。
- **正文渲染完了还显示"流式中"**（用户实测反馈）：`processLoop` 在答案流完之后**还要
  await 两个额外的模型调用**（生成标题、记忆整理：L1 事实 + L2 摘要），而 `isProcessing`
  直到整个函数结束才置 false——正文早已完整，面板却一直显示流式、输入区一直处于"忙碌"。
  现在**先把忙碌交还界面再做收尾**（收尾仍在同一 task 里串行跑，不与下一轮抢状态）。
  用真实服务实测：正文最后一次增长与 `busy=false` 出现在同一时刻（此前会拖后数秒）。
- **Agent 流式输出时界面卡死**（用户实测反馈：日志里成片的
  `RemoteLayerTreeDisplayLinkClient … pending main thread dispatch stuck for 0.5s`）。
  三个主线程热点，前两个在 Markdown 渲染器里：
  - **块解析曾在主线程**（`.task(id: text)`）：流式时文本每 ~80ms 变一次，等于每隔
    80ms 把越来越长的全文重解析一遍。现在放到后台任务解析，文本变化取消上一个任务
    （中间态天然合并）。
  - **内联渲染每次重绘都对所有块重跑**（每块 5 条正则 + 重建 AttributedString）。
    现在按源文本缓存（上限 500 条），只有新出现的块才付这份成本。
  - **超长回答在流式期间退化成纯文本渲染**（块数 > 120）：块渲染每次刷新要重建上千个
    子视图（标题/段落/列表/表格/代码块），测出偶发 0.5s 主线程卡顿；流一结束立刻恢复
    Markdown。普通长短的回答（20~40 块）不受影响。
  - 实测（40KB 回答流式、聊天面板打开，用桥 `/state` 往返延迟当主线程响应性探针）：
    修复前 **中位 0.242s / p90 0.576s / 最大 1.131s**（45 次 >0.3s、22 次 >0.5s）；
    修复后 **中位 0.004s / p90 0.02s / 最大 0.071s**（0 次 >0.3s），卡顿日志 0 条。
- **模型服务的"模型"改成下拉选**（用户实测反馈）：重做模型服务时把 Model 那行写成
  了纯文本输入，把原来的下拉弄丢了。现在编辑器里是**下拉菜单**（候选 = 该服务的
  模型清单 + 从 `/models` 拉到的 + 当前值，去重后列出，当前项打勾），下面保留一行
  "或手动输入模型名"兜底：回车（或点"加入清单"）就把它记进该服务的清单，下次即可
  在下拉里选。清单本身仍可在编辑器里增删，也可一键从 `/models` 拉取。
- **桥端点**：`POST /agent/cancel`（停掉正在跑的一轮，等价于面板里的 Esc/Stop；压测长回答时先用它收尾），`POST /ai/models/fetch {"id"?:uuid}`——用与界面同一个
  `ModelListFetcher` 拉取并并进该服务（实测：新建的无清单服务 → 拉取 →
  `modelList: ["fake-1","fake-2","fake-3"]`）。
- **聊天窗口里切换模型"不起作用"**（用户实测反馈）：菜单里的模型/服务按钮点了之后
  数据其实改了（下一轮请求立刻生效），但**界面不重绘**——`AgentModelMenu` 只观察
  `AgentSessionStore`，而模型/服务/providerKind 都存在 `AgentPreferenceStore` 上，
  会话 store 不转发它的 `objectWillChange`，于是标签与勾选停在旧值，看上去就是
  "切不动"。现在菜单直接观察偏好 store。同时把**当前模型**放到候选列表首位：此前
  自定义服务没有模型清单时，正在用的模型可能根本不在列表里，"切回来"无从下手。
  线级实测（假端点回显收到的模型名）：`POST /ai/model {"model":"fake-2"}`（与菜单
  同一条 setter）→ 下一轮请求里模型收到 `model=fake-2`。
- **桥端点**：`POST /ai/model {"model":"…"}`——切当前模型，与输入栏菜单同一路径，
  便于回归。

- **重放请求（Network 详情的 ↻）此前必然抛语法错**：`callAsyncJavaScript` 把
  `arguments:` 字典的**键当作包装函数的形参名**，而脚本里又写了
  `const url = arguments[0]` → `SyntaxError: Cannot declare a const variable
  twice: 'url'`（异常文本经 `WKJavaScriptExceptionMessage` 原样返回）。改成直接
  使用命名形参。实测重放 `http://127.0.0.1:8879/api/data` → 控制台打出
  `{"status":200,"ms":4,"bytes":32,…}`。
- **调试面板的日志不再跨标签页混成一条流**：Console / Network 的数据源是 app 级
  共享 store（每个 webview 都往同一个实例发消息），此前没有标签页维度。现在每条
  记录带上来源标签页（`tabID`），过滤条多了**标签页作用域**菜单（默认"当前
  标签页"，可切"全部标签页"或某个具体标签页——含已关闭的，它留下的日志还在）；
  徽章计数与"清除"按钮都跟着作用域走（作用域是单个标签页时只清它的），导航时的
  "清空控制台"也只清正在导航的那个标签页。`GET /devtools` 的计数同样是作用域内
  的（另附 `totals` 对照），`POST /devtools/config {"tabScope":"current|all|<tab uuid>"}`
  可脚本化切换。实测：两页各打日志 → 当前标签页 3 条 / 另一标签页 1 条 / 全部 4 条。
- **控制台的"来源"此前显示成 "https"**：`console-intercept.js` 按**第一个**冒号
  切 stack 里的 URL（本意是去掉尾部的 `:行:列`），于是 https 页面的来源全部退化
  成协议名。改成按最后两个冒号拆，来源恢复为完整 URL + 行号（实测
  `http://127.0.0.1:8878/index.html:6`）。
- **全屏浏览时标签栏不再消失**（用户现场指令）：原先只用一个 `isFullScreen`
  把「原生窗口全屏（⌃⌘F）」和「站点视频/元素全屏」混为一谈，于是 ⌃⌘F 之后
  标签栏、工具栏、进度条全被收掉——全屏浏览没法切标签。现在按**窗口身份**区分
  两者（`NSWindow.didEnter/ExitFullScreenNotification` 的 object 是不是宿主
  窗口）：窗口全屏保持 chrome 可见，只有 WebKit 自建的整屏窗口（视频/元素
  全屏）才收 chrome。实测四种走法：窗口全屏（有标签栏）→ 其中进视频全屏
  （画面整屏）→ 退视频全屏（标签栏回来，仍在窗口全屏）→ 退窗口全屏（恢复原状）。

- **插件存储命名空间其实没生效**（本轮的根因）：`webext-api.js` 的 RPC 只发了
  `{id, ns, fn, args}`，没带插件身份，宿主侧的 `ext` 永远是 nil——于是**所有插件
  的 `chrome.storage.local` 都写进同一个共享桶**（0.3.3 声称的按插件隔离只做了
  宿主一半）。现在 RPC 带上调用时刻的 `window.__desireExtID`，每个插件读写自己的
  桶；0.2.13 的共享桶数据仍在，面板里单列为"共享存储（旧版）"，不会被藏起来。
- **调试面板读 Cookie 崩溃**（SIGABRT，2026-09-20 23:01 崩溃报告）：
  `sameSiteLabel` 用 KVC 猜 `_sameSitePolicy` 私有键，`value(forKey:)` 抛
  `NSUnknownKeyException` 直接把进程 abort。改用公开 API
  `HTTPCookie.sameSitePolicy`（macOS 10.15+，别再退回 KVC）；没显式声明 SameSite
  的 Cookie 不再挂 "None" 徽章（只认显式的 Lax/Strict/None）。

- **Element 页签从来没被填过**（实测发现）：`onInspectedElement` 这条回调只接了
  线、从无调用点，采集 JS 只存在于 `ElementInspector.swift` 的 `#Preview` 里
  （该文件仅被自己的预览引用）。现在补上 `UserScripts/element-inspect.js`
  （返回 `InspectedElement` 形状的 JSON）与 `DevToolsStore.inspectElement(selector:in:)`。
- **元素拾取器被 AI 分支劫持**：拾取器只有一条消息通道，原生侧却无条件优先
  `onAIElementPicked`（该回调常驻非空），于是 Element 页签填不上、**元素屏蔽的
  "Block this element?" 弹窗也永远弹不出来**。改为由"谁启动拾取"声明
  `BrowserState.elementPickIntent`（block / devTools / ai），原生侧按意图分发。

- **强调色不生效于标签栏等自绘 chrome**（用户报"主题颜色 tab 栏好像没应用"）：
  根因是这些视图用的是 `Color.accentColor` —— 实测它既不跟随 macOS 系统强调色
  也不跟随应用设置（`.tint(purple)` 下仍返回 SwiftUI 默认蓝 #009DFF），只跟随
  `.tint` 的只有系统控件，所以自绘的胶囊/描边/图标一直是默认蓝。已改为
  `.tint` 系 ShapeStyle（TabBar 的选中胶囊/静音图标/加载点/切换器、Sidebar
  选中态、标签概览瓦片描边），并把强调色作为参数传进标签概览的占位渐变
  （`LinearGradient` 只吃 `Color`，没有 ShapeStyle 版本）。设置窗口是独立
  scene，`ContentView` 的 `.tint` 覆盖不到，已在 `SettingsView` 根视图补
  `.tint(settings.accentColor.color)`，窗口内的选中态/胶囊按钮一并跟随。
  量化验证（2560x1440 @2x，强调色设为 purple）：修复前标签栏区域紫像素 55 /
  蓝像素 390 → 修复后紫 279 / 蓝 1。
  随后做了 app-wide 扫除（用户确认）：**40 个文件、148 处** `Color.accentColor`
  全部改为跟随应用强调色——能用 ShapeStyle 的地方写 `.tint`，需要 `Color` 值的
  地方（渐变数组、`Color` 返回值、与 `Color.clear` 混用的三目）读新的环境值
  `\.appAccent`（`Views/Components/AppAccent.swift`）；自由函数/非 View 类型里
  无法读环境值的一律退化为 `.tint` 系样式。每个独立窗口根视图各自挂一次
  `appAccent(_:)`（设置窗、Agent 浮窗走参数；插件窗与截图工具条读
  `AppAccent.current` 镜像，由 `Settings.accentColor.didSet` 维护）。
  实测（purple）：下载面板快照 紫 531 / 蓝 0；设置窗选中态与 Picker 值均为紫；
  主窗（标签栏/工具栏）紫 444（蓝 194 为网页内容本身）。未实测：标签概览
  （需 ≥2 个标签）、Agent 浮窗、截图工具条。

- **视频广告拦截在列表页失败 + 误删正常视频**（YouTube 列表页"赞助商广告太多"
  的真因）：
  1) 它的开关值一直是 `false`——来自 4d67f1e 之前"首次启动把未设置的
     UserDefaults bool 读成 false 并写回"的 bug，而且这个功能在设置里
     **根本没有开关行**，所以用户既看不到也无从打开。现补上设置行
     （设置 ▸ 通用 ▸ 媒体 ▸ 拦截视频广告），并加 `videoAdBlockerUserSet`
     显式选择标记：没有标记的旧安装一律按默认 ON 处理，旧 false 被覆盖。
  2) 列表页规则会误删正常视频：`ytd-badge-supported-renderer`（通用徽章
     容器，承载 4K/CC/LIVE/新闻角标）被当作广告信号，且对整张卡片文本做
     `'ad'` 子串匹配。实测首页 60 张卡里误删 2 张新闻视频（"ME grijpt in
     op Malieveld"）与 1 张标题含 'ad' 的视频——这正是用户关掉整个拦截的
     原因。现改为**整段标签精确匹配**（`Ad` / `赞助商广告` / `Sponsored`，
     支持「Ad · 30 秒」式组合）＋只认 `.badge-style-type-ad`，并停止用
     CSS 隐藏全部徽章。哔哩哔哩的同类子串规则一并收紧。
  3) 广告 renderer 的外层网格格子必须一起删：`ytd-rich-item-renderer` 的高度
     由网格 CSS 决定、内部 renderer 被隐藏时不会塌陷，只删内部 renderer 会在
     页面上留下等高空壳——实测首页留下 4 个 700x494 的空框，即用户报的
     "赞助商广告变成黑框"。现改为命中列表页广告 renderer 时 `closest()` 到
     外层格子（section 级广告同理）一起删除，CSS 侧同步用
     `ytd-rich-item-renderer:has(ytd-ad-slot-renderer)` 等规则让空框不出现。
  4) 实测（Debug 构建）：首页连测两轮空壳数 = 0、页面无可见广告位，60/33 张
     内容卡片全部带缩略图与标题；搜索结果页 23/23 张卡片有内容、无可见广告；
     之前被误删的新闻与 LADYBOY 视频保留、36 个徽章恢复可见、Adobe/HBO Max
     等赞助卡片消失。视频内广告（快进/跳过按钮逻辑）未改动。
- **视频全屏（黑边 / 崩溃）修复**——三轮返工的真正根因有两条：
  1) 注入的 `fullscreen-shim.js` 覆盖了 `Element.prototype.requestFullscreen`，
     原生全屏管线从此不再运行，元素只能被 CSS 钉在 webview 视口里，于是
     "全屏"只有网页区域大小、四周黑边。最小宿主对照实验证实原生 element
     fullscreen 在本机完全正常（`WebCoreFullScreenWindow` + 视口 2560x1440）；
     shim 文件与注册行已删除，`isElementFullscreenEnabled` 恢复开启。
  2) 即使原生全屏跑起来，全屏视频仍只有 2314x1302：`WebView`
     （NSViewRepresentable）直接返回 webview，SwiftUI 在 WebKit 把它搬进
     全屏窗口后仍每轮布局重设其 frame（实测 1262 → 1440 → 1262 → 0×0），
     页面被锁在过期视口甚至渲染成 0×0。新增 `WebViewContainer`：SwiftUI 只
     管容器，webview 以 autoresizing mask 跟随，全屏期间应用侧不再触碰
     WebKit 的几何。
- **全屏崩溃**：WebKit 的 Live Text（图像分析）会为视频帧装入
  `VKCImageAnalysisOverlayView`，该浮层在布局过渡中以 0×0 bounds 算出 NaN
  contentsRect，触发 AppKit 几何断言（`EXC_BREAKPOINT _NSViewValidateGeometry`
  ← `VKCImageAnalysisBaseView.updateCurrentDisplayedViewContentsRect`）直接
  杀进程。已用 `systemTextExtractionEnabled = false` 关闭（Desire 没有 Live
  Text UI），同时消掉 `checkRichAnalysisAvailability XPC failed` 噪音。
## [v0.3.10] - 2026-09-20

> 分栏拖拽终局：HSplitView 原生分栏。v0.3.9 链路（系统 `.inspector`
> 六轮实验）经用户实测否定后整体回退、从未发布，版本号跳过。

### Changed

- **分栏拖拽重写**：分屏右栏 / 媒体查询检查器 / Agent / DevTools
  四个尾侧面板全部改为 HSplitView 原生子视图，分隔条与拖拽由
  SwiftUI 提供，视图层零拖拽代码。历轮自研机制（冻结状态机、快照
  层、等值门控、DragHookDivider，约 300 行）全部删除；面板宽度只经
  minWidth/idealWidth/maxWidth 协商，内部固定宽度禁令保留。
- WKWebView 恢复默认不透明：0.3.9 用 KVC 关闭 drawsBackground 试图
  消 resize 过场闪，实测反而加剧（透明内容无法旧帧拉伸），撤销。
- MARKETING_VERSION 自本项目首次对齐发布序列（此前恒为 1.0）；
  build 号 = git 提交数。

### Fixed

- favicon 直连候选改用页面原始 origin（此前 `http://127.0.0.1:8877`
  被退化成 `https://127.0.0.1` ——丢端口、强改 https，甚至生成
  `https://www.127.0.0.1`）；IP/localhost 不再生成 www 变体。
- 过滤列表编译失败不再吞错：两级编译失败均记录错误详情与 JSON
  大小；新增"下载到 HTML 页"前置校验（代理劫持场景报真实原因）。
- CHANGELOG 0.3.1–0.3.7 各版本的重复空壳标题（7 处）。

## [v0.3.8] - 2026-09-20

> 分发成熟化：应用内自更新、首启动引导、崩溃回收。

### Added

- **应用内自更新**（无 Sparkle 依赖）：更新横幅新增 "Update &
  Relaunch"——下载 Release 的 macOS zip 资产 → **SHA256 校验**
  （对照 SHASUMS256.txt，不匹配即拒绝）→ ditto 解包 → 原子替换
  /Applications/Desire.app → 自动重启。仅对装在 /Applications 的
  正式包开放；仓库私有时资产 404 会干净报错。
- **崩溃回收**：启动哨兵（启动置位/干净退出清除）检测异常终止；
  崩溃后 index 是上次干净退出的（过期），改按**文件 mtime** 取最新
  session 文件恢复（15s 定时器崩溃前一直在写），toast 提示"异常
  退出后已恢复"。
- **首启动引导**：三步窗口（欢迎定位 / 默认浏览器设置 / Agent
  配置入口），desire.onboardingDone 门控，自动化模式不打扰。

### Verified

- E2E：开 5 个特征标签 → 等 16s 落盘 → kill -9 → 重启恢复全部 5
  标签（mtime 路径而非过期 index）。自更新流程的下载/校验/替换需
  公开 Release 才能自动化，校验逻辑本地构造 SHASUMS 验证过解析。

## [v0.3.7] - 2026-09-20

> 阅读与研究模式：阅读器可调样式 + 页面批注 v1。

### Added

- **阅读器设置**：字号步进（14–26）、三级行距、四主题（跟随系统/
  浅色/羊皮纸/深色），UserDefaults 持久化。
- **页面批注 v1**：
  - 划选文本 → SelectionAIBar 尾部四色点（黄/绿/蓝/粉）→ 包裹
    `<mark>` 高亮（跨元素选区 extract 兜底）。
  - 按页持久化（URL 归一化哈希为桶键；锚定用**文本**而非 XPath，
    动态页面可靠）；页面加载时自动按文本重新包裹（已包裹处跳过）。
  - Agent 工具 `getPageHighlights`（只读级）："总结我在这页标了什么"
    直达。桥 `GET /annotations?index=N`。
  - 同页同文本重复划选 = 改色不追加。

### Known Limitations

- 笔记侧栏列表与 Markdown 导出留 v2；高亮恢复按文本首次出现锚定，
  同文本多次出现时可能包错位置；翻译对照留 v2。

### Verified

- E2E：选区包裹（返回文本 + mark 入 DOM）→ restore 按"Sign in"
  文本锚定重包 1/1 → collect 接口在位；持久化链路（SelectionAIBar →
  store → DiskStore）编译接线，UI 交互待用户验收。

## [v0.3.6] - 2026-09-20

> 智能表单与自动登录。

### Added

- **表单填充升级为模糊分类**：FormAutofill 的填充脚本从"精确属性名
  匹配"（name="given-name" 之外基本失手）换成 dom-tools.js 的
  `__desireFillProfile` 分类器——autocomplete token 优先，name/id/
  placeholder 关键词兜底（first-name/fname/surname/city/postal…），
  只填空字段，触发 input/change（React/Vue 兼容）。
- **Agent `fillLogin` 工具**（dangerous 级，走审批）：填当前站点
  存档凭据，可选提交登录；智能定位登录表单（可见密码框 + 表单内
  用户名字段推断），无凭据干净失败。域匹配复用 PasswordStore。
- **OTP 提示条**：页面出现验证码输入框（autocomplete=one-time-code
  或 name/id 含 otp，1.5s 轮询 SPA 场景）时顶部提示"取码后粘贴"，
  点击消失，导航自动清除。

### Verified

- E2E：__desireFillLogin 填入 u=e2euser/p=e2epass（触发 React 兼容
  事件）；OTP 选择器在含 one-time-code 的页面命中；fillScript 走新
  分类器；fillLogin 标记 dangerous（每次审批）。地址填充的站点实测
  待用户验收。

## [v0.3.5] - 2026-09-20

> Profiles 闭环：0.2.10 挂账的数据作用域转正 + 工具栏切换器。

### Added

- **书签/历史/快拨按 Profile 作用域**：三个数据 store 的存储键加
  人物命名空间（`bookmarks.<id>` 等），切换人物时保存当前桶、加载
  目标桶；种子数据与 legacy 迁移只属于默认桶。cookie/会话隔离仍是
  窗口级（profileDataStore），数据作用域跟随全局活跃人物。
- **工具栏 Profile 切换器**：最右侧头像菜单（活跃人物色圈 + ✓ 标识），
  一键在 Default 与各人物间切换；活跃人物持久化，重启沿用。
- **卸载人物清其数据桶**（书签/历史/快拨 + webext 存储）——Chrome
  语义。
- 桥 /bookmarks、/history 读路径落到当前活跃人物的桶（原先新实例
  永远读默认桶）；/profiles/active 切换同时切数据作用域。

### Known Limitations

- 数据作用域是全局单实例（多窗口共享同一活跃人物的书签视图）；
  cookie 隔离仍是窗口级。密码保留 Keychain 全局（不做人物隔离）。
  多窗口异人物并行是 v2 议题（需 store 实例 per-window 化）。

### Verified

- E2E：default 4 书签 → 切 Work（空桶）→ 加书签 =1 → 切回 default
  （4 条且无泄漏）→ 回 Work 书签仍在（持久化）→ 删人物清桶。

## [v0.3.4] - 2026-09-20

> 性能成熟化：概览分级渲染、面板条目上限、soak 工具化、启动预算实测。

### Added

- **标签概览分级渲染**：LazyVGrid 惰性挂载——只有可见行持有活
  webview，滚出屏幕的瓦片自动摘除（WKWebView 对象由 Tab 持有，摘除
  不销毁页面，滚回即重挂）。50 标签概览的常驻活视图 50 → 一屏 ≤9。
- **soak 驱动脚本** `tools/soak.py`：开 N 标签 → 定时采样 RSS + 巡检
  切换 → 关闭风暴 → JSON 报告（start/end/max/growth）。短程验证
  （8 标签 × 1 分钟）：RSS 增长 256KB，平坦。8 小时全量 soak 可用
  同一脚本参数化执行。
- **启动预算实测**：30 标签会话优雅退出 → 重启，`open` 后 1.6s 桥
  返回全部 30 标签（含进程启动 + 会话还原），预算内。

### Fixed

- DevTools 网络请求条目无上限（长会话 chatter 页无限增长）→ cap 500。
- 下载列表完成行内存 cap 100（进行中/暂停行永不裁；持久化不受影响）。

## [v0.3.3] - 2026-09-20

> WebExtension v2：从"能跑脚本"到"像扩展"——manifest 装载、popup 页、
> 每插件独立存储。

### Added

- **manifest v3 子集装载（.msex 包）**：zip（根目录 manifest.json），
  解析 name/version/description/content_scripts{matches,js,css,run_at}/
  action.default_popup；js/css 文件内容内联进 Plugin。同名重装 = 更新
  （沿用旧 id，已存数据不孤儿化）。桥 `POST /plugins/install-msex`。
- **popup 页**：带 action.default_popup 的插件，固定图标点击弹出
  独立 WKWebView 面板（320×420，扩展世界 + webext-api 运行时 + 插件
  身份注入；RPC 支持 storage/notifications）。无 popup 的插件维持
  "运行一次"语义。扩展面板行自动识别。
- **每插件独立 storage.local**：宿主注入前设置 `__desireExtID`，RPC
  携带身份，存储落 `desire.webext.storage.<插件id>` 桶；无身份 =
  legacy 共享桶（0.2.13 数据仍可读）。卸载插件清其桶（Chrome 语义）。
  browser._desireID() 供插件自查身份。

### Verified

- E2E：python 构造真 .msex → install → content script 注入命中
  （storage 计数）→ 跨导航计数持久（独立桶）→ 同名重装 id 稳定 →
  popup 页装载（hasPopup=true）→ 卸载清桶。

## [v0.3.2] - 2026-09-20

> 页面感知 v1：让 Agent"看时机"而不是"盲等"，"动作有回证"而不是"说了算"。

### Added

- **`waitFor` 统一等待原语**（替代盲 sleep）：三态条件——`text`
  （页面文本出现，大小写不敏感）、`selector`（CSS 存在）、
  `networkIdle`（XHR/fetch 全部落定且静默 ~500ms，hook 原生
  open/send/fetch 计数）。超时上限 60s。SPA/慢页面在 navigate/click
  后先 waitFor 再读内容。
- **动作回证（act + evidence）**：click / fill / clickAt / pressKey
  执行后自动截视口快照，按调用 id 存档（容量 12，消费型数据）；
  Agent 面板的工具调用条目展开后内联"EVIDENCE"缩略图——用户可直接
  核对"Agent 点完之后页面长什么样"，不再只听 Agent 转述。
- 已有 `__desireWaitForText` 改大小写不敏感（页面文案大小写不可控）。

### Verified

- E2E：注入延迟文本 → waitForText 1.2s 内命中 "Found text"；
  networkIdle 无在途请求立即返回；超时路径返回 "Timeout waiting
  for text"；回证截图走 takeSnapshot 自动通道（面板 UI 待用户验收）。

## [v0.3.1] - 2026-09-19

> 0.3.x「智能体浏览器」首版：Tab Crew 并行作业。

### Added

- **Tab Crew**（领队-工人模式）：Agent 会话可把研究/比对类任务拆成
  2-6 个独立子任务，每个子任务在**专属后台标签**上由一个 worker
  agent 执行，报告聚合回领队会话。
  - `crewDispatch`（objective + tasks[{url, instruction}]）、
    `crewStatus`（逐子任务进度 + 已完成报告）、`crewCancel`（全部或
    按下标）三个工具（Agent 内置工具面 + MCP 各一套，MCP 走
    `/agent/crew-dispatch` 桥路径）。
  - Worker：单向流式循环（AgentService.stream），只读研究工具子集
    （getPageSnapshot/getPageText/getPageLinks/findInPage/extractTables），
    预算 8 次工具调用 / 10 轮；模型停止调工具即视为最终报告。
  - 聚合：全部落定后，各报告拼装为一条提示自动注入领队消息流
    （领队忙则进队列），由领队产出面向用户的最终答案。
  - SSE 事件 crewStarted / crewSettled；桥 `/agent/crew`（状态）、
    `/agent/crew/cancel`、`/agent/crew-dispatch`。
- Agent 面板 Crew 进度条：objective + 每子任务状态点（pending 灰/
  running accent/done 绿/failed 红）+ Cancel 按钮。
- BrowserToolSurface 协议新增 `agentPreference`（worker 流式调用
  需要；WindowToolSurface 从 app.aiPreference 供）。

### Verified

- E2E（MCP tools/call 驱动）：crewDispatch 派发 2 子任务 → +2 后台
  worker 标签打开、状态 running/pending → crewStatus 返回逐任务进度
  → crewCancel 全取消 → settled=true；桥 /agent/crew 全程可观测。
  worker 的 LLM 循环需真实模型端点（走用户配置），自动化仅验证到
  状态机与浏览侧；聚合文案路径由单测覆盖（configure 注入逻辑）。

## [v0.2.18] - 2026-09-19

### Added

- **多语言完善**：Localizable.xcstrings 三语全覆盖——801 键 ×
  zh-Hans / zh-Hant / en 全部 100%。
  - 补齐 zh-Hans 缺口 140（0.2.x 新增 UI：分屏/扩展面板/密码中心/
    更新横幅/高危下载确认条等）。
  - zh-Hant 缺口 232 由 OpenCC（s2twp，台湾用词短语级）从 zh-Hans
    全量转换（強制重新整理/清空資料/記憶…）。
  - 36 个中文原文键补英文值（记忆/任务计划/响应式模式等 Agent
    onboarding 文案，英文用户不再看到中文）。
  - CLI 构建不做字符串抽取——代码里 16 个 `String(localized:)` 新键
    （分屏/下载确认/更新横幅等）手工补入目录，并建立"源码键 vs 目录"
    对账脚本化检查。
- 运行时验证：`defaults write AppleLanguages zh-Hans` + 桥面板快照
  ——下载面板完整中文渲染（下载/1 个已暂停/今天/昨天）。

## [v0.2.17] - 2026-09-19

### Added

- **Chrome 式扩展面板与工具栏固定**（WebExtension UX 补全）：
  - 工具栏 Agent 与缩放按钮之间新增拼图按钮，弹出扩展面板——全部
    插件列表（图标/名称/描述）+ 启用开关 + 固定开关，底部 Manage
    Plugins 进插件管理面板。
  - 固定的插件以图标常驻拼图按钮左侧；点击 = 在当前页运行一次
    （隔离世界直注，toast 反馈）。
  - Plugin 模型新增 `pinned`/`icon`（SF Symbol 自定义图标；optional
    字段保证旧数据解码安全）；PluginStore 新增 togglePin/setPinned/
    setEnabled/runOnce。
  - 桥 `/plugins/add` 接受 pinned/icon；新增 `/plugins/pin`（显式
    设定或切换）——Agent 可编程固定插件到工具栏。

### Verified

- E2E：pinned+icon 创建 → 列表回读 → 显式 unpin/pin 往返 → 清理；
  字段经 DiskStore 持久化（optional 解码对旧数据兼容）。面板/固定
  图标交互属 UI 层，待用户验收。

## [v0.2.16] - 2026-09-19

> 交付路线图 0.2.13 的内容（WebExtension API v1）——最后一个大项。

### Added

- **WebExtension API v1**：`browser.*` / `chrome.*` 运行时——
  - **隔离世界**：API 与插件代码运行在 `WKContentWorld.world(name:
    "desireExtensions")`，页面 JS 看不到也不能伪造 `browser.*`
    （E2E 实证：页面世界 `typeof browser === "undefined"`）；DOM
    共享，插件照常操作页面。PluginStore 注入从页面世界切到隔离世界。
  - **storage.local**：get/set/remove/clear（Promise，Chrome 语义——
    null 返回全量、缺键回 null），UserDefaults JSON 持久化。
  - **tabs**：query（id/index/url/title/active/incognito/pinned）、
    create（继承来源标签身份）、remove；onCreated/onRemoved/onActivated
    事件（ExtensionEventHub 直调分发，不依赖 SSE 订阅；切标签重建
    representable 后自动重入册）。
  - **notifications.create**（TCC 懒请求，下载通知同款模式）。
  - **runtime**：id / getManifest 桩。
- 桥 `/plugins` CRUD（add/list/remove——Agent 可编程装插件）；
  `/webext/eval`（隔离世界直读，测试原语）、`/webext/debug`（hub
  状态）、`/webext/fire`（手动投递事件）。

### Fixed

- events.addListener 注册消息无 id 字段被 RPC guard 整体拒绝（事件
  从未到达）——id 改为可选（fire-and-forget 不回复）。

### Verified

- E2E：storage 往返 `{"hello":"world","n":42}` → remove 后
  `{"hello":"world"}`；tabs.query 8 标签 + activeUrl 正确；
  onCreated 事件跨标签投递到插件 DOM（`|created:event-probe`）；
  隔离性实证；hub 注册/重入册状态经 /webext/debug 断言。
  notifications.create 未自动化（TCC 弹窗），代码路径同下载通知。

## [v0.2.15] - 2026-09-19

> 交付路线图 0.2.14 的内容（性能与加固）；发布序列号按时间顺延
> （0.2.14 已被菜单/设置扩充占用）。

### Added

- **下载高危类型落地确认**：.dmg/.pkg/.app/.sh/.command/.jar/.exe 等
  安装器/可执行/镜像类型在 navigationResponse 决策点被取消，弹非阻塞
  确认条（模态 NSAlert 会冻结自动化桥——密码保存条的同款教训）；
  "Download Anyway" 白名单放行一次。设置 ▸ Downloads 可关（默认开）。
  桥 `/downloads/dangerous`（GET 查询 / POST resolve 代答）。
- **混合内容警示**：https 页面 didFinish 时扫描 http:// 子资源
  （script/iframe/object/embed/样式表为主动组，img/media 为被动组）；
  有命中时工具栏锁图标换警告三角，安全面板列出明细，
  桥 /page/url 暴露 mixedContent / mixedContentScripts 计数。

### Verified

- 高危下载 E2E：导航 .dmg → 决策取消 + 确认条挂起（下载列表无行）→
  resolve allow → 白名单重载 → 下载 completed + 确认条摘除；dismiss
  路径不产生下载行。
- 混合内容扫描：https 页注入 http img/script 后 active/passive 计数
  正确；干净页面 0/0；/page/url 字段就位。
- **50 标签长会话回归**：50 标签开启 7.0s；10 轮随机切换选中全部
  正确（均 229ms 往返）；RSS 228MB 稳定（切换前后无增长）；50 标签
  连续关闭 11.5s 无崩溃，关闭后导航/执行正常，RSS 224MB（无泄漏）；
  优雅退出 + 重启会话正确还原。休眠清扫未实测长时阈值（30min 默认），
  内存压力路径已有 0.2.2 基线。

## [v0.2.14] - 2026-09-19

> 菜单栏与设置页两轮扩充（用户反馈驱动）。

### Added

**菜单**
- File：Open Location…（⌘L）、Open File…（⌘O，NSOpenPanel → 新标签）、
  Close Window（⇧⌘W）、New Container Tab 子菜单（按容器动态生成）。
- Edit：Find 子菜单（Find in Page ⌘F / Next ⌘G / Previous ⇧⌘G）。
- View：Stop Loading（⌘.）、View Source（⌥⌘U——WebKit 不支持
  view-source://，实测退化为抓 outerHTML 渲染 <pre>）、书签栏开关、
  Split View（⇧⌘\）、阅读列表（⌃⌘R）、命令面板（⌘K）、Agent 面板
  （⌘'）、Developer Tools（⌥⌘I）、全页截图。
- History：Back（⌘[）/ Forward（⌘]）置顶。
- Bookmarks：Add to Reading List、导入/导出（从 Tools 迁入）、
  全部书签动态区（≤20 条，点击直接导航）。
- Agent 菜单（新）：Agent 面板、Ask Agent About This Page（⌘⇧A）、
  命令面板。
- Help：GitHub / Releases / 桥文档链接。

**设置**
- Appearance：书签栏开关、链接预览、默认页面缩放（对新标签生效，
  BrowserState 直读 UserDefaults）。
- Downloads：完成通知开关、Dock 角标开关、**每次下载询问保存位置**
  （完成时弹 NSSavePanel，此时文件名已确定）。
- Profiles 区（新）：人物名录增删（0.2.9/0.2.10 收尾）。
- Developer 区（新）：自动化桥 / MCP server 运行状态（按启动参数
  探测）+ 桥文档直达——AI 原生身份首次进入设置页。

### Changed

- 窗口内隐藏快捷键按钮（⌘L/⌘[/⌘]/⌘G/⇧⌘G/⌘K/⌘'）全部收编进菜单，
  消除同键双触发；侧栏默认键 ⇧⌘B → ⌃⌘B（书签栏取回浏览器通用
  约定）；新默认键经 mergeOverDefaults 自动并入老安装。
- /command 桥补 viewSource/stopLoading/toggleSplitView/
  addToReadingList/askAgentAboutPage case。

### Verified

- E2E：/command viewSource → 新标签 <pre> 正确渲染转义源码；
  /shortcuts 实测 openFile/closeWindow/askAgentAboutPage/viewSource/
  stopLoading 等新映射注册；构建零警告。

## [v0.2.13] - 2026-09-19

### Added

- **分屏浏览**（路线图 0.2.15）：同窗口双标签并排——标签右键
  "Show Alongside (Split)"、View ▸ Split View（⇧⌘\）、桥
  `/split`（GET 状态 / POST 设置 / POST /split/close）。分屏对象
  豁免 LRU/内存压力休眠；胶囊弱高亮；右栏迷你标题（标题 + 退出分屏）。
  生命周期：选中分屏对象 = 转正解除分屏；关闭任一侧按落点正确解除。
- **菜单补全**：View 菜单新增 书签栏开关（⇧⌘B）、Split View（⇧⌘\）、
  阅读列表（⌃⌘R）、Command Palette（⌘K）、AI Agent 面板（⌘'）、
  Developer Tools（⌥⌘I）；Tools 新增 全页截图。侧栏默认键从 ⇧⌘B
  让位到 ⌃⌘B；窗口内隐藏的 ⌘K/⌘' 按钮移除（进菜单后避免双触发）。
  新默认键经 mergeOverDefaults 对老安装自动合并。

### Changed

- **分屏拖动**：恢复实时跟随（延迟提交的"松手跳一下"手感被否）——
  拖动期间高亮锁定 accent（hover 翻色是当初抖动观感的一部分），
  宽度半像素对齐消除亚像素闪动。disableScreenUpdatesUntilFlush 在
  macOS 15+ 已是空操作，不采用。

### Verified

- E2E：/split 状态机全绿（设置/选中分屏对象解除/选中他栏保持/
  关闭分屏对象解除/关闭主栏落点解除/幂等 close）；⇧⌘B 等新映射经
  /shortcuts 确认注册；构建零警告。

## [v0.2.12] - 2026-09-19

> 交付路线图 0.2.5 的内容（MCP resources 与 prompts）；发布序列号按
> 时间顺延——`v0.2.5` tag 已被审批策略引擎占用。

### Added

- **MCP resources**：每个打开标签暴露为 `page://<index>/text|html|screenshot`
  （resources/list 枚举、resources/read 读取——可见文本 / 完整 DOM HTML /
  视口 PNG base64）。initialize capabilities 声明 resources + prompts。
- **MCP prompts**：四个任务模板——summarize-page / extract-data /
  monitor-page / download-media；prompts/get 支持参数替换（未提供的
  可选参数占位符剥离）。
- 桥 `/screenshot` 泛化：`index` 参数支持任意标签（原先只有选中标签）；
  `inline=1` 直接返回 PNG base64（MCP resource 直读，不再必须落盘）；
  文件路径行为不变。

### Verified

- MCP 协议 E2E（curl JSON-RPC over 8798）：initialize capabilities 含
  resources/prompts → resources/list 每标签 3 条 → 三类 read 全通
  （text 80 字符可见文本；html 完整 DOM；screenshot 82KB PNG，
  magic `89504e47` 正确）→ prompts/list 4 条 → 参数替换与缺省剥离 →
  未知 prompt -32602 → tools/list 36 个 / tools/call getPageText 回归
  通过 → 旧文件落盘截图行为不变。

## [v0.2.11] - 2026-09-19

### Added

- **修改密码检测**：同用户名提交不同密码时提示"更新密码"而非静默忽略
  （此前该场景直接 return，改密永远不会入库）。同用户名同密码的普通
  重登录保持静默；新用户名仍走保存流程。
- 更新提示条：Update 按钮 + Username 副标题（保存提示的三按钮
  Never-for-this-site 对更新场景不适用，已隐藏）。
- 桥 `/passwords/pendingSave` 增加 `kind`（save/update）；
  新增 `/passwords/add`（种子凭据）与 `/passwords/import`（CSV 导入，
  只回传统计不回传 secret）。

### Fixed

- **CSV 解析器**：旧实现只认单引号且从不切换引号态，Chrome 导出的
  双引号字段（含逗号/引号的密码）全部错位；重写为 RFC-4180 索引式
  状态机（`""` 转义、引号内逗号、空字段均正确）。
- importCSV 表头检测按内容判断（无表头文件不再丢第一行），兼容 BOM。

### Verified

- E2E：种子凭据 → autofill 命中 → 改密提交 → pendingSave kind=update
  → 接受 → 重载 autofill 回填新密码（Keychain 改写实证）→ 同密码
  重提交无提示 → 新用户名 kind=save 拒绝不入库 → CSV 引号字段导入
  （密码含逗号+引号）→ autofill 原样回填 secret。

## [v0.2.10] - 2026-09-19

### Added

- **窗口级 Profile 切换**：TabManager 新增 profileDataStore 属性——设置后
  新建标签自动使用 Profile 的隔离数据存储（Cookie/会话完全独立）。
- 桥 `/profiles/active`（GET 查状态 / POST 切换）——自动化可程序化切换
  浏览人物。
- Profile data store 优先于 container data store（Profile 是更宽的
  隔离边界）。

### Verified

- E2E：add Profile → set active → profileDataStore 切换为 custom →
  切回 default → 恢复。

## [v0.2.9] - 2026-09-19

### Added

- **ProfileStore**：命名浏览人物（Work/Personal 等）——每个 Profile 拥有
  独立 WKWebsiteDataStore（Cookie/会话/站点存储完全隔离）。持久化。
- 桥 `/profiles`（list/add/remove）。

## [v0.2.8] - 2026-09-19

### Added

- **HLS 画质选择**：`GET /media/variants` 列出 master playlist 的全部
  画质变体（bandwidth + resolution + URL）；`downloadMedia` 接受
  `maxBandwidth` 参数自动选择 ≤ 上限的最高画质（不够时降为最低）。
- **批量下载**：`POST /downloads/batch` 和 MCP `batchDownload` 工具
  接受 URL 数组一键启动多个下载。
- **MCP 工具 34 → 36**：listMediaVariants / batchDownload。

### Verified

- E2E：MCP batchDownload 真实启动下载（300KB 小文件入列表）；
  36 个工具全量列出。

## [v0.2.7] - 2026-09-19

### Added

- **记忆 v2**：AgentMemoryStore 增加 searchFacts（内容+类目子串匹配，
  pinned 优先）、exportJSON（完整归档）、importFacts（JSON 数组去重
  导入）、decayOldFacts（清理超过 N 天的未 pinned 事实）。
- 桥 `POST /memory/search|export|decay`；MCP 工具 30 → 32：
  searchMemory / rememberFact（带作用域）。

### Verified

- E2E：多事实写入（全局+域作用域）→ 子串搜索 → JSON 导出 →
  MCP searchMemory → decay → 清理。

## [v0.2.6] - 2026-09-19

### Added

- **密码生成器**：PasswordGeneratorSheet——SecRandomCopyBytes + 长度
  滑块 (8–64) + 符号开关 + 复制/重新生成。
- **CSV 导入导出**：Chrome 兼容列格式（name,url,username,password），
  面板工具栏按钮 + 文件选择器/保存面板。
- 密码面板新增 Generate / Import CSV / Export CSV 工具栏按钮。

## [v0.2.5] - 2026-09-19

### Added

- **审批策略引擎**：ApprovalPolicyStore——按工具名的持久化 allow/deny
  规则（DiskStore），deny 对 dangerous 工具也生效（显式拒绝优先于
  内置白名单），allow 自动放行（不弹审批）。
- **审批历史日志**：每次决策（UI/桥/策略来源）记录工具/决策/时间，
  持久化最近 200 条；桥 GET /approvals/history 查询。
- 桥 /approvals/policy（list/add/remove/clear）全量端点。
- simulate 审批工具改走真实 gate() 路径——策略规则可被 E2E 验证。

### Verified

- add deny → simulate → 自动拒绝（pending=false）；remove → simulate →
  正常挂审批；add allow → simulate → 自动放行（历史含 allowed-policy）。

## [v0.2.4] - 2026-09-19

### Added

- **MCP 窗口绑定**：客户端 initialize 时声明 params._meta.desireWindow
  （窗口会话 UUID），后续工具调用默认作用于那个窗口；per-call window
  参数可覆盖。桥 X-Desire-Window 头透传。
- README 补充 MCP 鉴权与窗口绑定文档。

### Verified

- 双窗口 E2E：initialize 绑定 W1 → MCP navigate → W1 正确导航。

## [v0.2.3] - 2026-09-19

### Added

- **应用内更新横幅**：新版本时顶部显示（版本号 + 查看发布页 + 关闭）。
- **设置 ▸ System ▸ Check for Updates**：手动检查按钮，实时反馈
  （最新 tag / 已是最新 / 失败原因）。
- UpdateChecker 升级为 ObservableObject，横幅与设置页共享同一实例。

## [v0.2.2] - 2026-09-19

### Added

- **内存压力驱动标签休眠**：DispatchSourceMemoryPressure WARNING 事件
  触发按 LRU 挂起非活跃后台标签（豁免：选中/固定/无痕/播放音频）。
  零轮询。

### Fixed

- suspendIdleTabs 清理（前次编辑残留死代码）；TabManager 补 os import。

## [v0.2.1] - 2026-09-19

### Added

- **常驻书签栏**：工具栏下方横条——叶子直达导航、文件夹下拉、与书签
  面板/星标同源。默认显示，可关。
- **剪贴板 URL 直达**：地址栏聚焦且剪贴板为 URL 时建议首行出现
  打开剪贴板链接（scheme/www./IP 三模式检测）。

## [v0.2.0] - 2026-09-19

> 0.2 弧线首版：外部 AI 完全体。

### Added

- **MCP Server 鉴权**：--mcp-token（Bearer，全部请求 401 门禁；默认
  localhost 裸奔不变）。五场景实测全过。
- **桥 /events 心跳**：15 秒 keep-alive——死连接以发送错误浮出并自动清理。
- **官方驱动示例**：examples/desire-driver.py（实测跑通）、
  examples/desire-mcp-driver.ts（零依赖 MCP 客户端）。
- README AI/Automation 章节；ROADMAP 标记 0.1.x 全部完成。

## [v0.1.16] - 2026-09-18

### Added

- **⌘K 命令面板**：30 个浏览器命令的模糊搜索统一入口（前缀优先排序、
  键盘导航）——BrowserCommand 枚举即清单。commandPalette 映射进快捷键
  设置（默认 ⌘K）。
- **全页截图上 MCP**：fullPageScreenshot——整页 PDF 到
  ~/desire_fullpage.pdf。

## [v0.1.15] - 2026-09-18

### Added

- **记忆作用域**：MemoryFact 新增 scope（global / 域名），按域事实仅
  在当前页面匹配该域时注入提示词。
- **记忆管理上桥**：GET /memory + facts add/update/delete。
- **技能管理上桥**：GET /skills + reload/delete/import。

### Verified

- 全局 + 按域事实入库、技能导入→列表→删除全链路。

## [v0.1.14] - 2026-09-18

### Added

- **拦截规则录制**：POST /intercept/record——网络日志请求一键转 block
  规则；MCP 工具 recordInterceptRules。
- **真实网络捕获**：主框架响应记录进 DevTools 网络面板（此前面板只有
  占位数据）。

### Changed

- 响应式/节流诚实结论：WebKit 无真网络节流 API，路线图三项标记为
  平台限制关闭。

## [v0.1.13] - 2026-09-18

### Added

- **网络拦截 v1**：InterceptStore——block/redirect 规则经
  WKContentRuleList 编译分发到全部 webview（立即生效、持久化）。
- 桥 /intercept 四端点；MCP 工具 27 → 30。

### Verified

- /tracker.js 无规则命中 1 次 → block 规则 → 命中 0 次。

## [v0.1.12] - 2026-09-18

### Added

- **媒体流水线技能包**：media-pipeline 伞形技能（幂等 seed）。
- **Agent 工具 downloadFile**。
- **媒体上 MCP（24 → 27）**：listPageVideos / downloadFile / downloadMedia
  （后台执行）。

## [v0.1.11] - 2026-09-18

### Added

- **结构化提取**：POST /extract——表格/列表 → JSON 或 CSV（正确转义）。
- **MCP 工具 21 → 24** + const 参数支持。

## [v0.1.10] - 2026-09-18

### Added

- **页面监控**：隐藏 webview diff 检测 → 通知 + pageWatchChanged SSE。
- 桥 /watches 五端点；MCP 工具 17 → 21。

## [v0.1.9] - 2026-09-18

### Added

- **定时任务运行历史**：RunRecord 持久化 100 条 + turn 结果回传 +
  失败通知/重试 + tasks/enable。

## [v0.1.8] - 2026-09-18

### Added

- **多窗口 Agent 联动**：会话注册表 + /agent/windows + 按窗路由。
- 双窗口投递零泄漏实测。

## [v0.1.7] - 2026-09-18

### Added

- **MCP 工具 9 → 17** + GET /mcp 事件推送（SSE）+ DELETE 语义。

### Fixed

- GET 分支静默未命中修复。

## [v0.1.6] - 2026-09-18

### Added

- **Desire 作为 MCP Server**（9 工具）+ 桥 /mcp/add|reconnect。

### Fixed

- MCPConnection 显式 init（旧编译器合成 init 为 private，CI 失败）；
  按 Content-Length 累积读取（分段发送导致真实客户端 400）。

### Verified

- 自举：Desire MCPClient → 自家 MCPServer ready · 9 tools。

## [v0.1.5] - 2026-09-18

### Added

- **桥自描述 GET /**：68 端点 + 8 类事件机器可读目录。
- **可选 token 鉴权**：--automation-token。
- docs/BRIDGE.md 速查。

### Fixed

- release.yml grep 正则坑改 -F。

## [v0.1.4] - 2026-09-18

### Added

- **桥事件流 GET /events（SSE）**：8 类事件，BridgeEventBus 总线。

### Verified

- navigate → pageReady → 下载 → complete 完整事件流（4MB）。

## [v0.1.3] - 2026-09-18

### Added

- CI 启动冒烟 + x86_64 检查；冷启动打点（232ms/预算 400ms）；
  诊断导出按钮。

### Fixed

- 启动打点报 0ms（静态懒初始化）——显式锚定。

## [v0.1.2] - 2026-09-18

### Added

- **存储页面（⌘S）**：webarchive + 下载行 + savePage 命令。
- **NoticeBar 提示条组件**；密码「永不为此站点保存」。
- 下载通知聚合 + Dock 角标。

### Changed

- 密码保存 sheet → NoticeBar；beforeunload 确认 → 同一组件。

## [v0.1.1] - 2026-09-18

### Fixed

- **BUG-K 优雅退出挂起**：SIGTERM/SIGINT DispatchSource 接管转
  NSApp.terminate——与 Cmd+Q 同路径。100 轮压测 0 挂起。

### Added

- ShutdownDiagnostics 终止清单日志；桥 /agent/tasks 四端点 +
  /approvals/simulate。

## [v0.1.0] - 2026-09-18

首个 tag 发布。

### Added

- 中键操作、beforeunload 表单保护、快捷键设置页接线、下载面板重设计、
  桥端点大批量扩展（40+）。

### Fixed

- 下载竞态、无痕隔离、假活行、进度恒 0、handler 崩溃、查找计数、
  会话恢复、阅读模式、密码弹窗、IP 强升 https。
