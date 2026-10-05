## [Unreleased]
### Added

- **站点静音升级为劫持式（0.6.3 首项）**：原实现是逐元素一次性 `e.muted = true`——视频站播放器 1.5s 后自己取消静音就破功。现 documentStart 注入 page world 的 `HTMLMediaElement.muted/volume` 劫持（getter 分层：强制档恒 0 音量、非强制放行站点值），运行时开关 + MutationObserver 兜底迟到元素；独立宿主 spike 验证 round-trip（强制后站点 set false 读回 1、解除读回 0）。**Tab 挂起巡检新增豁免：Agent 正在操作的标签**（长任务的页面动作被挂起=腰斩）。
- **链接"在后台打开"偏好（0.6.3）**：设置 → 通用新增开关——开启后 ⌘点击/中键开新标签**不切换**（`addTab(makeActive:)` 只控选中态，插入位置随既有偏好）；默认关。真实站点的 E2E 驱动（中键注入）受 data: URL 限制待补，逻辑面（两处链接打开点 + 设置读写）已接通。
- **垂直标签栏（0.6.3 压轴）**：设置 → 通用「Vertical Tab Bar」开关——侧栏形态的标签列表（全高、HSplitView 分隔条可拖、宽度持久化；窄于 120pt 自动收成图标列），固定/普通分区、组色点、静音/播放状态内联、拖拽排序（原生 onMove → moveTab）、右键动作集与顶部栏同源；顺序即 `tabs` 数组顺序（与 `/state`、顶部栏一致）。站点整屏时侧栏随 chrome 收起。




## [v0.6.2] - 2026-10-05
### Fixed

- **⌘N / newWindow 静默失效（多窗口联动 E2E 抓到的既有 bug）**：带值 `WindowGroup(for: UUID.self)` 的 `openWindow` 必须用 `id:value:` 重载且 **value 传真 UUID**——id 单参重载与 `value: nil` 都是静默 no-op（新窗开不出来，桥 newWindow、CommandBus 路径全灭）。传真 UUID 直达新会话（等价 onAppear 的 mint 路径）。双窗 E2E 验收：桥按 window 参数分别 send，两窗各自会话零串台、conversationId 独立。

### Added

