## [Unreleased]

### Changed

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

### Fixed

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

### Changed

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

### Fixed

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

### Changed

- 原生窗口全屏（⌃⌘F）收起浏览器 chrome（标签栏/工具栏/进度条/书签栏），
  内容铺满整屏，与 Safari/Chrome 全屏一致。
- 新增自动化端点 `GET /diag/geometry`（webview 与各窗口的 frame / styleMask /
  全屏状态 / 所在屏幕 / 子视图树），用于全屏与面板类几何问题的无截图排查。


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