- **回合中检查点保存**：每个工具结果写入会话时立即落盘并冲盘（`checkpointSave` = save + `DiskStore.flushSync`，含并行批与拒绝结果）——此前只在回合开工/结束落盘，中途强杀会丢掉整段工具结果，恢复时模型只看到 "[interrupted]" 占位；现在恢复后模型能看到强杀前已完成的每一步。配套桥端点 `POST /agent/open`（把指定会话装载进活跃面板——强杀后面板自动还原的不一定是被打断的那个会话，先 open 再 resume）。
- **崩溃恢复提示**：启动时读干净退出标志（正常退出置位、启动即清除）——上次异常退出（崩溃/强杀）时提示"标签与会话已尽量恢复，被中断的回合在会话顶部有「继续」入口"；automation 模式只记日志不弹窗（E2E 友好）。
- **多窗口 Agent 联动 v1（部分）**：会话历史列表新增跨窗徽标（对话正被哪个窗口装载、是否运行中，2s 轻刷新）与右键「在新窗口打开」（开新窗并按会话注册差集装载对话）；桥 `GET /agent/windows` 每窗补 `conversationId`/`hasInterruptedTurn`（双窗互不串台的断言面）。**顺带修掉既有 bug ⌘N/newWindow 静默失效**（见 Fixed：带值 WindowGroup 的 openWindow 需传真 UUID）。
- **Agent 可靠性三连（0.6.2 深化）**：① **流式检查点**——最终回答的流式写回按 3s 节流落盘，长回答打一半强杀不再丢已流出正文（恢复时完整保留）；② **落盘副本现脱敏**——saveCurrentConversation 的副本层对当前回合 assistant 文本先 `SecretRedactor` 再写（流式检查点让保存高频化后，磁盘任何时刻都不该有未脱敏原文；内存不动，回合收尾的 redactTurnSecrets 才触发 UI 更新）；③ **deliveryTarget 跟随 key window**——此前只有"最新创建者接管"，切回旧窗后语音/定时/无 window 桥调用仍打到新窗会话（didBecomeKey 通知重绑，Cmd+` 切窗实测翻转）。





## [v0.6.1] - 2026-10-05
### Fixed

- **远程快照超中继单条上限静默失败（E2E 抓到）**：remote 信箱单条 32KB，长会话快照（100 条 × 2000 字符 + 多图）编码后超限被服务器 422 拒收——手机端永远停在旧快照且无提示。现在快照带 22K 字符预算逐级降级：全量 → 16 条短文（保截图预览）→ 丢预览 → 只留状态与白板，任何会话长度都能发出有效帧。

### Added

- **白板截图上板不再回传 base64（evidence 引用）**：image 块新增 `evidence` 字段（`"last"` = 本会话最近一张 screenshot/screenshotElement 结果，或显式 toolCallId），宿主侧从会话消息就地解析成 data URI——此前模型要把几 MB 的 base64 原样塞进 whiteboard 参数（纯 token 灾难）；解析失败带明确 Error（"call screenshot first"）。桥 `POST /whiteboard` 同一解析器。
- **白板撤销/重做**：store 级快照栈（每会话就近恢复，上限 50，不持久化），覆盖面板编辑**和 Agent 写入**——Agent 误 clear 也救得回；面板工具条 ⮌/⮭ 按钮（空栈禁用）+ 窗口级 ⌘Z/⇧⌘Z（重命名输入框编辑中放行给系统）；桥 `POST /whiteboard` 新增 `undo`/`redo` 动作（自动化同权）。
- **白板工具 `insert` 动作 + chart 块自定义高度**：`insert`（可选 1-based `index`，缺省=末尾）把块插到指定位置——补齐"逐块精确组装"的最后一块（get/edit/delete/move/insert 全了）；chart 块新增 `height` 字段（px，钳制 120-800，缺省 320；可选解码向后兼容旧 .board/落盘），高个子的图表不再被压扁。桥与工具同权；`insertingBlocks`/高度钳制进单测。
- **白板 Markdown 导出**：`WhiteboardSpec.markdownExport()` 纯函数（mermaid/chart 围栏化、note/table 原文、image 内联 data URI），面板「导出 Markdown」按钮 + 桥 `GET /whiteboard?format=markdown`——白板内容从此可贴进任何 Markdown 工具（文档/issue/笔记）。
- **Desire Remote 对齐白板与截图（双端）**：Mac 快照新增 `board` 帧（当前会话白板：标题 + 逐块类型/标题/200 字符预览/长度，**不带 base64**），iPhone 聊天页顶部出现白板条（块清单实时跟随，编辑仍在桌面）；截图类工具结果不再发 2000 字符的 base64 乱码碎片——改为「最近一张」降采样 JPEG 预览（预算 12K，四档自适应）+ 原始大小，iPhone 端直接渲染成图；whiteboard 工具消息收敛为轻提示 chip。





### Changed

- **仓库重组**：主浏览器 Xcode 工程移入 `apps/macos/`（`Desire.xcodeproj` + `Desire/` 源码相对布局原样保留，pbxproj/entitlements/Info.plist 零改动），与 `apps/ios/`（Desire Remote）平台对称，后续可按需扩展 `apps/android/`；`crates/`（rust 后端）留仓库根。同步更新 ci.yml/release.yml/release.sh/tests(run.sh SOURCES)/README 架构树/AGENTS.md 结构区；历史 docs 里的旧路径按当时记录保留不追溯。


## [v0.6.0] - 2026-10-04
### Added

- **会话历史显式多选**：头部「选择」按钮（行首出现勾选圈，点行=切换选中而非打开，Esc 或「完成」退出）+ 行右键菜单「选择」项。此前批量选择只能靠不可发现的 ⌘/⇧-点击；普通 ⌘-点多选仍可用。
- **DPP 演示场重建为可下单的迷你商店**：API 新增公开端点 `/demo/products|cart|orders`（CORS 收敛）：真实购物车与结账流程、L3 SDK `desire.expose()` 声明（类型化 price/number 字段）、购物车空态信号、SKU 选择器模板的 `add-to-cart`、`checkout`/`clear-cart` 标注 `effects: "outbound"`（审批流演示）、`order-placed` 事件（DOM watch + SDK `emit` 双通道）；演示 API 不可达时回退只读离线模式。
- **DPP 演示场 IM 游乐场 + 演示态落 MySQL（多实例正确性）**：`/demo/im/`（客服关键词、招聘面试两个机器人场景）+ 公开端点 `GET /demo/im/channels|messages`、`POST /demo/im/messages`；页面从纯轮询升级为 WebSocket `/demo/im/ws` 按访客订阅 Redis PubSub（服务端 20s ping 保活、连接无状态任意实例可投递），未配置 Redis 时服务端 no-op、2.5s 轮询兜底（设计内降级，与远程控制同款）。购物车/订单/IM 消息全部迁入迁移 0011/0012——API 按 nginx 轮询多实例部署（无 sticky），进程内状态会把访客的购物车劈到两个实例；结账走 `FOR UPDATE` 事务（并发不能双花），IM 会话按访客隔离（`channel` + `X-Demo-Client`）。
- **Agent 专属 DPP 配置面**：AI 设置新增「DPP 协议」区块（解析总开关、提示注入开关、未配置站点的默认事件级别、逐站点模式管理）+ 桥端点 `GET|POST /dpp/config`——此前事件级别只能 `/dpp/mode`、提示永远注入、解析无法关闭。
- **DPP 演示场论坛**：`/demo/forum/` 发帖/点赞/评论（迁移 0013，点赞按访客去重、计数由行计算），演示内容创建类动作（`new-post` 走 `effects: "outbound"`、`like-post`/`comment` 用 ID 模板选择器）、数字 `id` 视图字段、轮询 diff 派发 `forum-activity` 事件；卡片 DOM 增量更新——3.5s 轮询不清掉打开的评论区或写一半的草稿。
- **DPP 引导落地**：工具栏 DPP 徽标改为按钮——弹层显示页面声明摘要（views/actions/events 计数）、逐站点事件级别分段（关/草稿/自动）、提示注入开关；被抑制事件的 toast 带「为本站开启」当场切 draft——遇到 DPP 站即引导开启，而不是只指路设置页。
- **DPP 演示场扩到十场景**：booking（迁移 0014：槽位可用性 `bool` 视图字段、日期型预订、多参数 `book` 动作唯一约束拦双订回 409）、news（确定性合成文章 + 视图级 `pagination: {type: "paged"}` 使 `pageExtract(all)` 自动跨页收集；末页**移除**下一页按钮而非禁用——收集器以选择器消失为停）、dashboard（聚合其他场景真实表格，演示 `busy`/`error` 信号与 `stats-updated` 事件）、onboarding 向导（三步 hash 路由 SPA 每步换声明，dpp-route-watch 重解析接管）、审核台（操作论坛真实帖：隐藏/恢复/删除，删除标 `danger: true` 最强审批门）、商品详情页（shadow DOM `>>>` 选择器 + 同源 iframe）、遗留页（零改造 L0：纯 schema.org JSON-LD potentialAction 映射动作）；站点级 `/.well-known/desire.json` 声明整个演示域，well-known 合并对每个页面生效。
- **协议 §4.3.1 `content.sections`**：命名内容区域（语义名 → 选择器），Agent 经 `getPageText(section:)` 只读单区域而非整页（未知区域报错并列出可用名单，不瞎猜）；§4.2 新增 `stable` 信号（「数据就绪」区别于 `ready` 首帧渲染——navigate 在 ready 后继续等 stable，模型不再读骨架屏）；§4.3.2 固化表格数据声明约定（行=条目、列=类型化 `td:nth-child` 字段）。容错解码同收嵌套（well-known 原文）与拍平形态，非法值丢弃记 warnings。全部在 `/demo/guide/` 帮助中心页演示。
- **内置白板（一期）**：专用白板窗口吃结构化块——Mermaid（思维导图/流程图/时序图，vendored mermaid 11）与 ECharts（柱/线/饼，vendored echarts 5）+ Markdown 便签，零 CDN。新 `whiteboard` Agent 工具（render/append/clear），面板跟随活跃会话、导出 PNG；入口：Agent 面板头部调色盘 / ⌘ 菜单 "Show Whiteboard" / `POST /command toggleWhiteboard`；板按会话分存（同任务计划）。
- **白板入口与渲染加固**：`GET /whiteboard` 桥端点与 `panel/snapshot?name=whiteboard` 离屏卡供断言；修复 spec 推送落在 loadHTMLString 完成前的 about:blank 文档（板永远空且无报错）——推送等文档落地；渲染统计进统一日志作硬证据。
- **白板二期**：跨重启持久化（DiskStore 按会话 map、上限 24 块板）、逐块管理（hover 工具条上移/下移/删除/编辑源码，保存经 store 全量重渲）、新 `table` 块（markdown 表格渲染成真表格，Agent 工具类型同步扩展）、块清单快照端点。
- **白板 2.5 期**：Agent 消息里的 mermaid 代码围栏内联渲染成真图（共享隐藏 webview 渲染服务、按源码缓存 SVG/图片、失败回退代码原文、一键「投到白板」）；面板支持手动加块（四类模板进源码编辑）、`.board` JSON 导出与追加导入；新增共享 MermaidRenderService（隐藏 webview、串行队列、FNV 键缓存）。
- **网页选区 → 白板**：右键选中文本出现「加入白板」（与"搜索所选"同管线），浏览器命令 `addSelectionToWhiteboard`（菜单+桥）取当前标签选区追加为带来源的 note 块并开面板。
- **.board 文件关联**：注册双击打开（`me.siwi.Desire.board` conforms public.json），打开即导入为活跃会话的白板（无活跃会话落默认板）；面板标题点击重命名。
- **DPP × 白板约定（规范 §5.1）**：页面无需新原语——声明的 views 可被 Agent 抽取并渲染到宿主白板（本地双引擎）；页面只能经自由文本 `context.visualization` 提示**建议**（白板属于用户，页面无权写入）；dashboard 演示全流程。
- **全局悬浮球（一期）**：贴浏览器窗口边缘的非激活子面板，窗口内任意拖动、松手 spring 吸附最近边缘并持久化；呼吸动画、hover 放大、点击展开操作条（开 Agent 面板、语音输入带实时转写胶囊自动发送、页面总结、白板）；透明区域点击穿透到下层网页（自绘 hosting-view hitTest）。开关：Agent 面板头部 / 菜单 / `POST /command toggleAgentBall`。
- **悬浮球二期（设置与手势）**：AI 设置新增「悬浮球」开关（全窗口跟随、球回到最近活跃窗口）、右键菜单（重置位置到默认边缘位/隐藏）、拖动倾斜——球随水平拖速侧倾、松手回正。
- **悬浮球二期（感知与交互）**：2s 轮询驱动忙碌进度环与元素全屏（视频）自动隐藏/退出恢复——球的子面板原本会垫在全屏内容窗之后但盖住视频；双击直达语音输入；尺寸选择（小/中/大）进 AI 设置；`/agentball` 报 agentBusy 与 hiddenForFullscreen。
- **悬浮球三期**：回复就绪徽章（面板关闭时 Agent 完成，球上绿勾闪现）、iOS 式点外收起（条外点击收起、条内点击照常传给按钮）、球不再渲染成过大的透明板——视图与面板尺寸严格跟随展开状态。
- 悬浮球重构为浏览器窗口内覆盖层（AgentBallOverlay）：`.glassEffect` 在主窗内可采样网页内容，呈现真实 iOS 26 液态玻璃（独立透明 NSPanel 采样不到跨进程背景，玻璃退化实心灰——两轮实拍定案）；窗口内 SwiftUI 手势完整：拖动任意位置（命名坐标空间修半速）、松手 spring 吸附最近左右缘并持久化、单击开合操作条、双击语音、右键菜单（重置位置/隐藏）；Agent 忙碌进度环 + 回复完成徽章 + 语音实时转写条
- **聊天内嵌白板卡（2026-10-04 用户定案）**：whiteboard 工具**不再自动弹面板**——每条 whiteboard 工具消息在聊天里直接渲染实时板（与面板同一双引擎管线：Mermaid/ECharts/表格/便签），卡上「打开白板」管编辑导出。深化：**只有最新一张卡默认展开**实时预览、旧卡折叠成一行按需展开（每张卡各挂一个 WebKit 视图且都显示同一块当前板）；预览高度按内容自适应（webview 上报、上限 520pt），替代固定 300pt 裁切 320px 图表块的旧框。
- **白板：Agent 读板闭环 + image 块**：`whiteboard` 工具新增 `get` 动作（逐块清单回读给模型，超长内容截断、image 只报大小）——"读板→改图"的迭代不再盲写；render/append 的返回附带单行块摘要（模型不调 get 也知道板上有什么）；新 `image` 块类型（`data:image/` URI，截图上板图文混排；拒远程 URL 防外链依赖，单图上限 ~8MB）；note 便签支持 `[链接](url)`，点击经 whiteboardLink 消息在浏览器新标签打开——白板 webview 自身在 loadHTMLString 落地后一切导航被护栏取消、window.open 返回 nil（误点不再把整板打跑）；块解析收口 `WhiteboardBlock.make(from:)`（工具与桥共用，content 接受字符串或 JSON 对象）；append 增设 60 块板容量护栏；桥新增 `POST /whiteboard`（render/append/clear/get 与工具同权，可指定 conversationId）+ `GET /whiteboard` 每块附 200 字符预览。
- **白板：Agent 单块精细编辑**：`whiteboard` 工具新增 `edit`/`delete`/`move` 动作（1-based 块号，与 `get` 回读编号一致；edit 的 content 接受字符串或 JSON 对象）——修改单块不再重发整板（image 块的 data URI 特别吃 token），"读板→改一块"的迭代闭环补完；桥 `POST /whiteboard` 同步支持三个动作。
- **白板离屏成图管线（BoardRenderService）**：`/panel/snapshot?name=whiteboard` 从"块清单卡"升级为**真成图**——隐藏 WKWebView 跑与面板同一份 pageHTML 双引擎，串行渲染整板、全内容高 takeSnapshot（按 spec 内容+宽度哈希缓存，宽度可通过 `?w=` 指定），E2E 首次拿到像素级成图证据（返回新增 `rendered`/`errors` 字段；渲染失败回退块清单卡并带 `fallback: "block-card"` 标记）。
- **白板块拖拽排序**：块工具条新增 ⠿ 手柄（按住才置 draggable，不破坏便签文本选择），drop 目标块即新位置，经 `whiteboardEdit` 通道 `reorder`（index=原位置、delta=目标位置）落到新纯函数 `WhiteboardSpec.reorderingBlock(from:to:)`；拖拽视觉反馈（半透明 + 虚线落点框），增量渲染下其余块节点复用不闪。





### Changed

- 悬浮球定稿 V3「辅佐触盘」（三方向原型评审后拍板，原型 design/agent-ball/prototype-v1.html）：点球弹出 2×2 径向液态玻璃触盘（大圆按钮依次弹入、热区大、盲点得中），球图标切换 ✕，点触盘外任意处收起，录音时触盘内附实时转写条，语音发出后球旁弹"已发送"胶囊；吸收并行润色的克制口径（无呼吸/无旋转环，忙碌=静态强调环，悬停=轻微放大+brightness，触盘悬停填强调色）。修位置竞态：overlay 冷启动挂载时 GeometryReader 尚在布局链（0×0→900×600→真实尺寸），播种的球心在真实窗口下偏到页面中间（玻璃球"隐身"在深色页面）——球心改为永远由持久化 (edge, offsetFraction)+当前窗口尺寸推导、拖动期间才用临时坐标，位置类竞态整类消除
- **白板渲染改增量**：每次 spec 推送不再整板重建——内容未变的块直接复用 DOM 节点（ECharts 实例保留不 dispose 重建、Mermaid SVG/图片不重渲），append 与单块编辑不再整板闪烁；被丢弃节点才释放图表实例。编辑态节点与带错误的节点永不复用（保证同内容重试是真渲染）。
- **白板打磨包**：`.board` 导入在当前板非空时询问「追加/替换」（此前只能追加，想替换得先手动清空）；image 块不再提供"编辑源码"按钮（万字符 base64 进 textarea 没有意义，删除/移动仍可用）；桥 `GET /whiteboard` 支持 `?conversationId=` 指定会话与 `?format=readout`（返回模型 `get` 动作所见文本，断言"模型看到什么"用）。



### Fixed

- **设置页服务编辑器丢模型选择器**：双协议重构删了 `draftModelPicker` 行没加回——原位恢复：下拉 = 服务自带模型清单 + 已拉取模型，保留手动输入兜底。
- **「测试连接」误报超时**：改为镜像真实聊天请求（流式 body + 档案自定义请求头 + 按协议补全端点：OpenAI `/chat/completions` vs Anthropic `/v1/messages`），连通性按服务端首个流式行判定而非等完整非流式生成——非流式路径慢的网关（如 AMD Radeon）不再在聊天正常时谎报 15s 超时。
- **31 个字符串目录键补全翻译**：构建自动抽取产生的未翻译骨架（MCP stdio/HTTP 传输、DPP 徽标、AI 自动拦截 toast、PDF/播放器菜单、成本路由等）补齐 en/zh-Hans/zh-Hant，目录恢复三语全覆盖。
- **白板 PNG 导出可能空白**：cacheDisplay 拍 WKWebView 合成层不可靠——改为 takeSnapshot 按 `document.body.scrollHeight` 取全文档区域（超出视口的部分 WebKit 会照常渲染，长板不再被裁成一屏），失败回退 cacheDisplay。
- **白板面板块工具条"上移/下移/删除"自二期起无效（潜伏 bug）**：按钮闭包调用了 `post(...)`——那是渲染统计函数（发往 whiteboardRender 通道），编辑回传应走 `postEdit`（whiteboardEdit 通道），所以只有"编辑源码"真正生效过。改为 #board 事件委托 + 按钮只带 data-action、块编号读 `.block` 的 dataset.index（增量渲染复用节点后编号以 data 属性为准）。
- **白板面板块工具条从未在 app 里生效（接线缺失）**：`WhiteboardPanelView` 渲染 `WhiteboardWebView` 时一直没传 `onEdit`——工具条的移动/删除/编辑源码回传到 Coordinator 后落在 nil 上（二期 E2E 只在探针层验了 JS 流程，没验 app 接线）。现面板持有 onEdit 并把 move/delete/edit 落到 store.apply；聊天内嵌卡保持只读预览不受影响。
- **聊天内白板卡从未显示过（chip 化吞掉工具消息，用户实测抓到）**：`chipToolIds` 把 assistant 的**全部** toolCalls id 收进去、消息列表对 chip 化的工具消息一律 EmptyView——whiteboard 的结果消息因此永远不渲染，白板卡（内嵌实时板 + 全部深化）只在数据链路层存在过；用户截图里的 "whiteboard 39ms" 行其实是 assistant 气泡里的 ToolCallList chip。修 = chips 生成排除 whiteboard 调用 + ToolCallList 同步过滤（避免 chip 行与卡片双显）。教训：桥/探针 E2E 只能验数据链路，UI 呈现必须真截图目视。
- **聊天内白板卡缺水平边距**：卡片外层 HStack 没有像 AssistantBubble/ToolBubble 一样的 `.padding(.horizontal, 12)`——板预览贴死面板右缘（用户实拍反馈）。






## [v0.5.9] - 2026-10-03
### Added

DPP 实测反馈四项改进（来自产品页 DPP 的真实 Agent 会话复盘）：① `pageAction` 动作完成带导航反馈（click 触发跳转时返回 "→ navigated to …"，此前模型点完不知道页面已换、下一动作在新区报错）；动作找不到时错误信息带当前 URL 并提示 switchTab；② `pageExtract` 文本字段折叠连续空白（HTML 源码换行曾以 `\n` 脏数据进入抽取结果）；③ `getPageSnapshot`/`readTab` 在 DPP 声明页前置提示结构化通道（模型在翻译/总结类任务会跳过 pageProtocol——提示跟到最常用工具上；且 hint 必须前置，工具消息统一 prefix(8000)，尾部追加会被截断剪掉——实测）；④ `findAdCandidates` 候选补 class/id/position/zIndex 字段（此前模型要为"确认选择器"多发 3-4 轮 executeJS）。
DPP 增强（第五批）：① **SPA 路由变化全级重解析**——新增 dpp-route-watch.js（页面世界 documentStart）包装 history.pushState/replaceState 并监听 popstate/hashchange，经 desireProtocolControl 触发 250ms 防抖重解析（此前只有 L3 SDK 的 expose 通知；SPA 重排后 L1 锚点与声明缓存随之刷新）；② **precondition 轮询等待**——前置条件 3s 内轮询（水合中的页面不再秒判失败）；③ **`ignore` 正文文本扣减**——getPageText 的 contentMain 路径与 getPageSnapshot 的正文均剔除噪音子树（clone 剔除 + 块级换行，无声明时保留 innerText 快路径）；④ **pageProtocol 列出事件**（"auto-monitored" 行，模型知道哪些事件在自动监视）；⑤ **getNetworkLog 原生化**——改读 DevToolsStore（BrowserToolSurface 新增 devToolsStore），页面世界 network-tools 只剩 WaitForNetworkIdle。
**DPP 协议设计层升级（v1.1）**：① 规范新增 §4.0 版本与演进（major/minor 语义、消费者忽略未知字段、新能力"存在即启用"、容错解码为第一原则）+ P7 容错演进 / P8 求值隔离两条设计原则 + §4.7 站点级声明完整行为表（拉取条件/同源传输/缓存/合并/页面地图/安全边界）；② **profile 运行时化**——解析并透传给 Agent（pageProtocol 工具 / page_context / `/protocol/inspect`），站点级 `pages` 页面地图按路径回退补全（精确或 `前缀*`，长前缀优先），§5 各 profile 补**必选原语契约表**；③ **自检工具闭环**——`docs/dpp-schema.json`（JSON Schema 2020-12）+ `tools/dpp-validate.py`（零依赖命令行校验，schema 规则之上提前预警运行时陷阱：未知 run 操作、空选择器、outbound 未标 danger、events `on` 被忽略等）；SDK `desire.validate()` 增加 profile 契约检查；默认提示词补 profile 语义指引。E2E：/im 自声明 chat + well-known 页面地图 forms 双路径断言（upload 套件 9 项）。
DPP 第六批增强：① **类型化字段**（§4.3）——views 的字段支持对象形态 `{"selector": ".price", "attr": "href", "type": "price"}`，抽取时强转：`number/price`（price 剔除货币符号与千分位：`¥1,299.90` → 1299.9）、`url`（相对转绝对）、`date`（ISO 8601）、`bool`（存在即真）；转换失败回退原始字符串（宁可不转不可丢数据）；E2E 实测 `"price":1299.9` 数字落盘；② **事件回合带协议摘要**——事件触发时把页面声明的 `views [thread]; actions [send-message]` 附进 prompt，模型不必先探索就知道用 pageExtract/pageAction 响应；③ **动作参数类型校验**（声明 number/boolean 的参数命中即失败，模型自查）；④ 规范清理：chat 示例的 `waits` 占位换成 `waitFor` 步骤；Schema/校验器同步类型化字段（未知 type 预警）。
DPP 生态与可见性（建议落地批）：① **schema.org potentialAction 消费**（L0 扩展）——JSON-LD 里的 potentialAction（SearchAction/ViewAction 等）自动映射为 DPP 动作：@type 去 Action 后缀即动作名、URL target（含 {占位符}）映射为 navigate 步骤 + params；与 llms.txt 互补（llms.txt 管内容发现、DPP 管能力发现）；② pageAction DSL 新增 **navigate 操作**（URL 模板填充 + 主框架等待 ≤8s）；③ **事件同意模型**——默认档改为 off（事件自动唤起智能体消耗 token，不应在用户不知情时发生），首次遭遇被抑制事件时 toast 提示一次（"通知权限"式同意），规范 §4.5 同步 consent 语义；④ **DPP 徽标**——当前页声明协议时工具栏显示 DPP 标记（自观察 BrowserState 的独立子视图，不影响工具栏重绘链）；⑤ **在线演示页** website/demo/（L2 声明 + 类型化字段 + 事件按钮 + ignore 展示，dpp-validate 零警告），产品页/llms.txt 挂链接。
DPP 第七批增强（四项收官）：① **MCP 联动**——动作 run 支持 `{"mcp": {"server": …, "tool": …, "args": …}}` 步骤（桥接名与 MCPStore.bridgedToolName 同式）；含 mcp 步骤的动作强制升级 dangerous 逐次审批（页面经 DPP 请求**宿主侧能力**，不得静默执行）；② **views.empty 空态信号**——0 条目且空态选择器命中时明确告知"合法空列表"（区分于抽取失败，模型不必盲目重试）；③ **L1 扫描进 shadow DOM**——解析器递归收集 open shadowRoot，跨边界元素生成 `>>>` 路径（__desireQueryAll 求值）；④ **well-known auth 登录指引**——`auth` 自由键值解析透出（pageProtocol），Agent 遇登录墙据此引导用户（不自动填凭据）；Schema/校验器同步。






### Fixed

DPP 解析器：`content.ignore`（规范 §4.1 规定位于 content 对象内）此前被静默丢弃——normalize 只读顶层 `ignore` 键。产品页接入 DPP 的自检（用真实解析器解析 website/index.html）抓到；现优先读顶层、回退 content 内。
DPP 审批卡展示 run 步骤原文（此前只有页面写的 description——声明与实际动作的一致性无法核验）；DPP context 注入 prompt 时改用**显式不可信引用框**（UNTRUSTED 标注 + BEGIN/END 包裹——context 的设计目的就是进入 prompt，也是最直接的注入面，弱模型可能把页面写的"规则"当指令执行）。



## [v0.5.8] - 2026-10-03
### Added

DPP pageAction 审批时空一致性：闸门记录审批时的页面 host，执行时复核——审批之后页面已导航（同名动作会换页执行）则拒绝并要求重新审批。事件策略纯逻辑抽为 PageEventPolicy 进单测（限频滑窗/提示词/三档校验，290 项全过）；L1 解析前清理上次解析残留的锚点属性（SPA 同文档重解析的选择器复用风险）+ 静默跳过的容器记入 warnings。
**Agent 工具求值全面迁入隔离 content world（desireAgentTools）**：dom-tools.js 向页面世界与隔离世界双份注入，`callAsync`/`eval` 帮手默认隔离世界——页面覆盖页面世界的同名函数或猴补 DOM 原型不再影响 Agent 的查询与动作目标（DPP 部分上一轮已迁，本轮扩到全部工具）。留页面世界的例外：协议解析器（读页面全局）、executeJS（语义即页面上下文）、getNetworkLog/waitForNetworkIdle（依赖页面世界网络钩子）。
DPP `ignore` 噪音区接线（spec §4.1/L1 的 data-dpp-ignore，此前仅展示）：pageExtract 跳过落在噪音子树内的条目、getPageSnapshot/readTab 的交互元素清单不列噪音子树内元素（正文文本不扣减——innerText 无子树扣除语义，正文噪音走 content.main）；infinite 分页优先滚动条目的可滚动祖先容器（容器内滚动的站点此前静默收不到新条目）；`callAsync` 异常带出真实 JS 异常文本（此前只有无信息量的通用文案）。



### Fixed

DPP 第二轮审计修复（五项）：① **跨窗 navigate 链路断裂**——window 参数跨窗时 CF 挑战检测/标题/首段/DPP ready 等待全部读的还是旧窗口的 webview（load 落在目标窗、轮询看旧窗），统一改用实际承载导航的 webview；② **UploadIntent 陈旧 arm 劫持**——DPP upload 选择器没触发文件选择器时 intent 残留，用户之后手动点任何文件输入都会被自动提交那个文件；现在 3s 未消费即摘除并明确报错；③ **站点级 events 半接线**——well-known 的 events 此前只进展示/命中检查，页内 observer 不装（站点级 monitor 事件永远不会触发回合）；解析器现接受宿主注入的 extraEvents 与页面级一起装 observer（页面级同名键优先），首次 fetch 到站点级声明后自动带 extras 重解析；④ **事件节流吞跳变**——JS 侧 500ms 全局节流窗口内第二个跳变的 state 已更新但消息不发，该事件在恢复 0 之前永久丢失；去掉 JS 节流（宿主 3s 防抖 + 60s 滑窗限频本来就是风暴防线），跳变即发；⑤ **signals.error** 此前声明无消费——pageAction 步骤执行完但页面亮着错误信号时判失败。
DPP 工具求值面加固（第二轮审计 P2-1）：此前 DPP 查询/动作 JS 与页面同世界，页面覆盖 `window.__desireQueryAll` 即可劫持 Agent 的查询结果与动作目标（探针实证）。现在 DPP 全部选择器求值（views/字段、pageAction 步骤、precondition、signals、事件命中检测）运行在隔离 content world `desireDPPTools`——页面无法覆盖函数或猴补 DOM 原型，click/fill/scroll 语义不变（跨世界实证）；协议解析器与 executeJS 按语义留在页面世界。
**callAsync 位置传参错位（波及全部 dom-tools 函数，多年潜伏）**：`callAsync` 把参数键按字母序作位置实参传给注入函数——形参顺序 ≠ 字母序的函数全部错位（`__desireClick`/`__desireElementRect` 的 ref/text 形态靠 `__desireResolveEl` 的分支兜底掩盖，`__desireSnapshot` 加 ignoreSels 参数后炸出）。改为**按键对象传参**（`fn({a: a, b: b})`），dom-tools 宿主直调函数一律解构形参（内部互调的位置签名不受影响）。
第三轮审计：`__desireFillProfile` 解构回归修复——该函数唯一调用方是 FormAutofillStore 的**页面世界位置调用** `__desireFillProfile(p)`，上一轮解构签名迁移只核了 callAsync 调用点、漏了 JS 字符串直调，自动填写会被静默破坏（第三轮静态一致性审计抓到）；恢复位置签名并加"⚠️ 不要解构"标注（含 grep 全部调用方的迁移前置要求）。snap_e2e 回归套件扩展到 10 项：补 getTables/getImages/getPageLinks/getComments/fill 五个迁移后无独立覆盖的工具抽查。
第三轮审计指导落地（单源化/守卫/页面世界减负）：① **选择器穿透辅助单源化**——`DPPQuery.helperJS`（Swift 字符串）与 dom-tools.js 尾部段的双份拷贝收敛为后者单一来源，删除 DPPQuery.swift 与全部 14 处调用点前置（dom-tools 在 agentToolWorld documentStart 常驻，前置本是冗余）；② **callAsync 键名守卫**——非 JS 标识符的参数键直接报错（此前会静默生成坏 JS）；③ **页面世界减负**——dom-tools.js 只注入隔离世界，页面世界仅保留新拆出的 network-tools.js（__desireGetNetworkLog/__desireWaitForNetworkIdle，依赖页面世界网络钩子），autofill/批注恢复/高亮应用三个宿主调用点随之迁入隔离世界（executeJS 用户代码因此不再能引用 __desire* 实现细节）。
DPP pageExtract 诊断与路径统一：单页分支与分页路径共用 collectPage（此前内联分叉——失败被 try? 吞掉无诊断、行为漂移），抽取失败现在带日志（空 raw/坏 JSON/异常分类可见）；修复单源化过程中误删抽取 JS 的 `return` 导致抽取恒空（回归由线上 SDK E2E 抓到）。







## [v0.5.7] - 2026-10-03
### Removed

删除 DPP `installEventPolling` 死代码（Timer 轮询无任何调用点，CHANGELOG/文档曾误述为实装机制；事件监听实际由页面内 MutationObserver 跳变上报 + 每回合命中检测承担）。

### Fixed

DPP 审计三修复（P0）：① **审批闸门接线**——`pageAction` 在动作声明 `effects: "outbound"` 或 `danger: true` 时强制升级 dangerous 审批（此前按工具名分类 sideEffect，白名单/自动编辑档下任意站点的发消息/下单类动作零提示执行）；审批卡显示 host·动作·描述·effects。② **解析容错**——单字段结构不符只丢该字段并记 warnings（此前规范原文的 events 对象形态 `{watch,…}` 与 context 数组会让整份协议静默丢弃）；JS 归一化把对象形态 events 展平为 watch 选择器；`actions.run` 非字符串时字符串化兜底；warnings 经日志与 `/protocol/inspect` 透出。③ **L1/L0 选择器**——L1 条目集合打同一 `data-dpp-items` 标记（此前只锚第一个条目的 `:scope` 相对路径，document 级求值命中 `<html>`，抽取返回空数据假成功）；容器自身即条目时用锚点（此前 `*` 扫全文档）；ignore 多 class 正则修复（`/\\s+/` 字面反斜杠）；ignore-only 页面不再整体失效；pageExtract 支持逗号回退选择器与 `@text` 语义（L0 JSON-LD 字段此前恒空）。
DPP 工具与事件链路修复：`pageAction` 步骤异常不再吞掉报假成功（步骤失败返回 `Error: ` 前缀与已完成步骤清单，符合失败统一约定），补 required 参数校验、`precondition` 前置检查、`waitFor`/`hover`/`pressKey` 步骤，`upload` 明确报不支持；`pageExtract` 分页合并改结构化数组去重（空页不再拼出 `[,]` 非法 JSON），截断改按条目数（500）不再把 JSON 从中间切断；`PageEventHub` 频率上限改 60s 滑动窗口（此前进程生命周期累计 10 次后该站点事件永久静默）；页面事件 observer 改"匹配数 0→正"跳变语义 + 500ms 节流（此前匹配存在期间每次 DOM 变动都发消息）；导航开始即清 DPP 协议缓存（修复跨页执行上一页动作声明的竞态窗口）；`PageEventHub` 模式持久化对齐（初始化读回 `dpp.eventModes`，删除无人写入的 `dpp.eventMode.<host>` 死路径）。
非 DPP 页面不再每次导航刷一行 "DPP decode error"（解析器对无协议页返回字面 `null`，此前走了错误日志路径）。
DPP 布尔检查集体失效的潜伏缺陷（真机 E2E 抓到）：`callAsyncJavaScript` 把脚本体包进 `async function`——**没有 `return` 恒返回 nil**，而 fill/click 是副作用型步骤看不出异常。DPP 的 precondition/ready 信号/busy 信号/success 信号/waitFor 全部中招（如 precondition 永远"未满足"、success 永远"未检测到"）；全部补 `return`。
DPP danger 动作在"自动编辑"访问等级下零审批放行（真机 E2E 抓到，P0-1 修复的缺口）：审批闸门的 autoEdit 分支只例外 runCommand/fillLogin、不看风险档——`.dangerous` 升级挡不住它。现在 DPP 动作被站点声明为 `effects: "outbound"`/`danger: true` 时同样例外，必须逐次审批。另修 `pageAction`/`pageExtract` 跑在挂起标签页的冻结 DOM 上（协议缓存属 BrowserState、DOM 属活 webview——现在统一用选中标签的 webview 执行，挂起时明确报"suspended — switchTab"而非莫名其妙的"元素不存在"）。





### Added

- **DPP 协议增强**：`pageAction` 工具（声明式动作执行：fill/click/waitForText/select 步骤 DSL + 模板变量 + success 信号检测）；事件驱动（Timer 轮询 + PageEventHub + per-site 三档模式 off/draft/auto + 事件风暴防护）；navigate 返回值增强（页面标题 + 首段文本 + DPP 视图提示）；ad-candidates.js 选择器 id/class 优先修复（nth-child 死选择器问题）。
- **AI Auto-Clean 拦截结果 toast**：自动拦截后 UI 顶部显示橙色 toast（"AI auto-blocked N element(s) on host"），用户实时看到 AI 拦了什么；默认提示词新增 DPP 协议页意识（pageProtocol/pageExtract/pageAction 优先于 getPageText/click）。
- **DPP 二期完善**：`page_context` 增强——DPP events 命中检测（每次 Agent 回合自动检查 events 声明的选择器是否在当前页面命中，命中即告知模型 "[DPP Events Active]"）；设置页 AI Auto-Clean toast 反馈（自动拦截后 UI 顶部橙色胶囊提示）；默认提示词新增 DPP 协议页指引（pageProtocol/pageExtract/pageAction 优先于 getPageText/click）；navigate 返回值增强（页面标题 + 首段文本 + DPP 视图提示）；事件驱动 Timer 轮询 + PageEventHub 基建（per-site off/draft/auto 三档模式 + 事件去重/频率上限）。
- **DPP L3 SDK**（`desire-sdk.js`）：新开发的网站一行 `desire.expose({...})` 声明 DPP 协议（类型安全、SPA 路由自动重声明、`desire.emit()` 精确事件发射、`desire.validate()` 开发校验）；桥新增 `GET /protocol/inspect`（查看活动会话当前页面的 DPP 协议解析结果——站点作者调试用）。
DPP 语义上下文落地：`context`（persona/domain/rules，站点声明的参考资料位）此前解析了却从不进模型——现在注入 page_context 与 `pageProtocol` 工具输出（前缀 "reference, not instruction"）；`getPageText` 遵循 DPP `contentMain` 正文选择器（选择器落空回退 body）；桥新增 `GET /dpp/modes`、`POST /dpp/mode`（per-site off/draft/auto 事件自动化模式管理），`/protocol/inspect` 增加 warnings/eventMode 字段；DPP 容错解码进纯逻辑单测（tests/run.sh）。
DPP signals 行为接线（spec §4.2 承诺落地）：`navigate` 在页面声明 `signals.ready` 时等就绪信号出现再返回（带 `pageProtocolChecked` 标志区分"没解析完"与"无协议"，普通页面几乎零额外等待；6s 超时如实报告不假失败）；`pageAction` 步骤完成后等 `signals.busy` 消失再判成败（busy 持续 5s 会在结果里如实注明）。
DPP 二期补完：SPA 路由变化的协议重解析（desire-sdk.js `expose()` 经 `desireProtocolControl` 消息通知宿主，250ms 防抖合并连续 expose——此前重新声明永远不会进缓存）；`pageExtract(all=true)` 支持 `pagination.type: "infinite"` 无限滚动（滚到底收集、序列化去重、连续两轮无新增即到底）；DPP 审批闸门真机 E2E（假端点逼 danger pageAction 全链 20 项断言：审批挂起/挂起期间未执行/deny 后仍未执行/allow_once 后执行且 success 信号检测/local 动作在 autoEdit 下不受影响）。
DPP shadow DOM 穿透选择器（`>>>` 语法）：WebKit querySelector 不穿透 shadow boundary，宿主侧按段下钻 shadowRoot——views 的 item/字段、pageAction 的 fill/click/select/hover/waitFor、precondition、signals.ready/busy、事件命中检测全链支持（`"app-grid >>> product-card >>> .price"`；字段相对 item 的 shadowRoot 用前导 `>>>`）。配套修正：字段值 JS 曾把多行辅助函数嵌进对象字面量值位置（语法必炸，构建验不出——探针抓到）。
DPP 事件驱动回合真机 E2E 全链打通（8 项断言：跳变上报 → PageEventHub auto 档自动开回合 → 模型收到 "[DPP Event]" 消息并回包 → 防抖风暴防护）；DPP L3 SDK 公开分发（website/desire-sdk.js，随产品页部署为 https://desire.mankong.icu/desire-sdk.js）。
DPP 站点级声明（spec §2 顶层落地）：页面声明协议时宿主经**页面内同源 fetch** 拉取 `/.well-known/desire.json`（URLSession 会吃系统代理——用户机器上连 127.0.0.1 都不通，实测踩过；页内 fetch 继承 WebKit 网络路径无此问题），host 级 10 分钟缓存；合并语义 = 字典类（views/signals/events/context）逐键、页面级覆盖站点级，actions 按名去重（页面在前）、ignore 并集（进纯逻辑单测）；12 处消费点切到合并视图 `effectiveProtocol`，/protocol/inspect 增加 siteLevel 标记，pageProtocol 工具注明站点级来源。
DPP upload 步骤落地（复用既有 UploadIntent 原语：arm 文件 + 点击选择器 → openPanel 钩子自动提交面板，真机 E2E 验证文件真实交付给页面）；同源 iframe 穿透：选择器自动搜索同源 iframe 文档（collectDocs 递归、跨源跳过），`>>>` 中段遇到 iframe 时下钻其 contentDocument。












## [v0.5.6] - 2026-10-03
### Added

- **Desire Page Protocol (DPP) 一期**——页面内容 → Agent 的声明式映射协议（四层梯度接入）：L0 零改造（消费既有 JSON-LD schema.org 数据）、L1 属性微标注（现有 HTML 加 `data-dpp-view/field/ignore` 属性）、L2 声明块（`<script type="application/x-desire+json">` 集中 JSON）、L3 原生 SDK（`window.__desireProtocolExposed`）；归一化解析器 `desire-protocol.js` 每次导航后自动解析并缓存；`pageProtocol` 工具查看协议、`pageExtract(view)` 工具按声明抽取结构化数据（准确字段、省 token）；page_context 自动注入 DPP 摘要（视图清单+动作）让模型免猜页面结构。
- Agent click 工具增强：**点击后 URL 变化检测**——点击等待 600ms 后对比前后 URL，变化时返回 "→ navigated to …"（模型据此区分"点了链接"还是"按了按钮"，不再需要盲目调 getPageText/readTab 判断点击效果）。
- **DPP pageAction 工具落地**——声明的 DPP action 可通过 `pageAction(name, args)` 执行：run 步骤 DSL（fill/click/waitForText/select）由 Desire 填充模板变量后逐步执行，success 信号自动检测；`effects: outbound`/`danger` 的 action 走既有审批闸门。DPP 三件（pageProtocol/pageExtract/pageAction）全链 E2E PASS。
- **DPP 事件驱动**（二期）：页面按 DPP events 声明安装 Timer 轮询（3s 周期检查事件选择器命中），命中即经 `PageEventHub` 触发 Agent 事件驱动回合（prompt 带 `[DPP Event]` 前缀 + 事件详情）；per-site 三档模式（off/draft/auto）控制事件是否触发回合及 outbound 权限；事件风暴防护（debounce + 频率上限 + 去重）。





## [v0.5.5] - 2026-10-02
### Fixed

- **下载面板卡顿（用户实测）**：每行渲染在主线程同步 `fileExists` 检测文件是否被删——外置卷/休眠卷一次 stat 可达几十 ms～秒级，几十行一渲染面板就卡死。改为 `DownloadStore.missingFiles` 后台批量扫描缓存（utility 优先级、可取消防抖），渲染只读缓存零 IO；扫描触发 = 面板打开（`.task`）+ 下载完成 + **系统卷挂载/卸载通知**（拔盘瞬间自动刷新）。桥 `/downloads` 行带 `fileMissing` 字段（E2E/诊断同源），新增 `/downloads/remove`。

### Added

- **MCP 客户端 stdio transport**（完整 MCP 补强）：本地 MCP 服务器以子进程方式接入（`MCPServer.transport=stdio` + command argv + 可选 env），JSON-RPC 走 stdin/stdout 换行分隔行协议；裸命令名按 PATH 解析（python3/npx 不必写绝对路径）；进程退出/超时的挂起请求唤醒与诊断尾随（stderr tail 带回失败原因）；工具经同一桥接（`mcp_<server>_<tool>`）进 agent 工具面，与 HTTP 服务器共用 callTool 分派；卸载/停用联动 terminate。设置页新增表单（HTTP/Stdio 分段）；桥 `/mcp/add` 支持 command、新增 `/mcp/remove`。E2E：本地 stdio fixture 全链 PASS——spawn→initialize→tools/list（echo 进工具面）→ 模型 tool_calls → 经子进程 tools/call（参数正确送达）→ 结果回进对话 → 第二轮完成。
- **Skill 多文件支持**（盘点补强 2）：skills 目录同时识别单文件 `*.md` 与**目录 skill**（`<name>/SKILL.md` + 附属 scripts/references，目录名即技能名、目录优先于同名散文件）；useSkill 加载时列出**附属文件清单**（绝对路径 + 相对路径），模型用既有 readFile 按需读取——"带脚本/参考资料的技能"从此可安装。
- **MCP 客户端 prompts/resources 消费**（完整 MCP 补强续）：连接握手后尽力拉取各服务器的 `prompts/list` 与 `resources/list`（不支持 = 空表，不影响连接）；新增四个 agent 工具 `mcpPrompts`/`mcpGetPrompt`/`mcpResources`/`mcpReadResource`（HTTP 与 stdio 双传输都走同一条分派），模型可自主列取外部服务器的提示模板与资源内容。
- **Skill 导入管线**（多文件配套）：`SkillStore.importArchive` 统一入口——zip 归档（ditto 解包，根/唯一子目录的 SKILL.md 识别）、技能目录直装、散装 .md 拷贝三形态；技能名 = frontmatter name 优先（无则目录/文件名），同名导入 = 覆盖更新；桥 `/skills/import` 新增 `path` 参数（本地路径导入，与既有远程 url 导入并存）。
- **AI 广告拦截增强：Auto-Clean 自动拦截**（用户实测 findAdCandidates+blockElements 效果好之后的顺延）——新增全局开关（设置页 + agent 工具 `toggleAutoAdClean`）：页面加载完成自动扫描广告候选，**高置信度候选（≥2 条独立理由：class/id 词、slot 尺寸、overlay 浮层、跨域 iframe 等的组合）自动走 blockElements 通道**按 host 拦截（持久 + 即时隐藏）；单理由不自动拦（误杀率考量）；用户 `unblockElement` 某站点即加入自动豁免名单（防"用户拆、AI 又拦回去"的拉锯）。顺带修复 ad-candidates.js 的选择器生成：**id/class 优先**（唯一性校验），nth-child 路径仅作 fallback——此前 nth-child 对 body 位置计算脆弱，自动模式注入过永不匹配的死选择器。
- 广告拦截规则**来源标记**：BlockedElementRule 加 `source` 字段（ai-auto / agent，旧数据 nil 按 agent 处理）——Auto-Clean 与 agent 手动拦截同库共存后可区分来源；`listBlockedElements` 输出带 `[source]`；`unblockElement` 拆 **ai-auto** 规则才触发 host 豁免（agent/手动规则是显式意图，不触发），消除"拆手动规则误豁免自动清理"的语义漏洞。







## [v0.5.4] - 2026-10-02
### Added

- Agent 个性化增强：**输出规则（Output Rules）**——设置页逐条增删的长期个人偏好（如"始终用中文回答""先给结论再给细节"），独立成 `<output_rules>` 提示词层（identity 之后，声明优先于学到的记忆），主会话与子代理都遵守——比手改整段系统提示词门槛低一个数量级；**点踩原因沉淀**——回答点踩时弹可选原因输入，填写后存为 feedback 记忆（尊重记忆学习开关），用户负反馈首次进入记忆闭环。
- Agent 个性化三件（建议清单 1/2/3 落地）：**记忆来源可见**——每条学到的记忆带来源会话标题（记忆面板显示"学自：…"，可追溯可删除）；**会话级临时指令**——输入栏 sparkles 按钮设置"本次对话用英文"这类覆盖，`<session_directive>` 层注入（仅本会话生效、明确不进长期记忆）、随会话文件落盘切会话跟随、桥 `POST /agent/directive` 可程序化设置；**站点 scope 激活**——广告结构记忆按站点 host 存 scope（promptBlock 只在命中站点时注入，不再全站占上下文），记忆面板显示"仅限：host"。
- Agent 个性化再增两项（建议清单 4/5）：**智能体人设**——名字 + 语气描述（设置页 Persona 段），进 `<persona>` 提示词层（最前），主会话与子代理同一名片；**自定义快捷模板**——聊天快捷按钮行的用户自定义按钮（标题 + 整条 prompt），设置页增删编辑，点击整条发送不进输入历史。三者（含输出规则）随 agent_prefs 端到端加密同步（payload 向后兼容：旧设备解码新字段为 nil）。
- Agent 个性化 6：**BM25 记忆检索**——L1 事实不再全量注入（200 条上限会爆上下文且稀释注意力），按当前对话的词法相关性打分选最相关条目（pinned 恒定注入 + BM25 top-12；查询 = 最近 3 条 user 消息；中英混合分词 = 英文词元 + 中文 bigram；来源会话标题轻量加成；零重叠退化为最近优先兜底）。纯函数进单测（250 项），E2E 实证：50 条候选里精准选中唯一相关条目、31 条杂项全部筛除。
- Agent 个性化 7：**评估集回归闭环**——`scripts/export-thumbsup-eval.py` 扫描全部会话轨迹导出 👍 回合（goal/answer/标题；凭据模式 sk-/Bearer/AKIA/password= 掩码，--redact-hosts 可泛化 URL host；**默认输出到 agent 工作区仓库外**——含真实会话内容勿提交）；`tests/agent-eval.py --fixtures <path>` 新增 E5 用例：真实语料逐条回放假端点回合，断言系统提示契约（system 唯一第 0 位）在个性化改动后仍成立。全量评估 18/18 通过。





### Fixed

- **设为默认浏览器后点链接页面不打开（用户实测）**：macOS 发给默认浏览器的打开链接事件（kAEGetURL/'GURL'）从未被接收——AppDelegate 没有任何 URL 事件处理，URL 被静默丢弃。现注册 GURL Apple event handler（willFinishLaunching 阶段）+ kAEOpenURLs 兜底：外部链接在活动窗口**新标签**打开（不顶掉当前页），冷启动早于窗口就绪的事件进缓冲多跳重试 flush；同步修复两处连带：Dock 点击/`open -a` 纯激活会让 SwiftUI 对 value-based WindowGroup 再开一扇新主窗（applicationShouldHandleReopen 有可见窗口时返回 false）、openURLs 事件 SwiftUI 层默认开新窗（Info.plist 声明 CFBundleURLTypes http/https 后 GURL 单路消费，不再双开）。
- **应用内自更新"无法下载/不会安装"**：下载用逐字节 `for try await byte` 喂 SHA256——几十 MB 包是千万次 async 迭代，慢到像卡死；改为 `URLSession.download` 落盘 + 1MB 分块读文件算哈希。SHASUMS 匹配用 URL 尾段（镜像/改名场景静默 noChecksum）→ 改用资产名。全链路补日志（assets 下载/校验/替换/重启每步，替换为 fault 级），失败首次可诊断。
- 会话级指令设置后立即丢失：新会话（/agent/new 后 conversationId 为 nil）时设置无处落盘，send 建会话时 saveCurrentConversation 的反向同步把指令打回 nil——无会话时先落会话对象、并移除该反向同步（唯一入口 setSessionDirective，恢复靠 loadConversation）。




## [v0.5.3] - 2026-10-02
### Changed

- 本地文件链接的打开方式重构：action 阶段按扩展名分类当场处理——归档/安装类（zip/dmg/exe 等）直接进下载面板（不再依赖"导航→转下载→失败静默"的补丁链），PDF 走内建查看器，音视频/图片交给 WebKit 渲染；无扩展名的文件仍由响应 mime 兜底转下载

### Added

- 下载面板如实反映本地文件状态：完成行对应的文件被用户从磁盘删除后，显示"File deleted"徽章并将 Open/Show in Finder 替换为"Download Again"（按来源 URL 重新发起）；Show in Finder 在文件已删时退化为打开所在文件夹
- 主框架导航落到已知文件类型（zip/dmg/pdf/mp4 等）时在 action 阶段预判下载——配合下载转换失败静默，页面平滑留在原处不再闪错误页（衔接修复的另一半）
- 插件 API 面扩充：alarms（create/clear/clearAll/get/getAll/onAlarm，宿主 Timer 调度、周期性 alarm 自动重排）、windows.getAll（窗口+标签快照）、downloads.download/search（映射 DownloadStore）、action.setBadgeText/setTitle（占位存储）、tabs.update/get（激活/置顶/URL 加载）——content script 与 background 侧 handler 同步接入
- 插件 API 面继续扩充：chrome.scripting.executeScript（MV3 动态注入到 extension world）、chrome.cookies（getAll/get/set 映射 webview 数据仓库）、chrome.i18n（getMessage fallback 语义 + getUILanguage）、chrome.alarms（插件级定时器：宿主 Timer 调度、周期性重排、插件停用自动清理）、chrome.windows.getAll、chrome.downloads.download/search、chrome.action（badge/title 占位）——content/background/popup 三处 handler 同步接入
- chrome.alarms 持久化：插件 alarms 表落 DiskStore，app 重启后恢复重排 Timer（过期的自动清掉）——周期性 alarm 不再因重启丢失
- 插件系统：Port 长连接全链落地——`runtime.connect`/`onConnect`（端口表按双端 webview 路由，任一端 postMessage/disconnect 对称送达，插件停用自动拆端口）；`runtime.sendMessage`/`tabs.sendMessage` 回包路由补全（`_resolveReply` + JS 生成路由 id，`tabs.sendMessage` ns 对齐宿主 case）；桥 `/plugins/add` 新增 `background` 参数（后台脚本插件可直接经桥安装，E2E 用）。
- 插件系统：chrome.scripting 动态注入补全——新增 `scripting` 命名空间（executeScript/insertCSS，支持 code|files[]），**插件包资源目录**（manifest 包装载时整包拷入 `~/Library/Application Support/Desire/PluginResources/<uuid>/`，50MB 上限、路径清洗防逃逸、卸载联动清理），手写 JSON 插件 files[] 明确报错；MV3 动态注入落 per-plugin world 并幂等前置 webext-api 运行时（旧 webview 的 world 也有 chrome.\*）。
- 插件系统：tabs API 补全（update/get/reload，页面/背景 handler 共用一套宿主侧 helper）+ tabs.onUpdated 广播（didFinish 近似 status=complete + url/title，页面世界与全部 background 页双路派发，Chrome 多参签名）；桥新增 `POST /plugins/bg-eval`（在插件 background webview 里求值，背景页此前没有调试通道）。
- 插件系统：**declarativeNetRequest 动态规则落地**（拦截类扩展的标准入口）——`chrome.declarativeNetRequest.updateDynamicRules/updateSessionRules/getDynamicRules/getSessionRules`；规则经 `DNRConverter` 纯转换映射到 WebKit content blocker（urlFilter 语法 `||`/`^`/`*` 逐字转正则、resource-type/initiatorDomains/domainType/redirect/upgradeScheme），映射不了的语义（modifyHeaders/requestDomains/extensionPath 重定向）**逐条丢弃带理由**不整包失败；编译失败二分自愈（FilterListStore.sanitize 同款）；每插件一份规则列表随 webview 创建挂载、更新即时重分发；dynamic/静态落盘跨重启恢复，session 仅内存（Chrome 语义）；manifest `declarative_net_request.rule_resources` 静态规则随包装载，DNR-only 包（popup+规则表、无 content script）合法。
- 插件系统：`chrome.webRequest.onBeforeRequest`（MV3 观察语义，无阻塞回调）——网络请求 start 派发给注册监听的插件 background 页；事件派发按**监听登记过滤**（events/addListener 记账），高频事件不再无差别广播全部插件。
- 插件系统全面审查补齐（2026-10-02）：**宿主 RPC 收口**——背景/popup 两个 handler 共用同一份 `dispatchHostRPC` 实现（此前 popup 只有 5 个 case，扩展主 UI 调 tabs/runtime/i18n 全挂；cookies 背景缺失）；**i18n 真实现**——`_locales/<locale>/messages.json` 从插件包资源目录装载（locale 选择：UI 语言精确→前缀→en→首个；getMessage 同步查表经注入 prologue 内联），manifest `__MSG_key__` 占位随装载替换（此前真实扩展装出来就是字面 "__MSG_extName__"）；**storage.onChanged**（changes 带 oldValue/newValue，三处写路径统一广播）；**Port 语义补全**（onDisconnect 两端触发、对端无监听时 connect 端立即收 disconnect、tabs.connect 背景发起长连接到内容脚本）；scripting.removeCSS（insertCSS 的配对移除）；notifications.clear；cookies.remove + cookies.set 的 url-only 形式（domain 从 url 推导，Chrome 语义）；tabs.create {active:false} 不切走；eventAPI hasListener/hasListeners；webRequest.onCompleted。
- 插件系统：`chrome.action.setBadgeText/getBadgeText` 真实现——角标渲染在工具栏固定图标右下角（红底白字胶囊，最多 4 字符，会话态不持久化，Chrome 语义）。











### Fixed

- 主框架导航转下载时页面误报"无法加载/帧框加载已中断"（用户实测：GitHub release 点下载，文件已下完但页面直接变错误页）——下载转换引发的 frame-load-interrupted 失败不再写入页面错误，页面停留原地，下载静默完成
- 下载面板搜索行与头部补间距
- 插件消息传递（runtime.sendMessage/onMessage、tabs.sendMessage/onMessage）全链打通：background 页 → 页面 onMessage 的派发与回复回投经 .page 世界注入（background 页 chrome.* 与宿主 handler 同处 page world——此前 extension world 注入导致消息静默丢失）；每插件独立 WKContentWorld（插件间身份/全局不再互相覆盖，修复多插件同页 __desireExtID 被最后一个覆盖的问题）
- execute 桥新增 world 参数（main/extension/plugin:<uuid>）——调试插件 content script 必需（主世界探针看不到插件隔离世界的状态）
- 插件 RPC reply 闭包对**标量顶层负载**（String/数字/布尔）手动字符串化——NSJSONSerialization 默认拒绝标量顶层，抛 ObjC 异常且 try? 拦不住，整进程 FAULT（AI 拦截广告实测：scripting.executeScript 返回页面标题 String 即触发）
- 插件消息传递三处真 bug（真机 E2E 全链验证时揪出）：① 每插件 world 从未注入 webext-api 运行时（`extensionAPIScript` 写死 extensionWorld，per-plugin world 里 `chrome.*` 恒 undefined）；② 消息回程求值不指定 world（默认 page world 没有 `__desireExt`，background→页面的回复静默蒸发——PendingReply 表改为连同 content-script world 一起携带）；③ **WebKit 会吞掉导航收尾头 ~50ms 内新文档发出的脚本消息**（实测 didFinish 拍注入的代码立即 postMessage 必丢、setTimeout(0) 也丢、50ms 起存活）——document_end 插件体延时 60ms 再跑，且 desireExt handler 注册加台账去重（此前每轮 updateNSView remove+add 换桥接对象，在途消息同样被丢）、handler 未就绪时插件注入挂起到注册完成后补跑。
- 插件 URL 匹配支持 Chrome match-pattern 语义：pattern 不允许带端口，带端口的 URL（如 127.0.0.1:8877）也要命中无端口 pattern。
- 插件 reply 闭包第三次同类崩溃（insertCSS 实测 abort）：样式注入 IIFE 的尾值是 `appendChild` 返回的 DOM 元素——进 `JSONSerialization` 对 ObjC 对象抛异常、`try?` 拦不住直接杀进程。三处 reply 闭包（背景/页面/popup）default 分支补 `isValidJSONObject` 前置检查，CSS 包装尾值固定为空串；popup 的 reply 连标量分支都没有（contextMenus.create 回菜单 id 即崩）一并补全。
- 插件同名重装（更新分支）返回的是新构造对象的 uuid 而非实际入库条目的 id——桥/调用方拿到从未存在的 id（E2E 探针全打空）；`InstallResult` 改回实际入库的插件。
- 桥 `/plugins/add` 允许 background-only 插件（MV3 service worker 形态，js 可空）；`DNRRule` 这类 Swift struct 数组直接进 reply 的 `JSONSerialization` 会因 isValid=false 静默变 null（getDynamicRules 返回空对象）——经 JSONEncoder 往返成字典。
- 插件 Port 长连接 `window.__desireExt._ports` 注册表未初始化——背景页 tabs.connect/任何 makePort 调用直接 TypeError（"undefined is not an object"），首发消息全部丢失。










## [v0.5.2] - 2026-10-01
### Added

- 反"反广告拦截"内容脚本：站点检测到广告拦截后拒绝服务的两类对策——常见 bait 元素（.adsbox/adsbygoogle 等）伪装成 1×1 已加载态让检测 JS 失效；"请关闭广告拦截器"提示层直接不渲染；动态插入的检测弹层由 MutationObserver 兜底。随"拦截视频广告"开关注入，拦下情况计入拦截统计
- Agent 快捷操作新增"AI 拦截广告"（总结栏胶囊）：一键让 AI 扫描当前站点的广告候选（findAdCandidates）、甄别真广告（跳过正文和站点自有播放器）并按站点落地屏蔽规则（blockElements）——把启发式扫描、模型判定、浏览器拦截规则三层串成一键闭环
- 广告拦截学习闭环：blockElements 落站点规则时自动沉淀「站点广告画像」到 Agent 长期记忆（host + 选择器，同 host 旧画像自动替换）——AI 下次在该站工作时从记忆里"想起"广告结构，记忆随云同步跨设备共享学到的经验



### Changed

- 广告拦截三轮强化（能力基线抬升）：① 内置 Ads 域名规则 22 → 80 条（补二线广告交换、弹窗/跳转网络、分析型追踪、国内常见广告域——EasyList 的网络层兜底）；② EasyList 订阅默认启用（此前默认关，国际拦截开箱即用，6 万条 cosmetic+网络规则）；③ 视频广告拦截新增**通用 CSS 层**——各家播放器通用的前贴/暂停/角标广告 class 名（video-ad/preroll/pause-ad 等），叠加在每站专属规则之外，所有视频站受益
- 拦截规则自动更新补周期触发：启动时查一次后，长驻会话每 24h 再查（规则源每日更新，此前启动之后 7 天内不再检查）；元素屏蔽规则的 host 匹配改后缀点分语义（此前 contains 子串匹配——"example.com" 的规则会误命中 "notexample.com"）
- 设置页视频广告拦截行的说明更新（提及通用播放器 CSS、反反拦截与首击劫持防护——本轮能力的用户可见入口）
- 规则列表更新加镜像 fallback：主源（easylist-downloads.adblockplus.org，国内常被墙/劫持成 HTML）失败或返回非规则内容时，自动依次尝试 jsDelivr CDN 托管的镜像（EasyList/EasyList China/Annoyances 三列表配齐）；新增 Annoyances 订阅（AdGuard 维护的 Cookie 横幅/弹窗/社交浮层过滤，默认关尊重用户选择）
- 错误页加"返回上一页"按钮：重定向/验证链中途失败时不再把用户钉死在错误页（此前只有 Reload，会重放失败的跳转）





### Fixed

- 批量下载换站全灭：解析出的媒体 URL 是协议相对地址（//cdn…）下载器报"不支持的URL"——按详情页来源补 https 归一；同时排除 URL 路径含 IAB 展示广告尺寸（300x250 等）的资源——部分站点详情页"正片"实为页面广告视频，之前就算 URL 正确下载下来的也是广告
- 首击守卫与站点验证组件死冲突（用户实测"播放第一次点击总调验证、然后验证死循环无法播放"）：Turnstile/hCaptcha/质询容器不再被判定为广告浮层（判定时排除验证组件），验证组件上的点击整条守卫流程放行——此前守卫把验证弹层当广告隐藏，验证永远无法完成、站点反复弹验证
- 验证/质询域第三方 cookie 例外扩到主流验证产品全谱：Google reCAPTCHA（含 recaptcha.net 镜像）、GeeTest 极验、网易易盾、腾讯验证码、阿里云验证码、Vaptcha——防跟踪规则此前会把它们的跨域验证 cookie 全部丢弃，与 DMP 类自研验证同样造成"每次播放都要重新验证"的死循环；首击守卫的选择器同步扩谱（recaptcha/geetest/易盾的容器特征）




## [v0.5.1] - 2026-10-01
### Added

- 多窗口 Agent（0.1.8 挂账转正）：listWindows 工具列出全部窗口（会话短 id + 窗口标题 + 忙闲 + 是否本窗）；navigate/switchTab/readTab 支持 window 参数跨窗操作（短 id 定位，找不到明确报错）；提示词 environment 在多窗口时注入窗口清单（标记"你的窗口"）；Agent 面板头部显示本窗口名（>1 窗口时）；桥 /agent/windows 返回真实窗口标题。每窗口本就有独立的会话/TabManager/surface（WindowToolSurface），本次补齐的是"模型看见并跨到别的窗口"这半边
- 内建 PDF 查看器（对齐 Safari 的标签页内 PDF 预览）：主框架导航落 application/pdf 时取消导航、下载到临时文件、PDFKit 标签页内渲染（缩放/百分比/回原页/Preview 打开）——此前是白页只能下载后外部打开
- 下载文件名冲突策略（对齐 Chrome/Safari）：设置 ▸ Downloads ▸ Duplicate Files——自动重命名（默认，原唯一行为）/替换现有文件/每次询问；保存面板选了同名文件时落盘前移走旧文件（moveItem 不覆盖）
- 文件拖入直接打开（对齐 Safari/Chrome）：把 pdf/html/音视频/图片/txt 从 Finder 拖进页面即在本标签打开——pdf 走内建查看器，其余按 file:// 由 WKWebView 原生渲染；只接管 Finder 发起的 file URL 拖放，网页内部的拖放（拖图上传/拖拽排序）不受影响
- 地址栏历史建议频率加权（Chrome 式"最常且最近"）：HistoryEntry 加 visitCount——重复访问同一 URL 就地累计并提到最前（同 URL 不再每访一条，10 条重复把建议列表挤满的根源）；建议排序 = 新近度（24h 衰减）× 频率（平方根收敛防霸榜）；同步 payload 带访问次数（跨设备频率也计入，旧数据缺键 → 1 兼容）
- 文件拖入有视觉反馈：拖到页面上时显示强调色描边 + "松开在此标签页打开"提示（此前无任何提示，用户不知道可以拖）
- 历史面板行显示访问次数徽章（×N，>1 次才显示）——频率加权在 UI 上可见；EntryRow 组件支持可选尾缀徽章
- 查找栏 Shift+Enter 跳上一个匹配（Enter 下一个不变，主流查找栏键盘流）
- PDF 查看器缩放双向：工具栏 ±/重置与 PDFView 自带捏合/⌘滚轮缩放互通（旧实现单向覆盖用户手势缩放）
- 媒体查看器空格键播放/暂停







### Changed

- 错误页补本地文件错误（fileDoesNotExist 等）：拖入/地址栏打开的本地文件被移动、删除后刷新，不再落通用"Cannot Load Page"——给出"文件可能已被移动、改名或删除"的明确文案与专属图标
- 产品页内容更新到 0.5.x 能力：智能体检查点恢复与多窗口、批量下载智能分卷与冲突策略、本地文件拖入直接打开（第二排加"本地文件直接打开"格）


### Fixed

- 自动更新三处加固：安装失败后按钮可重试（此前 guard 只放行 .failed("")——永假，失败后无声失效）；zip 下载改流式落盘+边下边算 SHA256（不再整包进内存）并按 5% 步进发布进度（更新横幅显示百分比）；新增桥 POST /update/install（检查→安装组合入口，自动化/远程可驱动自更新）。全链 E2E（假 GitHub 端点）：下载→SHA256 校验→替换 /Applications→重启 成功；哈希错正确拒装且不崩
- 地址栏/导航方式打开本地 mp4/pdf 落"插件处理的加载"错误页（用户实测）：WKWebView 不渲染 file:// 媒体/PDF——现在与拖入共用一条本地文件打开路径（音视频 → AVPlayer 查看器、PDF → 内建查看器、其余 file:// 渲染）；音视频拖入同样改走 AVPlayer 查看器（自带控制条与明确的加载失败呈现，不再依赖 WebKit 媒体管线）
- /suggest 桥端点改同步构建：build() 带 100ms 击键防抖，桥同步读永远拿空数组（UI 真实路径不受影响）



## [v0.5.0] - 2026-10-01
### Added

- Agent 检查点恢复：回合开工即落盘"进行中"标志（随会话文件持久化），崩溃/强杀后重新打开会话时面板给出"继续回合/放弃"——继续不重复追加用户消息，工具结果缺失处由 [interrupted] 清洗兜底，模型自行续做；桥 POST /agent/resume（resume|discard）+ GET /agent/messages 带 hasInterruptedTurn；新增 POST /agent/new
- 旁路模型调用成本记账：标题生成/记忆整理（facts/summary）/自评 critic 的 token 用量按回合归账到尾助手消息（此前全部丢弃，对话成本与统计页明显少报）；usage chunk 先于正文到达时挂 pending 桶回填
- 成本感知路由：路由决策抽成纯函数 RoutingDecision（单测覆盖决策矩阵），新增"成本感知路由"开关——开启后简单短文本的纯文本回合（无工具、上下文小）交给免费的本地模型（Foundation Models / Ollama），云端留给复杂与工具回合；关闭时维持原关键词命中才走本地的保守行为


### Removed

- 删除 BookmarkStore.importFromHTML 与其私有解析器（无引用死副本；活着的导入路径是 BookmarkImportService 四路解析）

### Changed

- 批量下载分卷改智能寻卷（批内游标）：批首寻卷一次（第一个实际文件数不足 N 的卷），之后每个条目 O(1) 命中游标计数、计满才顺延并校验新卷——此前每个条目都从编号推导卷起逐卷列目录探测（SD 卡上是真实 IO 往返）；并发槽位同卷"都看到未满→都落进去"的超装竞态随游标串行分配一并消除，跨批续卷/补挂/手工放文件语义不变
- page_context 段加提示注入围栏：页面内容声明为不可信数据 + 边界标记，页面内的指令式文本不再当系统指令执行
- Keychain 访问收口共享 KeychainService（四处历史实现两两不同、Remote 的 service 名硬编码）：非交互 LAContext 语义统一，隐窗授权/ACL 类修复此后只改一处；行为不变（service 过滤、非交互启动读、失败状态码可记日志）
- 观察链补全（架构审计 ARCH-4）：ContentView 直接观察 settings（改主题/强调色不再靠"恰好有别的重绘"）、ResponsiveDesignBar 观察 store（预设清单变更可重绘）、地址建议的最近搜索段抽成自持 store 的子视图（新增历史即重绘）
- JS 字符串转义统一 JSString.literal（此前五处手写转义链各处理一部分，\r/\n/U+2028 进字面量即语法错）：收口 10 处注入点（查找计数/元素屏蔽/插件 CSS/密码回填/DevTools RPC 错误回包/xpath 等），并补上审计漏掉的 passwordDetect 用户名字段名裸插值；带 13 项单测
- ⌘S 存页从组合根搬进 BrowsingActions（写盘/落库归动作层，View 只剩结果映射 toast）；设置页"测试连接"两份手写 URLRequest 收口 AIConnectivity（鉴权头/超时/opencode 会话头/服务器错误回显统一）；阅读器设置抽独立文件
- 挂起标签二级挂起（安全子集）：快照 LRU 上限 12 份，超出的最旧挂起标签释放交互状态快照（恢复退回干净 URL 重载）——重会话下快照不再吃掉挂起省出的内存；webview 骨架的完全释放需"恢复时重建 webview"，另行立项
- 搜索建议空结果不再缓存（瞬时网络抖动曾把空数组在 LRU 槽里赖住，该词此后拿不到候选）；删除 DevTools 四个死文件（833 行，仅 Preview 引用）；QuickDial 清空被默认八枚复活与 saveAsPDF 假成功两项审计核对为已修（勿重复报）
- 防撞文件名循环统一 FilePathing.uniqueURL（下载/截图两份手写拷贝收口一处）；桥端点时间戳统一共享 ISO8601 formatter（此前现场 new 十余次）；自动化端口字面量收口 AutomationServer.hostPort/baseURL（散布 4 处）
- 插件 background 的 runtime.onInstalled 改确定性触发：页面注册监听时桥本就上报宿主，收到即派发——此前 300ms 延迟是启发式，background 代码加载慢时监听器未注册、事件凭空丢失
- ARCH-2：executeBody（122 个工具 case、1473 行）按域拆分——「页面/导航/标签/数据/控制」域（BrowserToolProvider+PageTools.swift，618 行）与「DOM 交互/录制/系统命令」域（+DOMTools.swift，891 行）以独立域函数承接，主文件缩到 338 行（域路由 + Utilities 尾段 + helpers）；case 体零改动（122 个工具逐一比对无丢失），此后加工具直接落在对应域文件
- ARCH-8：首窗口会话恢复编排从 ContentView 组合根抽出为 SessionRestore（App/SessionRestore.swift）——绑定会话身份/拖出接纳/本窗口恢复/采纳最近会话（含崩溃恢复提示回调）/legacy 接纳/兜底新标签，流程逐语义一致；组合根只剩回调装配








### Fixed

- **导航回退触发失败页（用户实测"经常"）**：goBack/goForward 打断在途加载产生的取消错误（-999）被 didFail 直接写进 lastError——错误页盖住回退后的目标页。现在普通导航失败与 provisional 失败两条路径都识别用户引发的取消（部分 macOS 构建 URLError.code 不归一为 .cancelled，按原始 NSURLErrorCancelled 兜底）并不再置错
- **设为默认浏览器状态不准（用户实测"从外面打开网址经常出问题"）**：https 设置成功即打勾、http 设置失败被静默吞掉——外部 http 链接仍归其它浏览器。现在串行设置后**重查系统实际状态**（http+https 双 scheme 都归 Desire 才显示 Default），失败进日志
- **Tab hover 预览生成慢（用户实测）**：① 显示延迟 1s → 250ms；② 15s 定时器此前只养选中页——后台页 30s 过期后 hover 才现场跨进程抓帧（200ms+）；现在 ContentView 注入 tab 源、定时器低频轮捕全部存活页（跳过未过期/加载中），hover 命中缓存几乎必然秒开
- **迭代复盘审计（v0.4.7→HEAD 全量）修复 9 项**：① 完全访问的文件路径放行在显式改过一次等级后永久失效（Workspace 读"等级键存在与否"而非实际等级，与 gate() 判定分叉）；② 看门狗掐掉卡死项落成 skipped 而非 failed——跳过重试、注释契约相反，改按失败进入重试队列；③ 批量日志从不删除（每批一份 json 永久留盘 + 进程内缓存无界）——removeSettled 时一并清理并补 batchUserAgents 释放；④ pause→resume 竞态可永久停摆 list 批次（引擎任务被取消但等 resolver 续体返回期间 engineRunning 占位，resume 误判存活不重启）——引擎代数门：取消中的任务视为死引擎照常重启，迟到退出不误摘新代槽位；⑤ 自动编辑等级绕过 deny 规则且静默放行 fillLogin（存档密码提交登录）——deny 前置到所有等级判定之前，fillLogin 列入例外；⑥ 失败项"从队列移除"空操作（skip 拒收 failed 且要求批在跑）——skip 扩展支持 failed 与已结束批次；⑦ 广告统计 perDomain 驱逐可把 other 当目标（自并合并不减键数、上限失效）——驱逐限定非 other；⑧ 广告统计"今日"跨零点不刷新直到下一个事件——读取路径主动滚日；⑨ didFail 镜像补 raw-code -999 兜底（部分构建上回退到已提交导航的取消仍会误报错误页）；另：重复的 /conversations 路由 case 删除、hover 缩略图轮捕对 NSCache 驱逐自愈、完全访问下系统命令跳过协商（与文案一致）、manageBatchDownloads 工具 schema 补 add 参数
- **Tab 预览缓存 miss 时永远停在"加载中"**：hover 触发现场抓帧是 fire-and-forget——快照 ~200ms 后到达没人推给预览面板，用户看到"加载中"直到下次 hover（桥实测截图实锤）。现在抓帧完成回调主动推图给预览面板；配合后台轮捕，预览两个节拍内必然出图
- 批量日志补 skip 事件（此前跳过无日志行：失败项移除/下载中项跳过/排队项移出）
- 手机远程新增 setAccessLevel 内层帧（三档直达，不再只有完全访问两态开关）
- **大文件 remux 被误杀 + 重试重复下载整片（用户实测 01 号 6.4GB）**：① 槽位看门狗 3 分钟无进度取消任务——remux 阶段只有开始/结束两个进度点，大文件转封装 3 分钟内无心跳被误杀；现在 remux 期间每 30 秒发一次心跳进度；② remux 独立超时固定 15 分钟不够 6GB（~27 分钟）——改为 15 分钟基线 + 每 GB 2 分钟动态；③ remux 失败保留的完整 .ts 在重试时被 uniqueDestination 绕开、整片重新下载——下载前检测同名 .ts（>100MB 视为完整产物）直接进 remux 复用。三项联动：大文件不再被误杀；即使被杀，重试也只补转封装不再重下
- 批量下载重试不再重复下载整片：.ts 预期落点随批次登记并持久化（跨重启存活），合成失败/中断后重试直接复用已下完整的 .ts 进合成（mp4 落在其旁边），此前智能分卷算出的候选卷变化会覆盖登记、让旧 .ts 变孤儿（6.4GB 实测重复下载）
- 批量下载嵌套文件夹（用户实测 directory=/Volumes/sd/missav.ws 落成 …/missav.ws/missav.ws）：工具层与桥在 folderName 缺省时自动垫站点域名子夹、无视已指定的 directory——现在 host 垫层只用于默认流（未指定目录），显式 directory = 根目录直落；批次启动回显改用真实落点（此前写死全局下载目录）；manageBatchDownloads 补 remove 动作（schema 已有、执行层缺失），removeSettled 允许删除暂停态批次（恢复后的批次 state=running 曾静默空操作）
- 独立窗口 Agent 在任务计划显示时高度无法调节：计划卡是非滚动固定区，步骤多时把浮窗 fitting 高度顶过最小尺寸——高度封顶（约 176pt）+ 卡内滚动，固定区有界后窗口恢复可调
- 任务计划改按会话归属：updatePlan 写入发起会话，面板/远程快照各自读对应会话的计划——切换对话跟随显示、切回可见、新建对话自然为空（此前全局单份 + 切换即清空）
- 任务计划卡高度改弹性：内容多高卡多高（实测步骤区自然高度定框），只有超过 176pt 封顶才在卡内滚动——此前 frame(maxHeight:) 对布局剩余空间照单全收，3 步也撑满封顶值、内容悬在中间（用户实测"高度定死了吗"）
- 任务计划随会话落盘：planSteps 存进会话文件（可选字段，旧文件兼容），打开/切换会话时恢复——重启或重开聊天记录后计划不再消失（此前只存内存）
- executeJS 失败不再重复执行带副作用的代码（点击/提交类脚本此前最多跑 3 次）：改为单次执行——表达式形态优先取值，仅解析期 SyntaxError（尚未执行任何代码）才回退语句形态，运行时错误绝不重跑
- Agent 的 navigate 对无 scheme 输入复用地址栏启发式补全（example.com → https://），不像 URL 的输入明确报错——此前 URL(string:) 构造成功但加载静默失败、回包"已导航"（假成功）
- 问题卡回答不再丢附件（sendFollowUp 此前只发文本）
- 远程信箱去重集改滑动窗淘汰——此前集满 500 一次性清空，窗口内重叠投递的旧行全部重新命中（重放=重复派活）
- 删除书签文件夹记整棵子树墓碑——此前只记文件夹一条，其他设备收不到子项删除、会把文件夹"救活"（跨设备根部复活）
- 密码保存提示的域名取提交发起页的 origin（页面脚本随消息带来）——表单提交即导航，此前收到消息时读 webview.url 已是新页，凭据被记到错误域名下（跨域跳转/SSO 回跳都踩）
- 关闭选中标签左侧的标签后选中不再跳到右边一格（删除索引算术：保持用户正在看的标签，Chrome/Safari 惯例）
- 选区 AI 条随导航清除——旧页的选区/坐标此前会一直悬在新页面上
- 纯无痕窗口的会话 key 不再被"继续上次会话"采纳（其会话文件早被 15s tick 移除，index 尾部恰是它时真正最新的会话不被恢复）
- 表单自动填充值统一 JSString 转义（旧实现只转义单引号——值含反斜杠或换行时注入即语法错，地址字段带换行很常见）
- 标签组创建的颜色选择接通（此前是死控件：点击无处理、✓ 永远钉在第一格、create 从不传 colorIndex）
- 远程 pull/push 限流按 user+device 分桶——此前按 user 共桶，Mac 1s 轮询吃掉 60/min，第三台控制器必然触顶
- 插件 background runtime 的 RPC 回包对标量负载（storage.get 返回字符串、contextMenus.create 返回菜单 id）手动字符串化——JSONSerialization 对非容器顶层抛 ObjC 异常且 try? 拦不住，整进程 FAULT（用户实测崩溃）













## [v0.4.9] - 2026-09-30
### Fixed

- **批量下载落点与追加语义终版（用户实测连环反馈后定案）**：① directory 精确直落 + folderName 可组合（directory/folderName → 父/子；都给即 /Volumes/sd + missav.ws 的直觉形态）——此前"directory 同给时 folderName 被忽略"过度纠偏；② manageBatchDownloads 的 add 现在会把**最新参数同步进被追加的批次**（maxConcurrent/splitEvery），旧批次遗留参数（并发 1、分卷 2）不再绑架追加任务——此前模型只能逐项 skip + 重建队列（用户实测的"骚操作"链）；③ 移除工具侧"站点域名自动子文件夹"回落——已按用户决定恢复（见前条），此项为该轮中间态的清理。桥 E2E：directory 直落 archived001、组合 site/archived001、add 同步参数 全通
- **视频任务面板两处显示修复（用户实测截图）**：① 批次卡的完成计数显示的是原文 `(batch.finishedCount)/(batch.items.count)`——源码里反斜杠写成双转义、Swift 当字面量文本，从头到尾就没插值过；改为真插值（11/12 正确显示）。② 顶部"下载 / 视频任务"分段控件拉伸满行、两段松散像两个独立按钮——收拢为固定宽度等宽整体控件
- 下载面板头部重排（用户实测三轮反馈）：视图切换 Tab 组贴左（页签名即视图名，去掉与之重复的"下载"大标题）；header 里重复贴了两次的文件夹按钮删除一个；全头部元素统一 28pt 高



### Added

- **系统访问允许列表主动协商**：智能体调用未在允许名单里的命令时，不再直接拒绝——自动向用户提问（面板问题卡），回复"允许"即永久加入允许列表并自动重试执行；拒绝/超时则带明确理由失败（模型据此换路）。此前 mv/df 这类命令连续被拒、智能体被名单卡死只能指路设置页
- **分卷智能顺延**：候选卷的**实际文件数**已满（≥N，.part 不计）则自动滚到下一卷——跨批次共用同一目录、用户手工放过文件、跳过造成的错位都能自愈（此前按批内编号定卷，各批编号都不足 N 时永远滚不起来，"144 个文件了还没分卷"）
- **批量面板操作完善**：已结束批次的删除 = 从面板移除（此前是空操作，永远占着面板）；排队/失败项支持逐项移除；桥 /media/batch/manage 新增 remove action
- 媒体导出总时长上限默认从 30 分钟改为 **120 分钟**（用户实测 30 分钟不够长视频慢网络）
- **批量任务日志（用户实测"分段下完导出一直 running 像假死"后要求全链可查）**：每批一份按时间追加的任务日志——批创建（模式/目录/分卷/并发/项数）、逐项解析完成、开始下载（含分卷落点）、下载完成（大小/验证/落盘路径）、失败（第几次尝试/原因）、跳过、合成开始、暂停/恢复/挂起/取消/批次完成（成败计数+总耗时）。入口：批次卡 doc.text 图标展开（mono 日志区自动滚到最新）；桥 GET /media/batch/log?id=。FIFO 3600 行、进程内缓存（防抖窗口内密集事件不再互相覆盖丢行）。附带：合成（remux）阶段新增进度上报（面板显示"合成中"，此前黑盒期 UI 静止像假死）+ 合成独立 15 分钟超时（卡住不再挂满总时长）
- **系统访问允许列表主动协商完善（用户反馈三轮）**：① 问题卡支持**快捷按钮 + 文本输入并存**（"允许"强调色胶囊、"拒绝"次级胶囊，比打字快；文本输入保留可补充说明）；② runCommand 被批准（allow_once/always_allow）时**自动将二进制加入系统访问允许列表**——一次审批，同类命令永久免问；③ 命令级允许列表内的命令**免审批直接执行**（尽可能少让用户回答）；FULL ACCESS 语义不变（更早分支，全部静默）。附：问题卡硬编码中文标题本地化。E2E：协商问句弹出 → 答"允许" → mv 入列 → 自动重试执行 → 模型收结果，全桥驱动
- **访问等级分级（参照用户提供的分级确认设计）**：完全访问拆为三级——变更前确认（默认，副作用工具逐次审批）/ 自动编辑（页面编辑类自动通过，系统命令仍受命令级允许列表管控）/ 完全访问（全部静默，最高等级）。输入栏完全访问胶囊变为 Menu 点选（图标+名称+描述+✓，三语）；持久化键 aiAccessLevel，旧安装从 aiFullAccess 迁移；手机端远程看板同步显示当前等级、远程开关映射两端。FULL ACCESS 相关既有判定（Workspace 路径放行、Remote 快照）全部兼容新等级。E2E 由桥 /approvals + 批 786E3B15 实测




### Changed

- **媒体导出 30 分钟总时长上限改为可配置（用户实测两个任务跑满 30 分钟失败）**：新增偏好"时长上限（分钟）"（默认 30，0 = 不限制，上限 600），HLS 分片循环 / ffmpeg watchdog / 超时错误文案三处共用一条配置；批量下载设置面板新增"时长上限（分钟）"行，桥 /media/batch/config 同步暴露 exportTimeoutMinutes。E2E：设 1 分钟后起慢速 HLS——ffmpeg 直连与内置回退两条路径都被正确按配置值切掉（日志实锤）
- 下载面板"下载 / 视频任务"切换改为应用设计语言的胶囊 Tab：选中 = 强调色胶囊实底，未选 = 次级文字 + 细描边（系统 .segmented 两态观感割裂，用户实测"两个按钮不和谐"）
- 下载面板视图切换并入标题行（方案 B 单行紧凑）：标题、Tab 组、图标钮一行排布，不再单独占行——原独立 Tab 行左上悬空、标题行大面积留白（用户实测"布局随便、上面空这么大"）。Tab 组 = 容器胶囊 + 选中段强调色实底
- **访问等级选择器自绘重设计**：完全访问胶囊 Menu（macOS 菜单只渲染纯文本、三档挤成三行无层次）改为**锚定胶囊的自绘 Popover**——每档一行：图标章 + 名称 + 一句职责描述，选中档墨底反白 + 强调色 ✓；点击选择即收起。"访问等级"分区标题三语
- 访问等级选择器紧凑化：面板 264→280（副标题单行不折行）、行距 4→2、图标章 26→24、字号梯度统一（节标题 9.5 大写加字距/标题 12/副标题 10/✓ 9）、内边距收紧——整体高度明显降低且信息密度更和谐






## [v0.4.8] - 2026-09-30
### Added

- **批量下载用户引导与设置面板（用户需求）**：新增"批量下载"设置区块与首用引导——保存位置（目录选择/恢复默认）、分卷规则（开关 + 每 N 个文件 archivedNNN）、并发数量（1-4）、磁盘预留空间（GB）、跳过已下载、命名风格，六项默认参数即设即用并写入长期记忆；对话中智能体仍可按批覆盖（directory/splitEvery/maxConcurrent/naming 工具参数优先）。入口：设置 ▸ 批量下载；下载面板"视频任务"右下角齿轮；首次进入视频任务栏自动弹一次引导（完成打卡不再弹）。分卷作为默认偏好贯通引擎（批未显式指定时生效）；桥 /media/batch/config 新增 splitEvery。E2E：config 设 splitEvery=1 + baseDirectory 后起批不带参数 → 落点 prefs/Desire-Batch-*/archived001/01-*.mp4。附带修复：destinationURL 的穿越防御整串替换斜杠，会把分层分卷打成单层横杠长名——改为逐段消毒保留分层
- **广告拦截统计与面板**：新增 AdBlockStatsStore（累计 / 今日按日滚动 / 分站点计数上限 60 站溢出并入 other / 最近 100 条事件，DiskStore 防抖持久化）+ 广告拦截面板（Tools 菜单"广告拦截统计"入口；今日/累计大数字、站点排行条形图、最近拦截流水、清零确认，数据 init 即载支持离屏快照）。统计口径诚实标注在面板内：仅内置视频广告规则（跳过/快进/首次点击防护）有逐次事件，EasyList 在 WebKit 引擎内执行无逐请求回调。桥新增 GET /ads/stats 与 POST /ads/stats/clear。E2E：恢复会话中的 YouTube 页真实上报 7 次拦截并出现在 /ads/stats
- **桥功能全面增强（面向自动化测试）**：① `GET /windows`——本应用在屏窗口清单（windowNumber 可直接喂 `screencapture -l`、含 frame/isKey/全屏态），替代 shell 里临时 swift 脚本查 CGWindowList；② `POST /app/quit`——优雅退出（与 Cmd+Q 同路径走 terminate→flush），测试收尾不再 pkill 强杀丢防抖写盘；③ `GET /conversations`——最新会话清单（id/标题/消息数/首条摘要），与 /conversations/delete 配合完成测试数据清理；④ `POST /media/batch/manage`——批量批次直达管理（pause/resume/cancel/skip，batchId/itemId 支持 8 位短 id 与前缀解析、未命中/歧义给出明确错误），不必再经智能体工具回合或手改盘上文件；⑤ 面板快照扩展：`/panel/snapshot?name=adblock|passwords|batch`（离屏渲染 AdBlockPanel/PasswordPanel/BatchMediaPanel，含渲染节拍与深色外观对齐）；⑥ `GET /media/batch` 行新增 destination（真实 saveRoot+folder 拼接）与 splitEvery。全端点已实测（windows/conversations/快照/manage 四动作与错误路径/优雅退出）



### Changed

- **批量下载路径语义重设计（用户实测"路径发成两段两个字段""指定 /Volumes/sd/missav.ws 却下错位置"）**：directory（或误传到 folderName 的绝对路径）= **精确目标目录，文件直接落那里**，不再叠加任何子文件夹——"我指定的路径就是下载位置"；folderName 仅在没给 directory 时作为默认下载根下的子文件夹，点噪音（"."/".."）回退时间戳文件夹。新增 **splitEvery 分卷规则**：目标目录下每 N 个文件滚动 archived001/002 子文件夹（如"每120个文件新建一个文件夹"），随批持久化、addItems 续号自动落对卷。**目标目录与分卷规则随批持久化并在重启恢复时保留**（此前 restore 丢 saveRoot——恢复后整批回落默认 Downloads）；恢复时 folder 保真（"" 直存原样保留，"." 噪音归位）。工具描述与桥 /media/batch 同步（bridge 新增 splitEvery）。修复 listBatchDownloads 输出写死默认目录、不反映批次真实落点的问题
- **打断后思考动画残留（多次修复仍有）**：两层收口——① 等待点只在"流式尾部"绘制（空正文的助手消息一旦不是尾部就安静下来，此前无条件画点=永久思考假象）；② flushTail 在取消态先补"（已取消）"再写回（cancel 写数组与循环本地缓冲的竞态——缓冲里的尾事件会把取消标记覆盖回空正文）
- **批量下载路径语义定案（用户拍板，去混乱）**：目录字段唯一——目录 = 精确落点；分卷开关开启后在该目录下按 archived001（1-N）/archived002（N+1-2N）滚动；两者组合即"每 120 个文件一个文件夹"。移除工具侧"站点域名自动子文件夹"回落（此前不指定文件夹会悄悄多垫一层域名夹）；folderName 参数仅在对话中显式需要子文件夹时使用（与 directory 组合为父/子，点噪音 = 无）。directory 与 folderName 组合语义保留（/Volumes/sd + missav.ws → /Volumes/sd/missav.ws）
- **恢复站点域名自动子夹（用户定案，撤回昨日移除）**：保存位置应设为通用根（如 /Volumes/sd），未指定文件夹时自动垫站点域名子夹——换站不混装；用户曾多设一层目录（/Volumes/sd/missav.ws），已通过偏好修正为 /Volumes/sd。桥 list 模式同步该回落。路径组合语义保留（directory/folderName 可组合，点噪音 = 无子夹）
- **已下载判断智能化 + 分卷×跳过错位修复**：① 卷号改按**文件编号**（01→archived001、121→archived002）而非"非跳过项序数"——重跑同一列表时前面的项被"已下载"跳过后，后面的文件不再错落进前面的卷（121-240 与上一批 1-120 混住的推演）；② 索引命中后**验证落盘文件仍存在**——用户手动删除/移动过的文件照常重新下载并刷新索引，不再永远跳过。E2E：删 01/03 两个文件后重跑同一列表 → 01/03 各自重下且分卷归位（archived001/archived002）、02 正常跳过，三方共存正确




### Fixed

- **批量任务无法管理（用户实测"一直报错"）**：listBatchDownloads 的输出里根本没有批次/条目 id，模型唯一能见到的只有启动摘要里的 8 位短 id，而 manage/retry 又只认完整 UUID——死循环。现在列表输出带 `[#xxxxxxxx]` 短 id（批次+条目），manage/retry/skip 改为大小写不敏感前缀解析（唯一命中即用，歧义提示加长前缀），工具描述同步
- **批量任务单点卡死拖死全队（用户实测"一个卡住剩下的都卡住，只能强退"）**：三处卡死点各有兜底——① 隐藏页加载加 60s 超时（服务器黑洞时 didFinish 永不来，串行解析队列永久阻塞）；② 人工验证等待加 5 分钟上限（此前无上限，用户不点整批停摆，超时转失败可事后 retry）；③ 下载槽位看门狗：HLS/ffmpeg 项 3 分钟无进度推进即取消其任务释放槽位（无进度数据的直连大文件由 URLSession 60s/900s 超时兜底）
- **开关窗口后打断按钮无效（用户实测只能强退）**：多窗口/浮窗各持一个会话 store，可见面板的打断只 cancel 自己——流跑在另一个 store 上时是空操作。现在打断后若自身本就空闲，联动停掉所有还在跑的会话（AgentScheduler.cancelStreamingSessions）；cancel() 补一条 ai 日志（此次事故日志里完全没有打断痕迹）
- **批量下载落点错误（用户实测"同一批任务下载错位置"）**：模型把 `"."` 当 folderName 传入时，消毒函数把它当合法名字放行——12 部全部平铺进 ~/Downloads 根、与用户既有文件混在一起。现在 `"."` / `".."` / 纯斜杠这类路径噪音一律视为"没有子文件夹"，回退到 `Desire-Batch-时间戳` 子文件夹；显式 `directory` 的语义不变（指定目录 + 时间戳子文件夹）。桥 E2E：folderName="." 的批次落点 = ~/Downloads/Desire-Batch-时间戳/01-*.mp4，根目录零散落



## [v0.4.7] - 2026-09-30

### Added

- **批量视频下载：用户可指定保存目录（用户实测反馈）**：模型把绝对路径当
  `folderName` 传时会被消毒成 Downloads 下的畸形文件夹——现在
  `folderName`/`directory` 里的绝对路径自动拆为保存目录 + 子文件夹名
  （随批持久化，不改全局偏好）；工具与桥同步加 `directory` 参数。
- **批量视频下载并发量用户可调（默认 2）**：工具加 `maxConcurrent` 参数
  （1-4），落 `batch.maxConcurrent` 偏好，`GET /media/batch/config` 可查改。
- Agent 输入栏三件套布局（参照主流客户端）：上下文占用 chip（gauge %，60% 橙 / 85% 红，与头部状态行同源数据）摆在模型选择器左侧，新增"思考等级"下拉（🧠 关/低/中/最高）摆在右侧；思考等级非默认档时随请求发送 `reasoning_effort`（默认 off 不发送，保持请求体与旧版一致，避免不认识该参数的服务报 400）；模型选择器的下拉指示改为清晰可见的单向下箭头（原 7pt 双向箭头几乎不可见）
- Agent 云端 provider 支持主流两种线协议：OpenAI 兼容（chat/completions，原有）与 Anthropic Messages API（/v1/messages）。服务档案新增"API 格式"选择（设置页编辑器分段选择 + 桥 /ai/profiles 的 apiFormat 字段），内置新增 Anthropic 预设（claude-sonnet-4-5）；AnthropicSSE 完整实现协议方言——system 顶层字段、user/assistant 严格交替、工具调用 tool_use/content_block 分片聚合、工具结果转 tool_result 块、截图 data-URI 转图片块、思考等级映射为 thinking.budget_tokens（开启时按协议要求省略 temperature 并抬高 max_tokens）、x-api-key + anthropic-version 头、模型列表拉取与用量上报（usage 记在消息上）同 OpenAI 路径对齐。假 Anthropic 端点 E2E 全通：114 工具 schema、tool_use→真执行→tool_result 往返、角色交替、usage 落盘

### Fixed
- **打断对话后正在输出的消息丢失 + 误报空响应（用户实测）**：打断时流式循环
  的缓冲消息只带 reasoning 没有正文——补"（已取消）"完结标记后再 flush；
  被打断的回合不再进入空响应重试/不再追加"模型返回了空响应"错误（打断 ≠
  模型出错）。
- **用户消息的复制按钮叠在文字上（用户实测）**：移到气泡下方（参照助手消息
  操作行样式，右对齐随 hover 显隐）。
- **顶部菜单缺密码库入口（用户实测）**：密码面板此前只能从工具栏钥匙图标
  打开——顶部 Tools 菜单新增 Password Manager（走面板路由，与 Element
  Blocker 同链路）。
- 多语言补全与目录修复：顶部菜单"Password Manager"入口（密码库/密碼庫）、下载面板"视频任务"分段与批量任务面板全部文案（暂无批量任务/媒体导出任务/已挂起/已取消/重试失败项/取消批次，悬停提示改走 String(localized:)）；目录侧修复 21 个 en 槽误填中文的键（广告拦截提示、站点名、地址栏占位、断点行等补齐英文+繁体，格式占位符统一为位置参数）、删除 2 个无代码引用的幽灵键与 1 个孤儿键、更新通知"有新版本"与"工具数"两处漏翻译、`上一条提问还没有收到回答` 的简体槽混入繁体已纠正；代码侧悬停提示字面量在运行时不走本地化的问题已包 String(localized:) 修复
- 用户消息的复制按钮永远点不到：按钮曾放在气泡行外面的独立 HStack，而 hover 判定只罩着气泡——鼠标移到按钮上就离开 hover 区、按钮随即消失且禁用点击；现在按钮放进气泡所在的容器（trailing 对齐贴气泡右缘），hover 区域包含按钮本身
- 输入栏三件套两处可见性修正（用户截图追问）：下拉箭头 7.5pt 在实机上不可见（与更早的 7pt 双向箭头同病）放大到 9.5pt；上下文占用 chip 曾按"≥2% 才显示"做——新对话 0% 直接看不见，改为常显（0% 也是有效信息）
- 输入栏下拉箭头第三次修复（前两次加大字号均无效，实机截图证实）：根因是 macOS 26 的 Menu 渲染自定义 label 时吞掉尾部内容——箭头改画在 Menu 外层 overlay（label 右内边距预留 13pt 箭头位，overlay 上 allowsHitTesting(false) 让点击穿透给菜单）
- 输入栏下拉箭头真根因（桥截图实测确认）：`menuIndicator(.hidden)` 不只隐藏系统指示，还会连带吞掉自定义 label 的尾部内容——自绘箭头 7.5/9.5pt 与 overlay 三个版本全部无效皆因此。修法：去掉 hidden 让系统画原生 ⌄（一行居中，图标-文字-指示），胶囊底/描边改挂 Menu 整体（label 会被菜单按钮再加工，边界不可靠）
- 删除当前显示中的会话后面板残留+会话复活：删除只动了存储侧，面板内存还留着已删消息（用户实测"删除全部会话回到对话页，当前会话还在，其实已经删除了"），且下一回合收尾落盘会用内存里的 conversationId 把已删文件写回复活。现在三条删除路径（历史列表单删/多选删、桥 /conversations/delete、手机远程 deleteSession）都会在删到面板正在显示的会话时把面板重置回初始空态（handleConversationsDeleted → clear(summarizeMemory: false)——跳过 L2 记忆抽取，用户丢弃会话不应被沉淀成长期记忆）。桥端点 E2E 实测：删除后面板 0 消息、文件不复活
- **打断对话后思考动画不完结（用户实测）**：cancel 收尾补完结——尾部助手
  消息只有 reasoning 没有正文时补"（已取消）"标记并强制重渲染。
- **navigate 频繁触发 Cloudflare 人工验证（用户实测）**：navigate 触发
  load 后立即返回，agent 读到挑战页判定失败 → 重试 → 挑战风暴。现在
  navigate 等主框架加载完成后检测挑战标记，最多等 15s 让 WebKit 自动通过
  managed challenge；仍在挑战则明确告知模型"需人工点击、勿重试"。
- **元素拾取取消后整页点击瘫痪（P0，虚报已修现真修）**：exit 脚本只删 style
  不摘三个 capture 监听器——取消拾取后整页点击被吞 + NotFoundError；重复进入
  拾取叠加多套监听。现在拾取器自带 `teardown`（挂 window 供 exit 调用），
  onPick 用 getElementById 判空、加 Esc 退出、重复注入先拆旧套。
- **元素屏蔽 Undo 删错 id（P1）**：handleElementPicked 生成的 rule 与 store
  入库的 rule 是两个 UUID——Undo 永远删不中，规则残留且元素在下次导航再次
  被屏蔽。现在 add 返回实际入库的规则供 undo 引用。
- **元素屏蔽规则删除无反注入（P1）**：删除规则只改 store，当前页与其他已开
  标签的即时 style 残留——删除时反向移除对应 style。
- **密码自动填充对括号形字段名静默失效（P1）**：`user[email]` 类字段名未加
  引号直接进选择器 → querySelector SyntaxError 被吞。选择器值加引号。
- **保存密码提示时灵时不灵（P1）**：500ms 延迟 post 在快速登录（响应快于
  500ms，旧文档销毁）时定时器永不触发——立即 post（值 submit 时已捕获）。
- **腾讯视频 observer 属性风暴（P1）**：`attributes: true` 无 filter——播放
  器每帧 style 变更全量扫描；补 attributeFilter 对齐 B站。
- **4 站通配 `[class*="skip"]` 点击收窄（P1）**：无广告判定时反复点击
  "跳过片头/片尾"类控件 + 计数虚高——去掉通配，保留具名类。
- **OTP 检测双链并行 + 无限自续（P2）**：命中时两链各 post 一次（提示条
  重复拉起）；长驻 SPA 双链每 1.5s 永久轮询。改为单链 + 命中即停。
- **视频规则单引号转义 no-op（P1-D 真修）**：`"'" → "'"` 在 Swift 里就是
  裸引号——含 `'` 的用户规则打爆 8 站 CSS（批 9 修了 CRLF，漏了这条同型）。

### Changed

- **DevTools Network 404/500 保留状态信息（P1-E）**：failed() 此前把
  statusCode/headers/body 全置 nil——失败请求 Status 列永远时钟。现在
  HTTP 失败保留状态信息（真网络错误仍置空）。
- **视频规则 CSS 安装脚本缓存双槽（P2-6）**：documentStart（false）与
  didCommit（true）两种变体不再互相逐出。
- **视频远程包刷新落盘降级（P2-7）**：磁盘写失败不再丢弃已成功抓取的包
  （内存采纳 + 落盘 best-effort）。
- **元素拾取重入去重（P2-11）**：同 (host, selector, xpath) 不再入库两份。
- **DevTools 悬停/改样式选择器转义**（0b3af49 声称修复的补齐——当时只改了
  inspectElement，highlight/mutate 两处漏了）。
- 密码面板重做（用户反馈"布局不合理、粗糙"）：头部改为强调色锁形徽标 + 标题/条目数 + 图标操作组（生成/导入/导出 | 清空，清空为红色并保留确认弹窗），取代三行裸文字按钮；搜索框从 .searchable 的右上角孤挂改为与书签面板同语言的内嵌搜索行（可一键清空）；条目行重绘：域名首字母强调色徽标 + 域名/用户名两级排版 + 常驻操作钮（显示/复制用户名/复制密码/删除，复制成功图标短暂变对勾），显示密码改为等宽胶囊芯片；列表按保存时间最新在前；空状态带引导文案；导入/导出结果提示补三语

## [v0.4.5] - 2026-09-29
### Added

- **媒体/拦截第十批（第三轮核查收尾）**：
  - **直连大文件流式落盘**：非 m3u8 的视频/音频 URL 先 HEAD 探内容类型，
    视频类交 `URLSession.download` 磁盘流式（此前整段 `Data` 读进内存——
    2-4GB 视频单任务数 GB 峰值，并发下载时有 jetsam 风险）；小型/未知类型
    保留内存路径。
  - **`.part` 名掺 UUID**：两批同名文件夹并发下载不再交叉写同一个 `.part`
    （此前先完成者拿走文件、后者报错且文件损坏）。
  - **`.part` 孤儿清理**：批量取消与正常收尾都会扫本批目录清除崩溃/取消
    遗留的 `.part`（磁盘预留监测的空间不再被自己的残件吃掉）。
  - **InterceptStore 删除竞态**：规则在编译回调期间被删除时不再被 add 回
    所有 controller 常驻到重启。
  - **FilterList 自愈深化**：sanitize 二分的转换挪后台（二分 14 层 × 每层
    2 块，主线程最多几十遍数 MB 转换）；probe 编译完即删（此前每次自愈留
    一份 MB 级缓存残件）。
  - **磁盘挂起"换位置"改 sheet**（远程会话触发的提问不再冻结全 app）；
  - **视频广告拦截双向生效**：关闭开关后已开标签反向移除隐藏 CSS（此前
    旧标签永远继续拦截）。
  - **xpath 转义回归修复**：批 5 的合并重构把反斜杠转义改成了 no-op——
    含 `\` 的 xpath 规则会打爆整段合并脚本。
  - **CSS 安装脚本按代数缓存补全**（声明去重与失效点复核）。

### Fixed
- **多档案 Cookie 隔离接线（P0-A）**：`addTab` 的 `profileDataStore` 参数此前
  全仓无人传入——Profile 的隔离 store 永远到不了 webview，切人物后登录态跨档案
  串档。现在缺省时兜底窗口的档案 store，会话恢复同理。
- **会话恢复懒物化补全（P0-B）**：非选中标签此前仍由 `Tab.init` 立即 load
  （N 标签启动 = N 个并发请求），且选中标签的 init load 会与 interactionState
  恢复竞争——现在非选中标签 `loadsPage: false`（挂起态首次 activate 恢复），
  选中标签恢复前先停掉在途加载。
- **密码 Keychain 读写属性错位（P0-C）**：写入缺 `kSecAttrService` 而读取按它
  过滤——重启后所有保存的密码消失、自动填充失效。写入已补齐并检查 Add 结果
  （旧条目受影响者需重存一次）。
- **批量下载 page 模式失败无限重试（P0-D）**：下载失败不递增 attempts，重试
  判据恒真 → 15 秒一轮永不落定、跨重启继续。下载失败现在烧 attempts。
- **无显式 IV 的 AES-128 HLS 静默损坏（P0-E）**：IV 生成多插 8 个零字节变
  24 字节，解密只读前 16（全零 IV）——坏 IV 每段损坏前 16 字节而 PKCS7 校验
  仍过，导出"成功"但花屏。
- **Agent 会话中途取消后永久报废（P0-F）**：未配对的 tool_calls 落盘后，
  严格端点对之后每条请求回 400——请求组装前现在全数组清洗，为每个无结果的
  调用补 `[interrupted]` 工具消息（比剥调用更诚实：模型知道哪些动作被打断）。
- **验证码提示条整条链路是死的（P1-3）**：password-detect.js 在 post
  `otpDetect`、处理分支和消费者都在，唯独消息处理器从未注册。
- **内置引擎关键词路由大小写写错（P1-10）**："baidu 新闻" 永不命中 Baidu
  （比较对象未小写），一直用默认引擎搜整串。
- **视频广告拦截三连修（P1-12/13/14）**：本地覆盖文件残留 CRLF 时 8 站 CSS
  整体 SyntaxError（转义补 \r\n）；"CSS 按代数缓存"补上真实现（此前每标签
  每次导航主线程全量重建 44KB + source.txt 每导航同步读盘）；信任远程脚本
  开关现在会推进代数（已开标签刷新即生效）、关闭开关会对已开标签反向移除
  隐藏 CSS（此前旧标签永远继续拦截）。
- **批量下载 skip 失速（P1-16）**：skip 唯一在跑的下载项后批次永久卡 running
  （并发槽空转、pending 永不启动）——skip 现在主动推进引擎。
- **本地 HTTPS 证书例外 + 插件/远程/同步六连修（第三轮功能核查第九批）**：
  - **自签名证书弹窗风暴**：一次加载对同一主机多次挑战（主框架+子资源+重定向），
    异步 sheet 化后全部各弹各的（此前被模态阻塞掩盖）——会话级信任例外（点过
    一次"仍然继续"不再问）+ 同主机挑战排队等首次决定；
  - **主框架 30s 加载看门狗曾被 beforeunload 守卫闷死**（early-return 跳过
    armLoadTimeout）——挂起的 TCP 永久白页，放行时补 arm；
  - **切标签 isLoading 永久卡 true**：dismantle 先摘 delegate 再 stopLoading，
    取消错误无人接收——顺序反转；
  - **工具栏"元素屏蔽"拾取被 DevTools 永久劫持**：intent 用完不还原；
  - **挂起标签设为分屏伙伴 = 右栏永久白屏**：显示前自动恢复；
  - **PageWatch 检查中删 watch 写穿/越界**：按 id 定位写回，删了就丢结果；
  - **地址栏 100ms 防抖窗口内回车提交上一次击键的候选**：提交前校验候选归属
    （Toolbar/新标签两处），Esc 现在真正退出 first responder（半聚焦僵尸态
    根因）；
  - **默认页面缩放设置失效**（didCommit 用字面量 1.0 兜底）、**CSV 导入按
    固定列位**（Firefox 导出写坏 Keychain 数据）——分别修复；
  - **录屏零帧/磁盘满停止即崩**：startWriting 失败守卫 + finish 只在 .writing
    态收尾；
  - **Agent：cancel 后立即新发送旧循环复活**（检查点补 Task.isCancelled）、
    **自评写进新回合消息**（按 id 写回）、**双 askUser 并行覆盖**（新问先解除
    旧问）、**取消的定时任务记成 success + RunRecord 泄漏**（失败 outcome 冲
    handlers）；
  - **同步：应用内登录后 5min 定时 pull/断网补拉/唤醒观察全部不启动**（设施
    只在启动时已登录才装）——三条登录路径补启；
  - **远程：应用内登录后 WS 永不重连**（signedOut→signedIn 转换无人接管，
    express 下行单腿）+ **手机消息落错会话**（会话基准从 stale 缓存改为面板
    实际会话）。





- **同步密钥派生失败 fail-fast（P2）**：`hmacClientID` 此前派生失败静默回退
  **随机密钥**——同一真实 id 每轮算出不同 client_id，tombstone 与反查表永不
  匹配（删除同步永久失效、同条目每轮当新行 push）。改为抛错：密钥损坏 = 该域
  对账失败并显示错误，而不是静默数据腐化。10 个调用点全部接入。
- **QuickDial 删光后重启被默认八枚覆盖（P2）**：区分"文件不存在"与"空数组"
  ——空数组 = 用户删光，尊重之。
- **URL 判定（P2）**：`example.com/search?q=x` 这类无 scheme 但 host 可判定
  的地址不再整串进搜索引擎（query/fragment 不参与判定）。
- **Agent/命令缩放不落盘（P2）**：Agent 与 ⌘命令的页面缩放此前不写
  `siteSettingsStore`——下次导航被 didCommit 打回，与手动缩放行为不一致。

### Fixed

- **视频广告拦截误伤正片（P0，第四轮核查）**：7/8 个支持站（B站/腾讯/爱奇艺/
  优酷/芒果/TikTok）的 skipAd 无广告态判定——广告拦截默认开启时，
  MutationObserver 持续触发把**正片无条件 seek 到结尾**（"直接播完"）。现在
  全部站点改为**只 seek 广告层里的视频**，正片视频永不触碰；X 无可靠信号、
  删掉无条件 seek（宁可漏拦不可错杀）。
  **v0.4.5 补充修正（B站实测仍误杀）**：首轮修复在 B站 意外丢失（修复脚本
  中途失败未写盘）——已补齐。
- **证书警告后遗漏的 Info.plist 声明（P0）**：网页请求摄像头/定位时宿主
  缺 `NSCameraUsageDescription`/`NSLocationWhenInUseUsageDescription`——
  TCC 层拒绝甚至崩溃（麦克风当初同课）。已补两键。
- **扩展 popup 的 chrome.tabs.query 缺失（用户扩展实测）**：popup RPC 面补
  `tabs.query`（trove-bookmark 登录页要取当前标签）；`background` 端补
  `action.openPopup` 映射。
- **地址栏回车/Esc 作用于旧标签（P0-2 第三轮）**：URLBarField 的 Coordinator
  首建时捕获旧 tab 闭包、updateNSView 从不刷新——导航/粘贴/Esc 全落在后台
  旧标签。每次更新刷新 coordinator 引用。
- **自签名站以外的搜索编码（P1-C）**：查询词含 `&`/`+`/`=` 时被引擎当参数
  分隔（"rock & roll" 只搜 "rock"）——四处拼接统一补转义。
- **视频规则单引号转义 no-op（P1-D）**：`"'" → "'"` 在 Swift 里就是裸引号
  ——用户规则含单引号时 8 站 CSS 全灭（与 CRLF 同型）。改为真转义。
- **DevTools Network 面板 404/500 无状态码**：`noticeFailure` 走的
  `failed(error:)` 把 statusCode/headers 全置 nil——Status 列永远时钟。
  保留状态码信息。
- **元素拾取器取消后监听器残留**（Esc 后页面点不动 + NotFoundError）+ 
  **DevTools 悬停/改样式选择器未转义**（含引号选择器静默失效）。
- **录屏 startWriting 失败（磁盘满）停止即崩**：加状态守卫。
- 其他：页面批注读盘挪后台、扩展内容脚本缓存、DevTools pendingRequests
  上限、console 重复消息丢对象 chip、网络监控 JS 大响应跳过、缩略图切标签
  不拍、容器删除孤儿化告警、QuickDial/URL 判定（随第十一批部分落地）。

### Fixed

- **视频广告拦截误杀正片（第四轮核查 P0-G，默认开启）**：7/8 个支持站
  （B站/腾讯/爱奇艺/优酷/芒果/TikTok）的 skipAd 无广告态判定——MutationObserver
  持续触发把**正片无条件 seek 到结尾**（"直接播完"）。现在各站 seek 前先检测
  已知广告容器；X 无可靠信号、删掉无条件 seek（宁可漏拦不可错杀）。
- **网页请求摄像头/定位时宿主缺用途声明（P0-R4）**：Info.plist 缺
  `NSCameraUsageDescription`/`NSLocationWhenInUseUsageDescription`——TCC 层
  拒绝甚至崩溃（麦克风当初同课）。已补两键。
- **扩展 popup 缺 chrome.tabs.query（用户扩展 trove-bookmark 实测需要）**：
  popup RPC 面补 tabs.query；background 端补 action.openPopup 映射。
- **地址栏回车/Esc 作用于旧标签（P0）**：URLBarField Coordinator 首建时
  捕获旧 tab 闭包且从不刷新——每次更新刷新引用。
- **搜索查询含 &/+/= 被引擎截断（P1-C，四处）**："rock & roll" 只搜
  "rock"——统一补转义。
- **视频规则单引号转义 no-op（P1-D）**：含 `'` 的用户规则打爆 8 站 CSS
  （与 CRLF 同型）。
- **DevTools 404/500 无状态码**：failed() 把 statusCode/headers 全置 nil；
  元素拾取取消后监听器残留；悬停/改样式选择器含引号静默失效。
- **录屏磁盘满停止即崩**：startWriting 失败守卫 + finish 只在 .writing 态收尾。
- 其他：页面批注读盘挪后台、扩展脚本缓存、DevTools pendingRequests 上限、
  console 重复消息保留对象 chip、network-monitor 大响应跳过 body 采集 +
  去重表淘汰、缩略图悬停才拍、QuickDial 删光尊重、URL 判定放行 query、
  默认缩放生效、CSV 表头映射、定时/快捷提示语不进输入历史、子代理结果
  脱敏、saveAsPDF 失败如实报、MCP resolvePath 补 query 转义、
  release.sh prep 自动同步产品页四处版本号。

## [v0.4.4] - 2026-09-29

### Added

- **插件系统归一（档位 B）**：Desire 此前有两套并行的扩展机制——
  `Features/UserScripts` 的 **Plugin 系统**（工具栏 ⇧⌘P 入口：JS/CSS 注入、
  隔离 world、storage/tabs/notifications RPC、popup、.msex 装载）与
  `Features/Extensions` 的 **SafariExtension 系统**（仅 content_scripts 注入，
  background 加载函数写了没接线、无 popup/storage，入口只有命令面板）。现
  归一到 Plugin 系统：Safari 扩展包装载并入 **MSExInstaller**
  （`.safariextension` 目录 / 含 manifest.json 的目录 / zip·crx·xpi 均可装），
  删除 `Features/Extensions/` 四文件（962 行）及全部接线。零数据迁移
  （该系统从未被真实使用）。
- **Chrome 式"从文件夹加载"已解压扩展**：`/plugins/install-msex` 与 Plugins
  面板的"安装扩展包"按钮现在都接受**目录**（含 manifest.json 的任意文件夹，
  即 Chrome 的 Load unpacked 流程）——目录走与 zip 相同的解析管线。
- **popup 相对引用资源内联**：装载时把 popup.html 里的 `<link rel=stylesheet
  href>` 与 `<script src>` 内联为 `<style>`/`<script>`（路径相对 popup.html
  所在目录解析，支持 `../` 跳包根；http(s)/data 引用保持原样；最多 3 轮防失控）
  ——真实扩展的 popup 都引用外部 css/js，此前裸内联会让弹窗变成断链白壳。
  已用 trove-bookmark 真实扩展 E2E 验证（qrcode 库/业务 JS/样式全部内联）。
- **插件 background 脚本支持（补齐 Chrome 扩展的最后一块：右键菜单）**：
  - 装载时内联 manifest `background`（service_worker / scripts）为
    `Plugin.backgroundCode`；
  - **PluginBackgroundRuntime**：每个启用且带后台的插件一个常驻 headless
    webview（baseURL = host_permissions origin → 背景脚本 fetch 与 API 同源），
    应用启动/插件启用时起、停用/卸载时停（PluginStore 变更回调对账）；
  - **chrome.contextMenus**：`create`/`remove`/`removeAll` RPC +
    `onClicked` 事件——原生右键菜单按上下文（page/link/image/selection）追加
    插件菜单项，点击派发 `contextMenus.onClicked` 给所属插件的 background；
  - `chrome.runtime.onInstalled` 每次 background 启动触发（配合原生 upsert
    幂等，菜单跨重启存活）；`chrome.tabs.query` 对活动窗口可用；
  - 桥端点：`GET /plugins/context-menus`、`POST /plugins/context-menus/click`。
  - 已用 trove-bookmark E2E：装载后 background 启动、`保存到 trove` 菜单注册
    （contexts page/link）、点击派发 ✓。
- **扩展包真实图标**：装载时取 manifest `icons` 最大尺寸的 PNG 随插件持久化
  （新增 `Plugin.iconPNG`），工具栏固定图标优先渲染真实图标、缺省回退
  SF Symbol——此前永远是拼图占位符。

### Fixed

- **扩展 popup 空白（用户实测 trove-bookmark）**：popup 宿主把 webext-api
  运行时（`chrome` 全局）注入**隔离 world**，而装载后 popup 的内联 `<script>`
  跑在**页面世界**——`chrome` 在 popup 里是 undefined，首个 API 调用即抛，三个
  初始 `hidden` 的视图永远不展开 = 空白弹窗。运行时改注入页面世界（popup 是
  插件专用 webview，只加载自带 HTML，页面世界注入安全且与 Chrome 语义一致）。
  独立 harness 实证：`.page` 注入后 `chrome` 为 object、storage 可用、内联的
  QRCode 库生效。
- **扩展 popup 的 API 请求被 CORS 拦截（"登录失败: Load failed"）**：popup 是
  about:blank 文档，对扩展 API 的 fetch 全被 CORS 拦截——Chrome 扩展页面凭
  host_permissions 跨域。现在装载时取 manifest `host_permissions` 第一个
  https/http 条目存为 `popupBaseOrigin`，popup 加载用它作 `loadHTMLString`
  的 baseURL——文档 origin 与 API 同源，fetch 不再需要 CORS 头。已实测：
  二维码正常渲染、登录流程可用。
- **扩展包装载的 attribute 正则捕获组越界**（NSException，ObjC 异常穿主 actor
  会致僵尸态）：`href` 属性提取读了不存在的捕获组 2——独立 harness 对真实
  扩展首跑即崩，已实证修复。
- **本地自签名 HTTPS 证书警告弹窗风暴（用户实测：192.168.1.6 / pve.mankong.icu
  疯狂弹窗）**：一次页面加载会对同一主机发起多次证书挑战（主框架 + 每个子资源
  + 重定向）——证书警告从阻塞式 runModal 换成异步 sheet 后，这批挑战全部
  各弹一张，弹窗成灾（此前被模态阻塞掩盖）。修复：
  - **会话级信任例外**：点过一次"仍然继续"的主机，本会话内不再询问（Chrome
    同语义）；
  - **同主机挑战排队**：决策窗展示期间的后续挑战不再各弹各的，等第一次的
    决定统一放行/取消；
  - 例外是**会话级**（重启后重新询问）——持久化需要配套管理 UI，暂不做。

## [v0.4.3] - 2026-09-28

### Fixed

- **全面体检第一批修复（报告见 docs/CODEBASE-AUDIT-2026-09-27.md，共 40+ 项分四批推进）**：
  - 页内查找计数曾用**未修复的旧副本**（`walk.nodeValue` 抛错 → 计数恒 0）——
    BrowsingActions 改调共享的 `WebView.findCountJS`，删除手抄 JS；
  - 插件 document_idle 档位注入把插件 JS 做 `\'` 转义后塞进**函数体**——函数体里
    `\'` 是非法 token，含单引号的插件必然 SyntaxError；转义整体删除（与
    document_end 档位一致裸注入）；
  - 标签自动挂起（30 分钟巡检）不豁免**正在播放音频**的标签——听歌半小时被静默
    切歌；补齐与内存压力分支一致的豁免；
  - `executeJS` 缺参返回裸 "Missing code"，不符合 `Error: ` 失败约定——机械核验
    漏计，改走 `fail()`；
  - 下载完成 `moveItem` 与密码 CSV 导出用 `try?` 吞错——失败仍报成功且零日志，
    改 do/catch + 日志/失败状态。

### Changed

- **两座本地服务（自动化桥 / MCP）的 listener 与连接从主队列挪到专用串行队列**：
  主 actor 被打瘫（ObjC 异常穿 async 帧的僵尸态，历史两次）时桥仍能收发——
  此前"窗口照常渲染但全部端点超时"的结构性根因就此移除（回调各自跳回主 actor，
  行为不变）。
- **删除未接线的 `Features/Extensions/` 死子系统**（WebExtensionRegistry 集群，
  722 行 / 3 文件，全仓仅自引用）——活着的插件系统是 `Features/UserScripts/`；
  Safari 扩展导入四件不受影响。
- `HeadlessMediaResolver`（批量下载解析器）：teardown/二次 load 时先解除挂起的
  加载续体再摘 delegate——此前取消批量下载会让引擎 Task 永久挂起（续体泄漏）。
- `BrowserWKWebView.requestInspector` 的 KVC 私有键 `_inspector` 加 `responds(to:)`
  防护——macOS 未来移除该键时从 NSUnknownKeyException 直接 abort 变为安全 no-op
  （2026-09-20 崩溃同型的最后残留）。

### Fixed

- **体检第二批（主线程热点，报告 docs/CODEBASE-AUDIT-2026-09-27.md）**：
  - 下载进度**零节流**修复：KVO/代理回调每秒数百次直写 `@Published` 数组（WebView
    representable 也观察该 store），高速下载时全 app 重绘风暴、与 Agent 流式输出叠加
    即"莫名卡顿"——节流到 150ms 一拍（终值不节流，速度按接受的采样间均值）。
  - 设置页服务列表行在 body 里现读 Keychain（阻塞系统调用，Performance Diagnostics
    点名过）→ `AgentPreferenceStore` 新增 `hasKeyByProfile` 预读发布，视图读发布值。

### Changed

- **`DiskStore.save` 的 JSON 编码从调用方线程移到后台任务**：TabManager 每 15s 的
  会话持久化此前每拍在主线程编码多 MB JSON（含各标签 interactionState），是周期性
  掉帧的直接来源；全部 DiskStore 热路径（会话/历史/书签/设置）一并受益。值经
  `EncodableBox` 过隔离边界（值语义 + 独占所有权，安全论证见源码注释；不直接加
  Sendable 约束的原因也在注释里——模块默认 MainActor 隔离会让 18 个 Model 全数
  编译失败）。落盘防抖语义不变。
- `DevToolsStore.jsRequestIDs` 加 4000 条上限（此前每条 fetch/XHR 都进、无淘汰，
  长会话下无界增长）；`MediaExportStore.jobs` 超 100 条裁最旧终态任务。

### Fixed

- **体检第三批（Agent 会话与远程控制加固，报告 docs/CODEBASE-AUDIT-2026-09-27.md）**：
  - **"新对话"不再与在跑回合互相踩踏**：`clear()`/`loadConversation()` 此前只置
    `isProcessing = false`，旧回合循环会挂在审批/提问续体上永久泄漏，且与新回合
    交错写同一 messages（工具调用/结果配对破坏）；现在先走与 cancel() 相同的取消
    舞步（取消 loopTask + 以拒绝解除挂起审批）。手机端切会话直达此路径，同样受益。
  - **工具审批加 600s 兜底超时**（与 askUser 同一默认）：面板没开/用户不在场时
    回合不再无限挂起，超时按拒绝处理并以 id 比对防陈旧超时误杀新审批。
  - **远程控制 WS 连接竞态三连修**：connect 的内层 Task 存句柄、teardown 后不再
    "复活"刚拆掉的连接（双活/旧会话泄漏）；迟到失败回调严格按 task 身份匹配，
    不再把刚建立的**健康**连接拆掉重建（周期性掉线抖动根源）；WS delegate 去掉
    跨线程读写闭包（真数据竞争），改持 weak store + 统一跳主 actor。
  - **网页弹窗不再冻结整个 app**：证书警告、摄像头/麦克风/定位授权、文件上传、
    JS alert/confirm/prompt 共 **7 处 `runModal` 全部换成异步 sheet**——此前网页
    一个 JS alert 就把主线程（含 Agent 回合、远程控制、同步）整体冻结到用户点掉
    为止。无窗口（后台/离屏 webview）给保守默认（拒绝/取消），不弹 app 模态。

### Changed

- **远程快照推送指纹前置**：此前每秒都把最近 100 条消息全量映射 + JSON 编码一遍，
  仅为指纹比对（流式期间与 flush 节拍叠加在主线程）；现在先用整数组合的廉价指纹
  判断有无变化，无变化零成本跳过（字段与帧输入一一对应）。`/tmp` 诊断日志句柄
  常驻 + 串行队列，不再每条日志开关一次文件。轮询保持 1s——降级轮询 ≤1s 延迟
  是产品规格，不做退避。

### Fixed

- **录屏功能自死锁修复（第二轮体检 ROUND2-P0，docs/CODEBASE-AUDIT-2026-09-27.md）**：
  `WindowRecorder` 把同一条串行队列既当 ScreenCaptureKit 的 sampleHandlerQueue
  又在回调里对它 `queue.sync`——对自身串行队列同步派发 = 教科书式死锁，**首帧即
  卡死**：录屏产出 0 帧坏文件、`stopRecording` 永不返回。回调本就在该队列上，
  改为直接执行；`finish()` 的 markAsFinished + finishWriting 一并进队列等真正
  写完（此前 enqueue 即 resume，与残留 append 竞态；macOS 27 SDK 起
  finishWriting() 已标 async，改用 completion 变体）。**待实测一次录屏验证产物**。

### Fixed

- **体检第五批（Agent 回合成本 + 每导航缓存，报告 docs/CODEBASE-AUDIT-2026-09-27.md ROUND-2）**：
  - **L2 会话摘要增量门控**：对话过 12 条后此前**每个回合结束都重发一次 8k 字符
    全量摘要请求**（纯闲聊也跑，memoryLearning 默认开 = 用户白付钱/额度）——
    现在新增 ≥6 条才重新摘要（与 facts 抽取同款门控）。
  - **记忆整理快照化**：housekeeping 的 await 期间用户发出下一回合时，旧循环
    会把新回合的消息一并标成"已处理"（那部分内容永远不被抽取）——所有判定
    与内容以进入时快照为准，计数只推进到快照数。
  - **地址栏剪贴板候选 COW 顺序 bug（功能性）**：值赋值发生在插入剪贴板候选
    **之前**，COW 让插入对已发布数组不可见——剪贴板链接"偶尔才出现"的根因。
  - 下载失败行纳入 100 条终态裁剪（此前一次离线批量下载的数百条 failed 行
    永久驻留）。
  - 遗留 2 处 `runModal`（⌘O 打开文件 / 新建标签分组）换异步 sheet。

### Changed

- **每导航/每击键的重复劳动批量消减**：`UserScriptLoader` 加缓存（此前每次导航
  的暗色注入与每个新标签的 10 个内置脚本约 90KB 全量同步读盘）；视频广告 8 站
  CSS 安装脚本按代数缓存（此前每标签每次导航重拼 44KB + 3 次全串转义）；
  elementBlock 的 xpath 规则从逐条 evaluateJavaScript 合并为单脚本一次注入；
  地址栏建议加 100ms 防抖、剪贴板读取加 2s 缓存（此前每击键一次 pasteboard
  跨进程 IPC）。
- 上下文占用比例计算降为 1Hz（流式期间末条长度每拍必变曾触发每拍全量字素
  计数；回合结束以 force 补终值）；桥的 trace/stats/search 端点复用内存
  ConversationStore（此前每请求 new 一个 = 主 actor 全量读盘解码；trace 保留
  落盘兜底查已删除会话）。

### Changed

- **体检第六批（启动与服务层，报告 docs/CODEBASE-AUDIT-2026-09-27.md ROUND-2）**：
  - **会话恢复懒物化**：多标签会话此前在主线程串行解码 N 份 interactionState
    归档、未带状态的标签立即 load（N 个请求并发哄抢），启动转圈随标签数线性
    恶化——现在只有**选中标签**急切恢复，其余走现成的挂起机制（原始归档数据
    直挂 `suspendedInteractionState`），首次 activate 时由 selectTab →
    unsuspend 自动恢复。整 webview 懒创建（挂起标签二级释放）仍在第七批。
  - **EasyList 转换离开主线程**：ABP→JSON 纯函数转换（最多 60k 行、数 MB JSON；
    编译失败的 sanitize 二分还会反复调）挪到后台任务；`updateList` 里"只为拿
    ruleCount 的整表二次转换"删除（复用 compile 阶段计数）。`ABPRuleConverter`
  标 nonisolated。
  - **同步派生密钥缓存**：collect 每条数据都重新 HKDF 派生 + base64 解码主密钥
    （2000 条书签 = 2000 次派生）→ 按 (master, domain, purpose) 缓存一次。
  - **自评偏好实例轻量化**：`criticPreferences()` 此前每次自评 new 完整
    AgentPreferenceStore（逐档案 Keychain 预读 = N 次 SecItem IPC）——新增
    `skipKeyStateRefresh` 跳过（评审 Key 由其自身路径显式读）。
  - **每导航重复 IO 缓存化**：Safari 扩展内容脚本按 extensionID 缓存（此前每次
    导航从扩展 bundle 重读）；页面批注首见 URL 的同步读盘挪后台任务。
  - **启动路径收尾**：UpdateChecker 延迟 4s 再发检查（启动窗口让位）；未登录
    不再启动同步 Timer/NWPathMonitor/唤醒观察者（登出即停，登录再启）。

### Fixed

- **体检第七批（细水长流收官，报告 docs/CODEBASE-AUDIT-2026-09-27.md ROUND-2）**：
  - **社区过滤列表被静默抹掉（正确性）**：`ContentBlockerStore.reapplyAll` 的
    `removeAllContentRuleLists()` 是 controller 级全清——本 store 每次刷新规则
    都会把 FilterListStore 挂在同一 controller 上的 EasyList 等社区规则一并抹掉
    且不补回。改为按持有的 ruleList 对象精确移除。
  - **会话"创建时间"漂移（正确性）**：`saveCurrentConversation` 每次保存都把
    createdAt 写成 now——已有会话沿用原值。
  - **标签栏链接预览连坐整层重算（R2-11）**：Tab 曾把 BrowserState 的**全部**
    @Published 转发给 UI——`hoveredLinkURL`（每掠过一个链接 2 发）与
    `detectedMedia`（嗅探器每资源一发）高频连坐 SelectedTabContent（工具栏/
    书签栏/HSplitView 整层）。现在只转发 17 个低频字段；链接预览条抽成自带
    BrowserState 观察的 `LinkPreviewBar` 子视图，悬停高频变化只重算那一条缝。
  - **切标签不再强制渲染快照（R2-14）**：`takeSnapshot(afterScreenUpdates:)`
    是主线程渲染强制 flush——连续切标签 = 连续渲染；预览只在悬停 1s 时需要，
    过期缩略图由悬停重拍自然覆盖。
  - 中键胶囊帧注册幂等短路（窗口拖动期间每布局帧 ×N 个胶囊的字典写与闭包
    分配省去）；Agent 证据截图缩到 ≤1200px 宽（此前未缩放 retina 位图 ×12
    ≈ 峰值数百 MB 内存）。

### Changed

- **服务端/协议（需随下次服务端发版部署）**：同步 pull 的复合游标查询从
  `> ts OR (= ts AND > id)` 改为 `>= ts` 单 range——OR 双 range 让 MySQL 放弃
  索引序、每页对全尾段 filesort（历史重度用户数万行时每翻一页一次）。旧客户端
  幂等兼容（重收行 = 同戳 LWW 无写库）；新客户端按 (updatedAt, id) 过滤已见行
  并在游标无进展时断页。**push 的 SELECT 批量化**：IN 一次取回现存行（400 条
  块的 400 次 FOR UPDATE 往返砍成 1 次；写路径保持逐行——ON DUPLICATE KEY 会
  重构 LWW 仲裁语义，刻意不做）。**rate_limit 内存泄漏**：公网扫过无鉴权端点
  的每个 IP 永久占一条 map 项——每小时清扫过期 key。
- **录屏分辨率封顶 2560**（5K 全屏 @2x ≈ 59MB/帧 BGRA，缓冲池最坏数百 MB 峰值）。

## [v0.4.2] - 2026-09-27

### Added

- **视频列表批量下载（两种模式）**：
  - **模式 A `downloadAllPageVideos`（喂食流）**：列表页卡片内直接播放的
    （feed/瀑布流），当前页嗅探 + DOM 扫描到的视频全部入队——去重、跳过
    blob:/DASH/纯音频，文件按 `01- 02-` 序号落 `<保存位置>/<文件夹>/`
    （默认以页面 host 命名）。
  - **模式 B `downloadVideoList`（逐页解析）**：每项有独立详情页的列表——
    由 Agent 收集详情页地址清单（用户确认后）交给原生引擎：**隐藏 WebView
    逐页加载**（串行 + 2-5s 抖动，复用应用桌面 Safari UA 与嗅探脚本），
    等播放器起流拿真实媒体地址，≤2 并发下载。解析梯度：等嗅探 → 周期
    DOM 扫描 → 点播放（静音）。
  - **Cloudflare 三层防线**：隐藏 WebView 与浏览标签页共享 Cookie 池，
    非交互挑战自动放行；交互式 Turnstile 先**自主通过**——解析器 webview
    弹成小窗后用 `SyntheticInput`（真实 NSEvent，isTrusted=true）点复选框
    （最多 3 次）；仍不成才降级为等人工（人工是最后兜底，不是第一响应），
    引擎继续轮询挑战解除后不重载页面直接续跑。
  - **失败自动重试（同批同文件夹）**：失败项冷却后自动重跑（≤3 次尝试，
    每次重新解析拿新签名 URL）——2026-09-26 真实站点 12 部批量实测：403 过期
    靠模型手动开新批次，文件散落三个目录；本轮根治。新增
    `retryBatchDownloads` 工具作规范重试入口，工具描述明确禁止失败后用
    `downloadMedia` 单补（散落根源）。
  - **解析节流**：下载占满并发槽时不预解析下一页——签名 URL 按需签，
    提前解析的地址会在队列里过期（403 主因）。
  - **低空间主动询问**：剩余空间低于阈值（默认 20 GB）时队列挂起，经
    `UserPromptCenter` 问用户（继续 / 换位置 / 取消，超时视为继续）；
    "换位置"走目录选择器并把位置落为偏好。新桥端点
    `GET /agent/prompt` + `POST /agent/prompt/answer`。
  - **命名偏好体系**：`clean`（默认——按最小周期折叠站点标题模板的重复段，
    真实站点那批"同一句话截三遍"的文件名根治；尾部模板残留番号一并去除）、
    `code`（番号/代号优先）、`title`（原样）。工具 `naming` 参数显式传入的
    值会持久化并**写入长期记忆**（addFact, category=preference）——模型
    下次直接知道；自定义保存位置同理。
  - **磁盘预留硬底线 + 人性化配置**：剩余空间低于预留线（`reserveGB`，
    默认 **5GB**）时**挂起整批**——在跑项收回 pending（不烧 attempts）、
    发会话备注 + 系统通知、面板提问（换位置/取消/已清理空间继续）；
    空间监视每 30s 巡检，恢复到 `预留 + 512MB` 迟滞线以上**自动续跑**。
    预留不做"继续"绕过——防止写满磁盘是目的。配置经
    `GET/POST /media/batch/config`（reserveGB / naming / baseDirectory）。
  - **批量任务管理**：新增 `manageBatchDownloads` 工具与桥端点——
    暂停/恢复整批、skip 单项（含下载中的项）、向既有批次**追加任务**
    （按 sourceURL 去重、序号接续，已完成批次追加后自动重跑）。
  - **可观测性**：快照带批次级聚合（各状态计数、暂停/挂起原因）与
    逐项进度（done/total/单位，ffmpeg 路径按秒、内置下载器按段）；
    引擎关键转移（解析/完成/失败/挂起/恢复）进统一日志
    （`subsystem == "me.siwi.Desire", category == "downloads"`）。
  - **清晰度智能选择 + 变体族去重**："按最高清晰度下载"真正进引擎——
    stream 候选里 master 播放列表（无画质标记形态）优先于任何带画质标记
    的变体（master 内部由 MediaExporter 取最高码率），无 master 时按画质
    标记（720p/1080P…）取最高；page 模式规划做**变体族去重**：master 与
    其目录下的画质变体同时被嗅探到时只留 master（此前同一视频会按两个
    画质各下一份）。
  - **已下载索引（跨批次去重）**：完成的项把来源/媒体 URL 记入索引
    （DiskStore，2000 条上限按时间淘汰），重跑同一列表自动跳过已下载项
    （skipped 注明原路径），`force` 参数（工具/桥）可强制重下；
    `batch.skipDownloaded` 开关可全局关闭。
  - **下载原子化 + 完整性校验**：所有下载一律写 `<final>.part`、成功后
    原地改名——崩溃/强杀只留一个 `.part`（下次尝试原地覆盖），根治崩溃
    残件触发 `-1` 后缀链的问题；完成后用 ffprobe 校验输出（时长 + 分辨
    率），摘要带 `✓ 60.0s, 320x240`（无 ffprobe 或校验不过则不显示）。
  - **下载历史 + 并发配置**：`GET /media/batch/history`（索引只读视图，
    最新在前，供回答"之前下过什么"）；`batch.maxConcurrent`（1-4，默认 2）
    经 config 端点可调。
  - **DASH (.mpd) 支持的可行性结论**：本机 Homebrew ffmpeg **无 dash
    demuxer**（`Unknown input format: 'dash'`，仅 webm_dash_manifest）——
    ffmpeg 直连不可行，维持跳过并注明；要支持需自写 mpd 解析 + 分段下载
    + 合流，暂不做。
  - **批量断点续传**：未完成批次持久化到 DiskStore（状态转移点即时落），
    app 强杀/崩溃后重启**恢复到队列（暂停态）**——在途项收回到 pending
    （下载地址保留，签名过期由自动重试兜底），resume 续跑；终态自动清理。
  - `listBatchDownloads` 查进度（含 attempts）；批次完成/取消/需要人工
    验证时发会话备注 + 系统通知（单项下载静默，批次统一汇总）。
  - **下载器 Cookie 透传**：`MediaExporter` 把同域 webview Cookie（30s
    缓存）附到 URLSession 分段请求、`Cookie` 头给 ffmpeg——媒体 CDN 也挂
    Cloudflare 的站点（此前分段 403）现在可下。
  - 已知边界：DASH (.mpd) 与 DRM 流不支持（批量中明确跳过并注明原因）；
    IntersectionObserver 懒加载的播放器靠点播放缓解，个别站点可能需把该页
    转到可见标签页人工触发。
  - 配套修复：批次取消后快照残留 `resolving` 行；重试后文件名序号叠加；
    低空间询问回答后永久卡住；`resolveAll` 对已解析项反复重解析。

### Changed

- 纯逻辑单测新增 `BatchMediaPlan` 用例（规划 16 项 + 命名风格 9 项，
  共 166 项）。

## [v0.4.1] - 2026-09-26

### Added

- **Desire Remote 与桌面 Agent 能力对齐（手机可介入 Agent 的每一个卡点）**：
  快照增补审批 / 反问 / 计划 / 子代理 / 排队 / 目标页 / 全权限 / 可重生成 /
  快捷动作 / 暂停 / token / 成本；手机上可**审批工具调用**（允许一次 / 始终
  允许 / 拒绝，按 `PendingToolApproval.id` 强校验以防停在旧审批上误批新审批）、
  **回答 Agent 的反问**（选项一键作答）、逐条移除排队消息、快捷动作与重新
  生成。此前这两类挂起状态完全没有走远程协议——Agent 在桌面等人工介入，
  手机既看不到也回不了，表现为"卡住不动"。
- **iOS 新增 Agent 页**（取代原「Agent 看板」那个只读数字列表）：工具与技能
  （按只读 / 改变状态 / 执行代码三档风险分级，与桌面 `ToolRisk` 同源）、
  用量统计（跨会话 token / 成本 / 每模型明细，与桌面「用量」页同一口径）、
  执行轨迹（每回合目标、工具序列与每步耗时、被拒 / 失败、慢工具榜）；
  模型、FULL ACCESS、本回合控制收进输入条左侧的状态弹窗。
- **扫码登录一次完成两件事**：登录二维码在远程控制开启时顺带携带配对信息
  （配对码 + 会话密钥 + 设备 id），手机扫一次即完成"登录 Mac"与"远程配对"。
  会话密钥仍只在二维码里传，服务器读不到。
- **远程会话控制**：新对话（先沉淀记忆摘要）、暂停 / 继续、停止。

### Changed

- **iOS 信息架构重做**：抽屉换成底部 Tab（会话 / Agent / 设置）；对话从会话
  列表进入并隐藏 TabBar（全屏聊天，导航栏透明、保留系统返回键与左滑手势）；
  状态、计划、子代理、排队、审批、提问统一到输入区上方的停靠层，模型与
  全权限等常驻信息移入弹窗——底部只留需要即时处置的内容。
- **Mac 设置与列表视觉**：新增表单行排布（固定标签列 + 撑满剩余宽度的控件，
  替代"标签左、控件贴最右"造成的半屏空白）、侧栏图标列固定宽度对齐（修正
  `iphone.radiowaves.left.and.right` 过宽导致的标题参差）、会话列表重做
  （单图标 + 内容预览行 + 时间/条数分列）、外观选择改为带图标的行式选择。
- iOS 三个 Tab 统一为 `List(.insetGrouped)` + 同一套分组标题与行样式。

### Fixed

- **Mac 登出后远程仍显示开启**：登出只在内部把连接状态置静默，开关的持久化
  真值仍是 true、心跳定时器空转。现在登出即拆链路、清设备列表与配对码、关开关。
- **手机被莫名退出登录**：refresh token 在服务端是一次性轮换的，而客户端三条
  并发路径（pull 轮询 / push 上行 / WS 重连）会各自刷新，第二个必然被拒并被
  当成会话过期 → 清凭证回登录页。改为刷新单飞，且只有服务端明确 401 才结束
  会话（网络抖动 / 5xx 不再清凭证）。
- **扫码不识别**：`startScanning()` 只在 `updateUIViewController` 里尝试，而
  sheet 弹出首帧 `view.window` 仍为 nil、之后又无人重试。改为轮询等视图上屏；
  同时补 `didUpdate` 回调、相机启动失败不再被 `try?` 静默吞掉、相机不可用时
  按钮不再是"点了没反应"的死按钮。
- **连接区块自相矛盾（上"未连接 Mac"、下"已连接"）**：Mac 名字只在配对响应
  里拿过一次且未持久化。现在随每帧快照下发并本地保存，主标题只放设备名、
  连接状态由带状态点的一行表达。
- **状态漂移**：漏掉"回合结束"那一帧会让界面停在"工作中"；三个 Tab 进页时
  强制 `requestSync()` 拉一帧权威状态。
- 输入框被消息穿透（停靠区补不透明底板、输入胶囊改实色）。

### Added

- **远程控制（Desire Remote，M0+M1，当日重构为可水平扩展传输）**：手机 App
  经 api 中继远程对话本机 Agent——**工作仍全部在 Mac 本地执行**，手机发指令、
  看进度。服务端 `modules/remote`（0008 配对码/留言 + 0009 双信箱迁移）；
  Mac 设置"远程"区（`Features/Remote/`）；`apps/ios/DesireRemote.xcodeproj`
  （登录 → 扫码配对 → 控制台）。**信道端到端加密**（AES-256-GCM，密钥只在
  二维码中，服务器只路由密文）。**传输架构（照 Trove im_ws 模式，两实例 +
  nginx 轮询部署下正确）**：上行一律 `POST /remote/push`（入库持久 + Redis
  express 发布，快照 replace 语义）；下行 = WS 订阅自己频道（即时）+
  `GET /remote/pull` 每秒兜底，按信箱行 id 去重；在线判定基于 DB
  `desktop_last_seen_at`（15s 窗口，跨实例一致）；服务端/客户端双向 20s
  心跳（解 nginx 空闲回收）。配对认领即时通知桌面收起二维码。
  **快照走独立 lane（controller_snap）**：replace 只清同 lane，不再误删
  先落地的 sessions 回包；远程"新建会话"修复（Mac 端 create 后补 save
  落盘进列表 + 手机端点"+"乐观进空聊天室、按快照 session 字段锁定选中）。
  远程开关关闭后不再有任何广播（拆 WS + 停链路循环 + isEnabled 守卫）。
  E2E：`tools/api-remote-smoke.py` 10 步全绿 + Mac 桥真机链路验证（prompt
  送达 Agent 执行、快照回传手机可解密、newSession 列表/落盘/快照三确认）。
  APNs 推送、审批卡片远程应答（M2）、按需截图未做。
- **Desire Remote iOS 支持 Markdown 渲染**：Agent 气泡接入 MarkdownUI
  （上一版手写的无依赖轻量渲染移除），主题参照 IrsClawApp——GitHub 基础
  主题 + 气泡内边距收紧、表格横向滚动（手机宽度放不下整表）、代码块/引用/
  有序无序列表全覆盖；流式更新不整棵重建（按 message.id 稳定身份）。
  **修复工具消息不渲染**：快照里调用名在 assistant 帧、结果 content 在
  tool 帧（toolCalls 为空）——此前 assistant 分支丢弃调用名、tool 分支
  无展开钮导致结果永远折叠；现 assistant 帧显示"工具调用名"行（点击展开
  参数摘要），tool 帧结果常驻显示（默认 4 行，点击展开全文）。
  **Agent 看板**：聊天页状态胶囊升级（忙时"工作中·用时"，闲时"已连接·
  模型·上下文 N%"），点击进入看板——状态区（模型/上下文占用%/排队/回合
  用时）+ 记忆区（用户画像/事实/对话摘要，滑动删除走桌面同款 tombstone
  语义）；快照协议相应扩展 model/contextPercent/queueCount/elapsed/
  toolArgs，新增 getMemory/deleteMemory/memory 帧。

### Added

- **Mac 端扫码登录（照 Trove 三步流）**：设置 → Sync 未登录时新增"扫码
  登录"——桌面出票渲染二维码，已登录的 iPhone DesireRemote 扫码并在
  手机上确认，桌面轮询领走 token 对，免密码登录。服务端新增
  `auth_qr_logins`（0010 迁移）与四步端点 `qr/create|status|scan|confirm`
  （create/status 无鉴权带 IP 限流；scan/confirm 走手机 JWT；refresh
  token 绑定桌面设备行，吊销设备即吊销扫码登录）。**token 一次性消费**
  （被领走时原子清空，防同 token 被第二个轮询方领走，Trove 踩过的坑）。
  扫码登录不经密码——E2E 主密钥沿用本机 Keychain 已有值，无主密钥的
  全新机器仍需密码登录一次完成托管恢复。另修复 iOS 切后台时任务切换
  卡片黑底（窗口底色钉为系统背景色）。

### Changed

- **DesireRemote 视图层照 IrsClawApp 架构重写**：单页聊天为根（无 Tab、
  无独立会话列表页）；左上 ≡ 弹出 Menu 半屏 sheet（.medium/.large
  detents）——Agent 状态卡（模型/上下文%/排队/连接）+ Browse 磁贴网格
  （会话/记忆/看板/扫码登录）+ 最近会话前 5；磁贴经 navigationDestination
  push 全屏页：会话列表（今天/昨天/本周/更早分组 + 左滑删除 + 左滑重命名）、
  记忆页（画像/事实/摘要 + 左滑删除）、看板页；聊天页照 IrsClaw ChatView
  （bottom 锚点滚动、safeAreaInset 漂浮输入胶囊、mic/send 圆钮、busy 变
  停止、PulsingDot 录音条、断线/排队横幅）。sessions 帧补 date 时间戳。
- **服务器地址改为"覆盖"语义（Mac + iOS）**：内置生产地址不再出现在
  任何界面（登录页删掉服务器区块、设置页占位符不露地址）；设置项留空
  = 使用内置默认，填了才覆盖（旧版把默认值写进覆盖位的自动迁移清除，
  配对/登录二维码自带服务器仍是显式覆盖来源）。Mac 端"Apply"空值 =
  回内置默认。
- **远程链路三个双端 bug 修复**：① iOS"已断开"永不恢复——`login()` 从未存
  refresh token、WS 用过期 access 直连、断线后无重连逻辑；现 401 自动刷新
  重试一次、断线 5s→30s 退避重连、会话彻底过期回登录页。② Mac 配对二维码
  认领后不消失——认领是纯 REST、桌面端无从得知；现认领即时推送通知 +
  二维码显示期间 2s 设备数轮询兜底。③ iOS 解除配对无效——只清本地不清
  服务器；现先 best-effort 调 `/remote/pairing/revoke` 再清本地。

- **默认同步服务器切至生产**：全新安装（未手动配置过服务器地址）直接使用
  `https://api.mankong.icu/v9`；已手动配置过的设备保留原值不受影响。
  服务器地址输入现在会去除尾斜杠（避免拼出 `//auth/…` 双斜杠），设置页
  占位符同步更新。本地开发用桥 `POST /sync/server` 钉回本地实例。

### Added

- **浏览历史同步（第八类，opt-in 默认关闭）**：服务端新建专表
  `sync_history_items`（0007 迁移，与通用引擎同构、按域路由表名）——历史是
  高频写入的日志型数据，与关键小域分开治理；**服务端 90 天 TTL**（history
  push 后顺带清理该用户超期行，含 tombstone）。客户端 `HistoryEntry` 补
  `updatedAt` 盖戳（旧文件缺键以访问时间兜底归一）、墓碑清单（**只有用户
  显式删除**——单删/清空/按域删/按时间删——才推 tombstone；滚动裁剪与合并
  溢出不推，靠 TTL 收敛）、`replaceForSync` 合并回写；合并语义
  `HistorySync`（FlatSyncMerge 直配）进纯逻辑单测。设置 → Sync 类目列表
  自动出现"浏览历史"开关（默认关）；桥 `/sync/status` 的 cursors/待删计数
  补 history，`/command` 补 `clearHistory`。desire-admin stats 并表统计。
- **会话过期自愈**：refresh 令牌被服务端拒绝（吊销/轮换丢失/换 JWT 密钥）
  时不再每轮空转报 401——干净登出（清令牌/游标/戳，主密钥保留）并给出
  "同步会话已过期，请重新登录"的明确提示（全局与逐域状态一致）。
- **退出前补推**：退出时有未上推的本地变更，`applicationShouldTerminate`
  走 `.terminateLater` 做**只 push 不 pull** 的限时补推（5 秒内必回调，
  推不上去的域放回脏集合由下次启动首轮对账兜底）；无脏域照常立即退出。
- **产品介绍页（`website/index.html`）**：单文件静态落地页，"墨与朱"编辑风
  （宣纸底 + 墨色正文 + 朱砂点睛，「欲」字印章记忆点）；字体全用 macOS 内置
  Hoefler Text / 宋体 / 楷体，**零外部依赖**（无 CDN，国内访问无阻碍）。
  内容：英雄区 + 六大特性 + 智能体轨迹示例 + 端到端加密三步图解（含七类
  同步 chips 与"AI 对话永留本地"的诚实标注）+ 下载四步（含 xattr 命令）。
  桌面/移动自适应；动效纯 CSS，支持 `prefers-reduced-motion` 与无 JS 降级。
  **已部署生产 <https://desire.mankong.icu/>**，主 README 顶部与 Download 段
  均已指向；更新与发布方式见 `website/README.md`。**SEO/GEO 已优化**：canonical、
  完整 OG/Twitter Card（含 1200×630 `og.jpg`）、JSON-LD（WebSite +
  SoftwareApplication + FAQPage，问答与页面可见 FAQ 逐字一致）、新增可见
  FAQ 段与导航锚点、`robots.txt`（显式放行 GPTBot/ClaudeBot/PerplexityBot
  等 AI 爬虫）、`sitemap.xml`、`llms.txt`。
- **同步改为变更驱动（近实时）**：源 store（书签/快速拨号/阅读列表/快捷键/设置/
  Agent 记忆/Agent 提示词）的变更经 `objectWillChange` 标脏对应域，5 秒防抖后只
  上推脏域——不再等 5 分钟定时轮；远端合并回写由 `applyingRemote` 守卫包住，
  拉回来的数据不会把自己标脏。启动/登录首轮仍全量对账；push 失败保留脏标记，
  退避重试（5s 翻倍至 5min 封顶，等同旧定时节奏）；睡眠唤醒、断网恢复后自动补一轮。
- **每域同步状态**：设置 → Sync 的类目列表逐域显示"✓ 相对时间 / ⚠ 错误文案"，
  单域失败不阻断其他域（错误按域隔离聚合进全局错误文案）；自动同步的失败只落
  逐域状态、不打扰全局错误（手动同步才刷新全局 lastError）；"上次同步"改相对时间。
  桥 `/sync/status` 新增逐域 `dirty/status` 观测面。

### Changed

- **push 增量化 + 大库分块**：脏域才发 push（空集合不发请求）；服务端单请求
  500 条上限（MAX_PUSH_ITEMS）不再会让大书签库整单被拒——客户端按 400 一块
  顺序推；pull 整页（1000 条）时自动翻页拉全，中途失败游标不落盘（下轮幂等重拉）。
- **设置/提示词域只推变化键**：快照 diff 收敛单次推送范围，并修掉旧缺陷——本地
  改过的设置键以前每轮都被重复上推（collect 盖新戳但快照不落盘，diff 永远不等）；
  现在"推送成功才落快照"，`/sync/setting` 桥写路径同步修正（标脏 + 盖戳，不写快照）。
- i18n：补齐 v0.4.0 同步功能漏翻的 4 条文案（验证码加载失败/密码策略/加密失败/
  未设置），新增同步副标题，目录 1301 键三语 100%。

## [v0.4.0] - 2026-09-25

### Added


- **注册体验重做 + 口令策略升级**：设置 → Sync 的登录/注册表单改为**模式切换**（登录/
  注册分段选择），注册模式提供确认密码（二次输入一致性校验）、**实时字段校验**（用户名
  规则/密码规则镜像服务端，错误即时报出不出网）与**密码强度条**（长度/字符组合 0-3 档），
  密码可见性切换。服务端口令策略升级为 **8-72 位且必须同时包含字母和数字**（注册与
  改密码共用；已有账号的旧弱口令仍可登录——登录不校验复杂度，只在下次改密时收口）；
  desire-admin 重置密码同策略。纯数字等弱口令注册返回 422（api-smoke 新增回归步骤）。
- **运维管理 CLI（`desire-admin`）**：账号与注册开关的命令行入口——`user list /
  reset-password / delete / disable / enable`（重置密码与禁用都会吊销全部刷新令牌，
  delete 级联清同步数据）、`registration status|on|off`（开关存 server_settings 表
  立即生效；env `DESIRE_API_ALLOW_REGISTRATION` 显式设置时优先，此时 CLI 拒绝切换并
  提示）、`stats`（用户数/各域密文行数）。顺带修复：**登录未拦截禁用账号**（此前
  禁用用户仍可换取新令牌，仅中间件事后 403）——login 现校验 status。
- **Agent 内容纳入同步类目（用户可选）**：新增 `agent_memory`（Agent 记忆：画像/
  事实/摘要，逐条 LWW 合并 + tombstone，能力衰减/容量淘汰/一键清空均下推删除）
  与 `agent_prefs`（自定义系统提示词，快照 diff 盖戳）两个类目，设置 → Sync 的
  类目列表自动出现开关。`AgentMemoryStore` 补同步支持（replaceForSync、待删清单、
  pin/内容修改盖戳）；对话本身仍按此前决定永久留本地。`AgentMemorySync.apply`
  合并语义进纯逻辑单测（117 项）。
- **同步数据端到端加密（E2E）**：主密钥（256 位随机）只在客户端 Keychain、永不上传；
  每域 HKDF-SHA256 派生独立密钥做 AES-256-GCM 载荷加密（信封 `{v,ct}`），真实 id/
  设置键名在密文内部；线上 client_id = 独立派生密钥的 **HMAC**（服务器只见不透明
  标签，唯一性保留、读不出内容）。服务器只新增 `users.sync_key_check`（密钥指纹，
  0003 迁移）与 `GET/PUT /sync/key-check`——**拖库只能拿到密文、用户 id 和时间戳**。
  新设备靠手动导入 base64 密钥；指纹不一致时拒绝同步（防拿错密钥把旧密文全量覆盖，
  服务端 409）。已知明文元数据：用户 id、域名、行数、时间戳、删除标记。
  E2E 实测：81 行全密文零泄漏、错误密钥导入被拒且不污染服务端指纹、解密回环后
  本地数据完好。
- **同步协作审计：五项修复**（浏览器 ↔ 后端全链路复查）：① 服务端 LWW 仲裁改 `>=`，
  **同刻时间戳 = 幂等 applied**（此前拉取/采纳过的条目每轮全量 push 必吃 conflict
  回包，纯噪音且随数据量膨胀）；② 客户端清账改"全部 results"——**输掉 LWW 的删除
  不再每周期重推**（旧逻辑只清 applied，conflict 的待删 tombstone 永久残留）；
  ③ 拉取游标升级为**复合 `updated_at|id`** + 服务端 `since_id`/次级排序（消除同刻行
  恰跨分页边界的静默丢失，ts-only 旧语义兼容）；④ 书签合并**两段式孤儿归位**（父在
  批次晚于子出现时挂回，不再永久落根，纯逻辑单测覆盖）；⑤ 加固：登录双重限流
  （IP 20/min + 用户名 10/min → 429）、注册 IP 10/小时 + `DESIRE_API_ALLOW_REGISTRATION`
  开关、时间戳钳制 [2000, now+5min]（防 .distantPast 撞 DATETIME 下限/快钟霸占 LWW）、
  单条 payload ≤256KB。E2E：同戳幂等步驟进 sync 冒烟（10 步）、限流 25 连发出现 429、
  桥真机验证"删除输 LWW → 待删清零 + 远端版本复活"。
- **同步类目由用户选择**：设置 → Sync 新增"同步类目"区块，五个域（书签/快拨/阅读
  列表/快捷键/设置）各有独立开关（默认全开，存 UserDefaults `sync.enabled.<域>`）。
  关闭 = 跳过该域的 push/pull，**游标保留**——重新打开后自动补齐关闭期间的增量；
  服务端数据不删除。桥补 `POST /sync/domain`，`/sync/status` 带各域 enabled 态。
  E2E：关快拨 → 第二设备推送 → 应用拉不到；重开 → 同步后补齐 ✓。
- **后端部署体系（照 trove 搬）**：`docker/Dockerfile.api|Dockerfile.migrate`（多阶段：
  rsproxy 镜像源 + 按架构分 id 的 cargo cache mount；api 非 root 运行、migrate 冷拷
  迁移 SQL）+ `.dockerignore`（Swift 应用/构建产物/秘密不进构建层）+ 五个脚本：
  `build-api.sh` / `build-migrate.sh`（多架构镜像）、`push.sh`（latest + commit 短
  hash 双 tag）、`run.sh`（起服务 / 一次性迁移容器）、`migrate.sh`（本地直跑）。
  **部署顺序铁律**：迁移执行器先行，改迁移不牵连业务镜像；prod 下 api 不自动跑迁移。
  清单与 env 表见 `scripts/README.md`。
- **云同步收官：settings KV 域 + 服务器地址设置**：23 个功能偏好（搜索引擎/主页/外观/
  强调色/书签栏/下载/SponsorBlock/缩放/自动播放等）全量入同步；载荷 = 带类型标签的
  `SettingsSyncValue`（string/bool/number），目录白名单 `SettingsSync.catalog` 刻意排除
  机器相关项（截图文件夹路径、自定义搜索引擎引用）。设置没有 per-key 时间戳——由
  SyncStore 维护"快照 diff 检测本地变更 → 变更盖新戳"，其余交给服务端 LWW。设置页
  Sync 区块新增服务器地址行（即时生效），桥补 `/sync/setting`（写一个可同步设置项）。
  E2E 双向验证：远端推 homePage → 应用偏好落盘；桥写偏好 → 服务端行 `{"b":true}` 带
  新戳。**注意**：设置推送若被远端拒（conflict）是 LWW 正常行为——测试时远端时间戳
  要真的更新（秒级 now 会输给应用侧微秒戳）。
- **云同步扩展到四域 + 自动化桥端点**：快拨/阅读列表/快捷键接入 SyncEngine（`FlatSyncMerge`
  通用平铺合并核心，与书签同一套 LWW 规则；`QuickDial` 增加 `sort` 字段、每次结构变更
  重编号并盖戳——位移不改戳会被远端 LWW 拒收导致跨设备顺序分叉；阅读列表**清空 = 逐条
  tombstone**；快捷键无删除语义，重置即更新）。桥新增 `/sync/status|now|login|register|
  logout|server`，同步链路可全程 curl 验证。E2E（真机 + 真库）：注册→四域全量入库
  （书签 5/快捷键 43/快拨 8）→ 第二设备 CLI 推送 → 应用增量拉取可见 → 删除下推
  tombstone（payload 置 NULL）→ 登出，测试数据已全部清理。
- **云同步客户端（首域 = 书签）**：新增 `Features/Sync/`——`SyncStore`（登录态/Keychain
  令牌非交互读写/游标/启动后 + 每 5 分钟自动同步）、`SyncAPIClient`（信封解码、401
  刷新令牌单次重试）、`SyncModels` + `SyncMerge`（树 ↔ 条目展平/合并，LWW 仲裁与
  tombstone 收敛有纯逻辑单测覆盖）。`Bookmark` 增加 `updatedAt`（optional + 合成
  Codable，旧文件缺键解码为 nil 不清数据）；`BookmarkStore` 本地删除进 `pendingDeletions`
  待删清单（显式推 tombstone，push 成功后清除，防止其他设备把已删节点"救活"）。设置页
  新增 Sync 区块（登录/注册/状态/立即同步/退出），i18n 补 21 键三语。已知边界：双端都
  有书签时首绑为并集（UUID 不同不去重）；同步当前活跃 Profile 的桶；服务器地址默认
  `http://127.0.0.1:18090`（`sync.serverBaseURL` 可覆盖）。
- **云服务后端 M1（同步引擎，`crates/`）**：通用"域 + 文档"同步——`0002_sync_items.sql`
  单表按 `(user_id, domain, client_id)` 存 JSON 文档，`GET /sync/{domain}?since=<游标>`
  增量拉（含 tombstone）+ `POST /sync/{domain}` 批量推（单批 ≤500）。仲裁 =
  `client_updated_at` **LWW**：推送逐条事务内 `SELECT .. FOR UPDATE`，旧改动拒收并回传
  服务端胜者；删除 = tombstone（`deleted_at` 置位 + payload 置 NULL，已删内容不留库）。
  首批域：bookmarks / quickdials / reading_list / keyboard_shortcuts / settings（KV）。
  `tools/api-sync-smoke.sh` 9 步全绿（conflict 回胜者 / 游标增量 / tombstone / 未知域
  404），auth 冒烟回归通过。
- **云服务后端 M0（账号底座，`crates/`）**：仓库新增 Rust workspace（照 trove 的组织方式）——
  `crates/api`（`desire-api`，axum，默认 `:18090`）+ `crates/common`（增量迁移 +
  `desire-migrate` 执行器）。功能：注册/登录（bcrypt）、JWT access + refresh token
  **事务内轮换**（旧 token 重放 401）、设备登记与吊销（客户端稳定 device_id；
  吊销联动该设备全部 refresh token 失效，重复登录自动恢复）、`/auth/me` 资料/改密码、
  dev-only `/openapi.json`（utoipa）。迁移基线 `0001_init.sql` = users / devices /
  user_refresh_tokens。全链路冒烟 `tools/api-smoke.sh` 9 步（含 409/401 反例）在真实
  MySQL 8.4 上全绿；`cargo test --workspace` 11 用例。组织约定、迁移纪律与运行方式
  写进 AGENTS.md「后端」章节。
- **发布流程一键化（`scripts/release.sh`）**：v0.3.14 的发布把每个手工步骤的坑都踩了一遍
  （Release 工作流禁晚了被 tag 触发、`gh` 用错 repo 名 404、CI 红着就打了 tag、冒烟/打包/
  校验全凭记忆排顺序）——现在全部固化成一个脚本：`scripts/release.sh <版本号>`，阶段
  **prep**（冻结 CHANGELOG + 版本号 + 构建号自增，推 main）→ **build**（clean Release +
  零警告闸门 + 产物版本核对）→ **ci**（HEAD 质量闸门，红着不许发）→ **smoke**（从
  **非 DerivedData 路径**启动冒烟 + 桥/统计/档案端点探活）→ **package**（zip + SHASUMS）
  → **publish**（先禁 Release 工作流再推 tag、正文 = CHANGELOG 段 + 安装说明模板、
  `--repo` 从 git remote 推导）→ **verify**（从 release 重新下载验校验和/版本/启动，
  完成后恢复 Release 工作流）。任一步失败 `--from <阶段>` 续跑；`body <tag>` 可单独
  预览 release 正文。安装说明抽成 **`scripts/install-note.template.md`**（CI 的
  release.yml 与脚本共用，单一真相）。**GitHub 免费额度烧完也能发**：ci 阶段
  `--ci auto`（默认；Actions 不可用时自动回落）/ `gh` / `local` 三档——`local` 用
  本地单测 + 评估套件顶上 CI 的覆盖（build 排在 ci 之前就是为了给它供产物）；
  gh API（推 tag、建 release、workflow 开关）不走 Actions 分钟数，额度烧尽照样发。

### Fixed

- **桥的 HTTP 收包循环会把被 TCP 分段的请求整个丢弃**（CI 上的 agent 评估抓到的，
  本地几乎复现不出来）：`AutomationServer` 的连接处理只调**一次** `receive()` 就把
  缓冲当完整请求去路由——TCP 不保证一次 `receive` 收全（CI 虚机的网络栈经常把
  头和 body 拆成两段交付）。被截断的请求 `body` 解析成空字典：`/agent/send` 报
  "missing text"、任何带 body 的端点随机失败，且重试也救不了确定性分段的那次。
  现在按 **Content-Length 攒齐再路由**（按字节找 `\r\n\r\n` 头尾——多字节字符
  被分段处 `String(data:)` 会直接失败，不能用字符串定位）；对端关闭但仍不完整
  的连接直接取消。8KB body × 60 次连发压力验证 0 失败。

## [v0.3.14] - 2026-09-24

### Added

- **中断恢复入口：未回答的提问一键续跑**（优化清单"检查点/恢复"的 UX 切片）：会话以
  **未获回答的用户提问**结尾时（工具执行中途被杀的典型残留 —— 提问已落盘、回答没有），
  面板在输入框上方显示"上一条提问还没有收到回答 · 继续回答"提示条 ✓；点击为**已有**
  的那条提问直接开一轮（不重复 append、不重复记历史 ✓）。桥端点
  `POST /agent/resume` 同能力（自动化用）✓。

- **空回合自动重试一次**（优化清单收尾）：模型偶发返回空内容（上游抖动、网关抽风）时，
  不再把可见警告直接甩给用户 —— 自动**再试一次**，仍空才给出说清原因的警告 ✓。
  有界：至多多一次调用，不会循环 ✓；与瞬态重试、超限减半重试的既有语义并存 ✓。
  - **实测**（假端点 EMPTYSTREAM 每次都返回空）：fixture 收到 3 次请求 = 2 次回合尝试
    （原发 + 自动重试）+ 1 次标题生成，最终以警告收尾、无死循环 ✓。

- **只读工具并行执行**（优化清单 P2）：连续的 `.readonly` 工具（getPageText、快照、
  readFile、检索类……）从逐个 await 改为**整段并发**、按原顺序落结果 —— gate 仍逐个过
  （readonly 从不弹审批、取消即拒），`toolCallId` 配对不受执行顺序影响 ✓。
  多读类回合（检查多个元素、读多个文件）的墙钟直接省一半以上 ✓。
  - **顺带修掉一个被它暴露的轨迹 bug**：步骤-结果的认领用的是"最近一个没观察的步骤"
    （位置配对）—— 串行时代恰好不出错，并行完成后**结果全部张冠李戴**（实测 3 个并行
    readFile 的结果互相错位）✓。现在按 **toolCallId 精确认领**（旧会话没有 id 的退回
    位置配对）✓；单测加了并行批的配对回归（旧算法下该用例必失败）✓。

- **Agent 评估脚本（`tests/agent-eval.py`）**（优化清单 P1）：固定 prompt 集 → 假端点 →
  断言轨迹与消息，四个确定性用例：系统提示契约（system 唯一且在开头）、**失败约定**
  （工具结果/模型所见均为 `Error:` 开头 + 机械核验触发）、**脱敏**（工具结果与模型所见
  均为 `[redacted]`、原文不出现）、**超限重试**（首答 context length → 自动重试并完成）✓。
  清理只删脚本记录的会话 id；档案自动恢复 ✓。

- **上下文管理：摘要顶替 + 超限自动重试 + 预算自校准**（优化清单 P1）：
  ① 长对话被裁掉的轮次**不再无声消失** —— 压缩时为被裁轮次生成**机械摘要**（每轮
  "用户目标｜结论"，非模型生成、有长度上限），并入开头 system 提示的
  "Earlier conversation (compacted)" 一节，模型仍知道前文聊过什么 ✓；
  ② 服务端报"上下文/输入过长"（各家措辞不一，按关键词归一识别）时，**压缩预算自动减半
  并重试一次**，成功后记住该校准预算，后续回合沿用 —— 不再把超限当成普通失败丢给用户 ✓；
  ③ 面板的"上下文占用%"同步改用**生效预算** ✓。
  - 单测：摘要包含被裁轮次的目标、预算内 digest 为 nil、压缩后逐日无断档等 ✓。
  - **实测**（fixture 首次请求报 context length、重试放行）：应用自动重试并正常收尾 ✓。

- **纯逻辑单测 harness（`tests/run.sh`）**（优化清单 P0）：解析/压缩/脱敏/用量折算/轨迹派生
  这些**纯 Foundation 逻辑**现在有一套不依赖 Xcode 的测试 —— `swiftc` 直接编译受测文件 +
  用例入口，CI 在构建前跑 ✓。首批 36 项：脱敏（含**多形态命中 + CJK 混排**的越界回归用例、
  PEM、已知 Key、无命中原样返回）、金额格式化边界（`< $0.0001` / `$0`）、用量汇总（混价
  不给总额）、统计派生（连续天数 / 峰值 / 分模型 / 逐日连续）、上下文压缩（裁最老整轮、
  最终块保留、工具配对不拆散、单轮超预算宁可超发）、轨迹派生（answer / 失败标记）✓。
  顺带把 `compactForContext` 从 `AgentSessionStore` 抽到 `ContextCompaction.swift`
  （纯 Foundation 文件才进得了这个 harness）✓。

- **工具失败统一约定：所有工具失败一律返回 `Error: ` 前缀**（优化清单 P0）：此前只有
  `executeJS` 写 `Error:`，其余失败（"File not found"、"Missing path"、runCommand 非零退出、
  MCP 报错、子代理流失败…）都是普通文本 —— 机械核验看不见、轨迹的 `threwError` 统计低估、
  模型也难以可靠识别失败。现在约 120 处失败返回全部收口（`BrowserToolProvider.fail`），
  且 **runCommand 的非零退出/超时**与 **MCP / 子代理失败**一并进约定 ✓（输出原样保留，
  模型仍能看到 stdout/stderr）。**查询成功但结果为空不是失败**（"No bookmarks" 等），
  避免把正常空答案误标成错误 ✓。
  - **实测**（假端点强制 `readFile` 一个不存在的文件）：工具结果 = `Error: File not found: …` ✓；
    **机械核验第一次对这类失败触发了硬提示**（"本轮所有工具调用都被拒或报错"）✓；
    轨迹 `threwError = true`、`stats.threwError = 1` ✓；模型实际收到的工具消息同样以
    `Error:` 开头 ✓。

- **crew 用量记账 + 状态可见**（优化清单 P1）：多标签 crew 的 worker 跑在各自标签页里，
  此前用量**无处记账**（成本与统计都会低估，一次 crew 可能比主循环本身还贵）。现在：
  worker 的 token 按 crew 累计 ✓；落定时写成一条带 token 字段的系统备注进会话 ——
  统计与成本随之把 crew 算进去 ✓（字段不进模型请求正文）✓；`crewStatus` 的返回也带上
  `[usage] …` ✓。
  - **实测**（1 子任务 crew，假端点）：落定后会话出现"消耗 12.8k tokens（in 12.0k / out 800）"
    的系统备注 ✓；统计 totalTokens 精确 +12800、归入"子代理"桶 ✓；领队聚合轮的 12800
    单独计 ✓ —— 对账无重复、无遗漏 ✓。


- **Agent 面板输入框自动聚焦**（优化清单 P0；用户此前反馈过"必须先点一下输入框"）：
  打开面板或从子页回来时，焦点自动交给输入框（跳一帧 + 400ms 延迟 —— `@FocusState`
  在 onAppear 事务里直接置真走不进 AppKit 的 first responder，AGENTS 记录在案）；
  停在子页（轨迹/统计等）时不抢焦点 ✓。

- **地址栏：输入被立刻清空 / 候选闪一下 / 有网址时不出候选**（用户反馈）：三个症状是**同一个 bug** ——
  聚焦时那次"把缓冲播种成当前 URL"的写入（`Toolbar.swift` 的 `.onChange(of: isUrlFocused)` 分支）✓。
  它本来就**多余**（未聚焦期间 `.onChange(of: displayedURL)` 一直在同步），而它依赖的聚焦通知是
  **晚一帧**到的（地址栏是 NSViewRepresentable，同步置位会报 "Publishing changes from within view
  updates"，所以当初跳了一帧）✓ —— 于是"点进去马上打字"时，这一帧的播种把刚打的字**覆盖回 URL** ✓；
  紧接着候选浮层因为失焦而收起 ✓（看起来就是"闪一下"）✓；"有网址时输入不出候选"同样出在这里
  （缓冲被重置成 URL，模型自然不会为"你打的那串"给候选）✓。
  - 修法：**聚焦不再播种** ✓；并给"失焦"通知加了真实状态校验（跳一帧后 field editor 还在 = 仍在
    编辑中，不报失焦）✓。

### Fixed

- **Keychain 授权窗能把应用钉死在启动里（本次发版冒烟抓到，v0.3.13 同样中招）**：
  本地构建是 adhoc 签名——每次重建/换路径 cdhash 都变，Keychain 条目的 ACL 认不出
  当前构建时，`SecItemCopyMatching` 会向 SecurityAgent 申请授权；实测那个授权窗
  **可能永远不渲染**（进程和窗口都在、屏幕上什么也没有），而 `AgentPreferenceStore.init`
  在 `applicationWillFinishLaunching` 的主线程上同步等它 —— 整个应用死在启动里，
  且之后每次启动都排在同一个隐窗后面，全部挂死（桥无响应、进程活着、无崩溃报告，
  与"主 actor 僵尸"外观一致但根因不同）。
  - 修法：**启动与回合中路径的 Keychain 读全部改为非交互**
    （`kSecUseAuthenticationUI = Fail`：失配时失败成"无 Key"，绝不等 UI）——
    init 的 `refreshKeyState`、迁移读、`secretsForRedaction`（桥驱动的回合没有用户在场）、
    critic 档案检查、`PasswordStore.loadAll`（init 全量读）；设置页等用户在场的路径
    保持交互（授权窗可答，答一次"总是允许"即恢复）✓。adhoc 构建换路径后 API Key
    显示为未配置属预期，设置里重存一次即可 ✓。

- **脱敏代码把应用打成了"僵尸"：主 actor 永久卡死，界面却照旧**（排查"桥端点忽然没响应"时
  挖到底）：`SecretRedactor` 的 `NSRange` 在循环**外**算了一次 ✓，而循环里每次都改写文本
  （`[redacted]` 比任何命中都短 → 串必然变短 ✓）—— 下一轮 `firstMatch` 带着**越界**的旧范围
  调用 Foundation ✓，直接抛 `NSRangeException` ✓。异常从 Swift async 帧里穿出去（工具结果
  入会话这条路径 ✓），被 HIServices 的处理器吞掉 ✓，**主 actor 的执行器就此损坏**：此后所有
  `@MainActor` 任务只是排队、永不执行 ✓ —— 桥端点全部无响应（连 `/state` 都挂）✓、数据文件
  停在出事那一秒 ✓，但窗口照常渲染、AppKit 事件循环照常、**甚至还能被 `osascript quit`
  优雅退出** ✓，所以看起来完全不像崩了（没有崩溃报告 ✓，只有 `log` 里那行 NSRangeException）。
  - 修法：`NSRange` **每轮重算**、现算现用 ✓；并审计了全仓另外两处正则
    （`MarkdownRendererView` / `DevToolsPanel`）—— 都是现算现用 ✓，只有这一处踩了。

- **悬空 tool_calls（工具执行中途被杀 → 之后每一轮请求都被服务端拒绝）**
  （优化清单"检查点/恢复"的最小切片）：应用在工具还没跑完时崩溃/退出，最后一条
  assistant 的 tool_calls 没有等到结果 —— OpenAI 兼容服务会拒绝
  （"assistant message with tool_calls must be followed by tool messages"），且之后每一轮
  都拒绝，会话等于报废（模型永远答不上来）。
  现在构造请求前把**末尾悬空**的调用剥掉（正文保留；正文也为空则整条丢弃）✓，
  只处理崩溃形态，不猜更多 ✓；单测 4 项（剥字段/整条丢弃/正常会话不受影响）✓。

## [v0.3.13] - 2026-09-23

> Agent 健壮性与闭环收尾（优化清单 P0/P1 落地）：工具失败统一约定（`Error:` 前缀，
> 约 120 处收口）、空回合与超限的自动重试、被裁轮次摘要顶替、只读工具并行、
> 中断恢复入口、crew 用量记账与模型归属、CI 接入评估套件与单测；
> 以及地址栏输入被清空、消息操作按钮压住正文、三条运行时警告等一批修复。
### Added

- **Token 使用统计面板**（用户："token 统计面板也要加 参照这样的面板"）：Agent 面板头部多一个
  入口 ✓，页内四段——**头条**（累计 Token / 单日峰值 / 最长对话 / 当前连续 / 最长连续，
  填过单价还会多一个成本）✓、**Token 活动热力图**（GitHub 风格：列 = 周、行 = 周一到周日，
  颜色深浅按当天 token，悬停给"日期 · token · 轮数"）✓、**每日 Token 趋势**（按模型分色 +
  近 7 / 30 日切换）✓、**模型用量**（环形图 + 每模型百分比 / token / 金额）✓。
  - 数据**全部从已存盘的会话派生**（token、模型、时间戳都记在消息上）✓ —— 与轨迹页同一个
    原则，所以统计永远和聊天记录对得上；桥 `GET /agent/stats?days=N` 与页面同一套实现 ✓。
  - **两条如实说明的前提**（写在页脚）：只有服务端上报过用量的调用才计入；**本功能上线前的
    历史对话没有记录，显示 0** ✓（实测：既有 8 个会话、33 轮全是 0，只有新增的用量有数）✓。
  - 没有模型归属的用量（子代理）单列**"子代理"**一行 ✓；金额沿用"没单价就不显示"的规矩：
    只要有一笔没定价，**总额就不显示**（各模型自己的金额照常显示）✓。
  - **对账实测**：造一份跨 40 天、4 个模型、含空日与连续段的合成数据，桥端点与**独立重算**
    （Python 直接读会话文件）逐项一致 —— 累计 215860 / 峰值 51600 / 当前连续 5 / 最长连续 8 /
    最长对话 2160300s / 各模型 {gpt-4o 100440、gpt-4o-mini 44620、deepseek-chat 35960、
    glm-4.5 30540、子代理 4300} ✓；填上单价后各模型金额也与手算一致
    （0.3024→`$0.302`、0.008007→`$0.0080` …）✓。
  - **布局在 380 / 420 / 900 三种宽度**下各渲染验证 ✓（面板可拖宽拖窄，窄面板最容易挤坏）——
    走新增的 `GET /panel/snapshot?name=agentstats&w=&h=`（进程内渲染，不依赖屏幕录制）✓。
  - **UI 重做（用户："使用统计 UI 还要继续美化 还要考虑窗口是可以拉宽的"）**：每段改成
    **卡片**（淡底 + 发丝描边 + 12pt 圆角 + 分区图标）✓；头条变成**一条卡片里按列数排开、
    列间竖分隔线**（宽面板一行六格、窄面板自动两列三行）✓；热力图与模型列表按可用宽度
    换档 / 铺满剩余宽度 ✓；内容**限宽 1100 并居中** ✓——不限宽的话热力图最多 53 周，
    拉到 2000pt 时右边会空掉一大半（比对称留白更难看）。
  - 顺带修掉三处：趋势图**图例列出了没画的模型**（Charts 按 domain 出图例，得只给画出来的
    前 5 个）✓、窄面板下热力图档位跨度太大右侧空一块（补 30/22/14 周三档）✓、
    月份标签落在相邻列时会撞在一起（"5月6月"）✓。
  - **空状态**：一条用量都没有时不再给一张空仪表盘，改成一条说明卡并如实告知"已保存 N 轮
    对话" ✓ —— 这正是**现有用户第一次打开时看到的样子**（本功能之前的历史对话没有用量）✓。
  - 按 **380 / 700 / 1100 / 1500 四个宽度**渲染验证 ✓（含空状态）✓；三语共 18 个新键
    （目录 1238 键、零缺口）。
  - **热力图改为"量宽度、现算格子边长"**（用户："方块要加点圆角 要撑满宽度啊 自动调整"）：
    原来用固定档位表（53/44/34…周 × 11…18pt），档与档之间必然落差几十到上百点——
    700pt 面板挑中"34 周 @13pt = 508pt"，右边就空 136pt ✓。现在先用"格子不小于 11pt"
    反推能放多少周（上限 53 周 = 一年），再把宽度平分给这些周，**任何宽度都正好铺满** ✓；
    圆角也随格子边长走（`min(5, max(2, 边长×0.24))`）✓，小格子不会变成圆点、大格子看得出圆角 ✓。
    实测 420 / 700 / 1100 三档铺满效果 ✓。
  - 配套：桥的快照要多等一拍才能拍到"量完宽度"的那版；等法是 `Task.sleep` 而**不是**
    `RunLoop.current.run` —— 后者在 async 上下文里阻塞协作线程池（Release 构建报两条
    "unavailable from asynchronous contexts"，Debug 增量构建看不出来）✓。

- **成本估算：把 token 折算成钱**（对照评估里"成本与延迟平衡"那条——此前只有 token 计数与
  上下文占用，于是"轻任务走轻模型"没法度量）：面板状态行多一个成本 chip ✓（`$0.038`），
  悬停给出本对话的 in/out token 与金额 ✓；轨迹页总览多 `Tokens` / `Cost` ✓、每个回合的摘要行带
  `12.8k tok · $0.038` ✓、展开能看到这一回合**实际用的模型** ✓；桥 `GET /agent/trace` 的
  stats / 每回合 / 新增的 `usage` 段与面板同一口径 ✓。
  - **单价由用户填**（设置 → Agent → 成本，或桥 `GET|POST /ai/prices`），口径为**美元 / 每百万
    token** ✓。**不内置价格表**（服务商改价是常事，内置一份很快变成错的信息）、**也不做前缀匹配**
    （`gpt-4o` 会顺手套到 `gpt-4o-mini` 头上，差 10 倍）✓——填了才算。
  - **诚实性规则**：没填单价 → 只显示 token、**绝不显示 `$0`**（那会被读成"免费"）✓；
    一段对话里只要有一笔没定价，总额就不给（改标 `≥`）✓；比 4 位小数还小的非零值写成
    `< $0.0001` ✓（四舍五入成 `$0.0000` 是另一种谎）。
    **实测**：12000 in / 800 out + `$2.5/$10` 单价 → `$0.038`（与手算一致）✓；换成未定价模型
    再发一轮 → 会话总额消失、该回合仍只显示 token ✓；改单价后**已有的对话立刻按新价重算** ✓。
  - **落盘**：逐条消息记 token 与**产生它的模型**（响应里的 `model` 优先——网关会路由/改写，
    成本得按真跑的那个算）✓，所以历史会话也能重新定价、重新算钱 ✓。
  - **子代理的用量记在 `spawnSubagent` 的工具消息上** ✓：它跑在自己的消息数组里、不进会话，
    不认领的话对话成本会明显少报（一次 crew 可能比主循环本身还贵）。
    已知缺口：**多标签 crew、自评 critic、标题/记忆整理这些旁路调用不计入对话成本**。
  - 三语 8 个新键（目录 1214 键、零缺口）。

- **桥端点 `POST /conversations/delete`**（E2E 收尾清测试遗留用）：按 `id` / `ids` 批量删会话 ✓。
  写操作走**UI 持有的那份 store**（活会话 → `AppState` → 读盘兜底，响应里如实回报
  `scope` ✓）——用新实例删只会删掉盘上的文件，界面列表里那一行还在 ✓。
  实测：删完等过 `DiskStore` 的 500ms 防抖，检索里就没有了 ✓。

- **输出护栏：凭据在进入对话之前就被屏蔽**（用户："继续" → 输出护栏）：两道判据，一严一宽 ✓
  ——① **应用自己配置的密钥**（所有服务档案的 Key）精确匹配 ✓（自建网关的 Key 没有任何
  形态特征，只能靠这条认 ✓）；② **常见密钥形态**（OpenAI / Anthropic / GitHub / AWS /
  Slack / Google / GitLab、`Bearer …`、PEM 私钥块）保守匹配 ✓ —— 每条都带长度下限，
  宁可漏也不能误伤普通正文（正文里出现 "sk-" 很正常 ✓）。
  - 屏蔽发生在**消息入会话之前**（工具结果追加时就地脱敏 ✓ + 回合收尾对助手文本再扫一遍 ✓），
    于是**会话文件、轨迹文件、发往模型服务的请求**三者都拿不到原文 ✓ —— 模型看不到，
    也就无从复述 ✓。工具最容易把凭据带出来（`cat` 一个配置、`curl -v` 打印请求头…）✓，
    而把这段结果交给**第三方**模型服务，正是这条护栏最该堵的路 ✓。
  - **实测**（假端点 + 让模型调 `readFile` 读一个含假密钥的文件）：工具结果进对话时已经是
    `OPENAI_API_KEY=[redacted]` / `Authorization: [redacted]` ✓；再把**模型实际收到的**
    工具消息原文回显出来（`MODEL-SAW>>>…`）✓ 也全是 `[redacted]` ✓ —— 端到端证明上游
    从没看到原文 ✓；轨迹里那一步的 `result` 同样是脱敏后的文本 ✓。

- **独立评审档案（critic）**（评估里"自评是自己在评自己"那条）：设置 → Agent 里新增
  **评审者** 选择 ✓ —— 选另一个服务后，`reflect` 工具与回合收尾的自动自评都走它 ✓
  （**评审者 ≠ 被评审者** ✓ 换一个模型才能看到被评审者自己看不到的问题 ✓）；保持"与当前
  对话同一服务"就是原来的同模型自评 ✓。
  - 实现上不碰当前会话的模型 ✓：给评审单独建一个**轻量偏好实例**（provider 是无状态的、
    只读传入的 prefs ✓）→ 无竞态、不影响正在进行的回合 ✓。
  - **评审档案没配 Key 时自动回退**到当前档案 ✓ 并记一条 error 日志 ✓ —— 否则自评会因为
    "API Key not configured" **静默失败** ✓，用户看到的只是"自评忽然不工作了" ✓（实测踩到 ✓）。
  - 实测（两个假端点）：主对话走 A、评审走 B ✓ —— 会话里存下的评语正是 **B 独有的文本** ✓，
    证明评审确实换到了独立服务 ✓；A 全程没有收到评审请求 ✓。
  - 新增 3 条三语文案（目录 1206 键、零缺口）。

- **轨迹页（可观测性落地到 UI）**（用户："trace 关键"）：`AgentTrace` 的派生内容现在有个
  页面能看了 ✓ —— 面板头部新增轨迹入口 ✓，页内分三段：
  - **总览**：回合数、工具调用数、失败/被拒、**平均工具耗时**、**未验证回合数**、👍/👎 计数 ✓；
  - **工具**：最慢的几个（平均耗时）与最易错的几个（失败/调用）✓ —— "哪个工具慢、哪个爱挂"
    一眼可见 ✓；
  - **回合**：逐条展开 Thought → Action → Observation ✓（动作 + 参数摘要 + 观察 + 每步耗时 +
    `denied`/`threwError` 标记 + 回答 + 自评 + 未验证提示 + 用户投票 ✓），顶部可切换会话 ✓。
  - 数据**全部从会话派生**（`AgentTrace` 一份口径 ✓，与桥的 `GET /agent/trace` 同源 ✓，
    `stats` 也一并在该端点返回 ✓），所以这一页与历史消息永远对得上，也不需要在热路径埋点 ✓。
  - **实测**：真实会话 9 个回合 → `toolCalls=8 / failed=1 / avgToolMs=104.9 / unverified=2` ✓，
    并用**独立重算对账**（从导出的 JSONL 自己统计得 8/1 ✓ 与 stats 完全一致 ✓）。
  - 新增 11 条三语文案（目录 1206 键、零缺口）。

- **轨迹导出（Thought → Action → Observation）+ 分工具耗时**（评估里"没有结构化轨迹"那条，
  它是后面所有分析的前提）：新增 `AgentTrace`，把一条会话编译成**一行一个回合的 JSONL**——
  每行含目标、步骤（动作 + 参数 + 观察 + **耗时 ms** + 两个如实命名的失败标记 `denied` /
  `threwError`）、最终回答、自评、机械核验、以及**用户的 👍/👎** ✓。
  - **轨迹从会话本身派生，不另存一份**：会话里已有目标/调用/观察/回答/自评/反馈 ✓；唯一
    派不出来的是**工具耗时** ✓ → 所以它记在**工具消息**上（`AgentMessage.toolDurationMs` ✓）
    随会话落盘 ✓ → **历史回合也能导出** ✓，且导出的内容与用户看到的永远一致 ✓。
  - 桥：`GET /agent/trace?conversation=<uuid>&limit=N` ✓（默认活动会话 ✓）。
  - 聊天里也直接显示耗时：工具卡片上标 `0.1s` / `1.2fs` ✓ —— "哪个工具慢"一眼可见 ✓。
  - 实测：真实会话导出 2 个回合并逐字段核对 ✓；新回合的 `ms` 是真实数字（如 `getPageTitle
    ms=104.9` ✓），加计时之前的老回合如实为 `null` ✓（不编造 ✓）；失败标记与机械核验同一
    口径（只认应用自己写的两种 ✓）。

- **回答质量反馈（👍/👎）**（评估里"最便宜也最真实的标签"那条）：助手回答 hover 时出现
  两个小按钮（与复制按钮同规格、同排 ✓），投过票会保持高亮 ✓；投票**随会话文件落盘** ✓
  ——这是将来做评估集的第一桶数据 ✓。
  - 存储 `AgentMessage.feedback`（`up`/`down`/清除 ✓）；面板走活动会话 ✓，桥端点
    `POST /agent/feedback {"messageId","vote"}` 找不到活动会话里那条时会落到**已存盘的会话** ✓
    并如实回报 `scope: live|saved` ✓（此前那种"静默无效却报成功"的情况已修 ✓）。
  - `/agent/messages` 现在带每条消息的 `id` ✓（自动化要用它投票 ✓）。
  - 实测：`down → 落盘 ✓ → 改 up ✓ → 清除 ✓`，端点回报 `scope: saved` ✓。
  - **注意**：按钮用**回调下传**而不是 `@EnvironmentObject` ✓ —— 面板是显式传参持有 store 的 ✓，
    环境里没有它 ✓，用 EnvironmentObject 会在运行时直接崩 ✓。
  - 新增 2 条三语文案（目录 1195 键、零缺口）。

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

- **地址栏：输入被立刻清空 / 候选闪一下 / 有网址时不出候选**（用户反馈）：三个症状是**同一个 bug** ——
  聚焦时那次"把缓冲播种成当前 URL"的写入（`Toolbar.swift` 的 `.onChange(of: isUrlFocused)` 分支）✓。
  它本来就**多余**（未聚焦期间 `.onChange(of: displayedURL)` 一直在同步），而它依赖的聚焦通知是
  **晚一帧**到的（地址栏是 NSViewRepresentable，同步置位会报 "Publishing changes from within view
  updates"，所以当初跳了一帧）✓ —— 于是"点进去马上打字"时，这一帧的播种把刚打的字**覆盖回 URL** ✓；
  紧接着候选浮层因为失焦而收起 ✓（看起来就是"闪一下"）✓；"有网址时输入不出候选"同样出在这里
  （缓冲被重置成 URL，模型自然不会为"你打的那串"给候选）✓。
  - 修法：**聚焦不再播种** ✓；并给"失焦"通知加了真实状态校验（跳一帧后 field editor 还在 = 仍在
    编辑中，不报失焦）✓。
  - **实测**：有 URL 时 ⌘L 聚焦 + 输入 → 字段保住输入、候选浮层弹出 ✓；桥 `/suggest` 确认模型对
    `abc` / `127.0.0.1:8877` / `github` 都给出候选（URL 形态给 navigate + history）✓。

- **请求日志提到 info 级、且不再只在 DEBUG 里**（2026-09-23 一次真实排查的教训）：同一天里
  出现"任何输入都得到同一句回复"，真因是我测试用的**假端点还占着用户网关的端口**
  （`/tmp/fake_leak.py` 监听 127.0.0.1:8889，而 `amd` 档案正指向那里）—— 应用侧其实每一轮都打了
  `AI request — endpoint: …`，但那行在 `#if DEBUG` 里且是 debug 级，**统一日志默认不持久化
  debug**，事后查不到，只能靠翻会话文件 + 进程列表反推 ✓。现在这行（端点 + 模型 + 条数 + 工具数）
  是 info 级、Release 也会打 ✓；请求体 dump 仍留在 DEBUG ✓。

- **消息操作按钮压住正文**（用户反馈："这几个按钮 应该放在消息下面，现在遮挡住了"）：
  👍/👎/复制那一排原本是气泡的 `.overlay(alignment: .topTrailing)` 再 `offset(x: 6, y: -6)` ✓
  —— 贴在气泡右上角**外侧**，短消息时正好压住正文第一行（长消息盖住的是空白，所以只有短回答
  才看得出来）✓。
  - 现在改成**气泡下方的独立一行** ✓，并且**位置与宽度一直占着**（`opacity` 切换显隐，不是
    `if`）：鼠标扫过时下面的消息不会跳、复制按钮也不会在 hover 时左右横移 ✓；
    只在有正文且非报错时出现（报错气泡没有可复制/可评价的答案）✓。
  - 第二轮（用户："不应该分两侧吧"）：第一版行里有 `Spacer`，被撑到面板宽度 → 按钮跑到
    **右缘**、和消息分家 ✓。改成**贴气泡左缘**（顶对齐、不撑宽）✓。
  - 实测（假端点造一条短回答后整窗截图，并把操作行临时设为常显以便拍摄）：正文干净、
    按钮就在气泡正下方左缘 ✓。

- **脱敏代码把应用打成了"僵尸"：主 actor 永久卡死，界面却照旧**（排查"桥端点忽然没响应"时
  挖到底）：`SecretRedactor` 的 `NSRange` 在循环**外**算了一次 ✓，而循环里每次都改写文本
  （`[redacted]` 比任何命中都短 → 串必然变短 ✓）—— 下一轮 `firstMatch` 带着**越界**的旧范围
  调用 Foundation ✓，直接抛 `NSRangeException` ✓。异常从 Swift async 帧里穿出去（工具结果
  入会话这条路径 ✓），被 HIServices 的处理器吞掉 ✓，**主 actor 的执行器就此损坏**：此后所有
  `@MainActor` 任务只是排队、永不执行 ✓ —— 桥端点全部无响应（连 `/state` 都挂）✓、数据文件
  停在出事那一秒 ✓，但窗口照常渲染、AppKit 事件循环照常、**甚至还能被 `osascript quit`
  优雅退出** ✓，所以看起来完全不像崩了（没有崩溃报告 ✓，只有 `log` 里那行 NSRangeException）。
  - 修法：`NSRange` **每轮重算**、现算现用 ✓；并审计了全仓另外两处正则
    （`MarkdownRendererView` / `DevToolsPanel`）—— 都是现算现用 ✓，只有这一处踩了。
  - **独立复现** ✓：同一段逻辑喂 `sk-…` + `Bearer …`，旧写法报
    `NSRangeException: … Range or index out of bounds` ✓、新写法干净通过 ✓。
  - 这是同一天里**第二例**"陈旧索引/范围"类 bug（第一例是消息渲染的 AttributedString
    失效索引），已把规矩写进 AGENTS.md ✓。

- **回合结束不落盘：最后一条回答只活在内存里**（排查上面那条时顺带发现）：`runTurn` 在
  "模型给出最终回答"（本轮没有工具调用）时是 `guard … else { return }` **直接返回**的 ✓，
  而**保存**只挂在"执行过工具""迭代到上限"等分支上 ✓ —— 于是回答得等用户再发一条消息
  才被顺带写下 ✓。两个可见后果：**轨迹（读盘渲染）里 `answer` 永远是空的** ✓、强杀进程
  即丢这条回答 ✓。
  - 修法：回合序列结束后**无条件保存一次** ✓（覆盖 `runTurn` 的每条退出路径：最终回答 /
    报错 / 迭代上限 / 取消）✓；并把脱敏兜底**提到保存之前** ✓ —— 否则标题生成与记忆整理
    那几个额外模型调用（要跑好几秒）期间，带原文的回答会躺在会话文件里 ✓。
  - **实测**：同一轮现在落盘 4 条（含回答）✓、轨迹 `answer` 有值且已脱敏 ✓。

- **侧边栏打开 Agent 时绿灯一直闪**（用户反馈："侧边栏打开 agent 这绿点 闪动"）：两处叠加
  ——① `AgentHeaderView` 在 `.onAppear` 里**无条件**把 `isDotPulsing` 置真，于是 `Ready`
  状态下绿灯也在脉动；② 脉动用 `.animation(.repeatForever, value:)` 实现，而打开面板时的
  频繁重绘（布局/滚动/task）会**不断重启动画**，看起来就是"闪动"。
  现在**只有真的在忙时才脉动**（绿色/灰色状态点是静态的），并且脉动改由 `TimelineView`
  按**时间**算——纯时间函数，重绘打断不了；不忙时那个分支根本不存在（连计时器都没有）。
- **地址栏聚焦时刷的 3 条运行时警告 —— 这次真修掉了**（用户第一次贴出后我修过一版，
  **没修对**，第二次贴出才挖到根因）：`AddressSuggestionsModel:125/126` 的 "Publishing changes…"
  与 `URLBarField` 的 "Modifying state during view update" 是**同一条链**，根因不是 delegate，
  而是 `updateNSView` 里**同步**调用 `becomeFirstResponder()`：
  ① 它装好 field editor 并把控件内容灌进去时会**同步**发 `controlTextDidChange` —— 这个通知
  **不在** `isSyncingFromSwiftUI` 标志的覆盖范围里（那只挡得住显式 `stringValue` 赋值那一次），
  于是 `parent.text = newValue` 与随之而来的 `AddressSuggestionsModel.build`（两次 publish）
  全落在更新事务内部；② 同一调用还会同步进输入法/文本系统的 IPC，Xcode 的 Performance
  Diagnostics 因此报 **"Hang Risk: User-interactive QoS 线程等待 Default QoS 线程"**
  （`URLBarField.swift` 的 `becomeFirstResponder` 那行）。
  **修法**：把这次聚焦**跳一帧**再做（`Coordinator.focusField()`，并校验"已有 field editor
  就别重复夺焦"）—— 三条警告 + 一条 Hang Risk 一起消失 ✓。第一版只把"系统发的编辑通知"
  跳帧、却没动这个同步调用，所以警告照旧（教训：**先定位"谁在更新事务里写状态"，再谈怎么挡**）。
  另：这三条是 Xcode 的运行时问题通道（统一日志里没有，`log show` 查不到），验证要靠 Xcode 的
  issue 列表 ✓。

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
