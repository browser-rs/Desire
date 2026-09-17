# Desire 功能实测报告（第一轮，2026-09-17）

测试方式：Debug 构建启动 + AppleScript UI 自动化（键盘注入）+ 截图比对。
已覆盖：启动、新标签页、地址栏导航。未覆盖：Agent 面板、多窗口、下载、书签。

## 发现的问题

### BUG-A（高）：地址栏输入带 scheme 的网址 → 被交给系统打开
- 复现：⌘L → 输入 `https://example.com` → 回车
- 现象：弹出我们自己的 `confirmAndOpenExternalURL` 弹窗（"Desire 没有找到已注册处理此链接的应用：https://example.com"），页面白屏
- 疑点：`WebView.swift:597` 的 `!internalSchemes.contains(scheme)` 白名单里明明有 https
  （:667），静态分析无法解释。需插桩 decidePolicy 输出实际收到的
  url/scheme/navigationType/targetFrame 定位。

### BUG-B（高）：导航 example.com → 白屏
- 复现：⌘L → 输入 `example.com`（无 scheme）→ 回车
- 现象：页面全白。example.com 应渲染内容；错误页（ErrorPageView）也未出现。
- 待查：didFailProvisional 是否触发、lastError 是否为空、沙盒
  `com.apple.security.network.client` 授权、HTTPS-upgrade 循环。
- 佐证：新标签页的快捷拨号 favicon 能显示（可能来自磁盘缓存），不代表网络可用。

### ISSUE-C（低）：新标签页「最近访问」区域上缘有横贯全宽的虚线锯齿渲染伪影
- 截图 /tmp/desire_test2.png 可见。疑似虚线边框样式绘制宽度错误。

### ISSUE-D（中）：confirmAndOpenExternalURL 在导航委托里用 NSAlert.runModal()
- 模态阻塞主线程 + 阻塞导航委托；确认框应改为非模态（或至少
  dispatch 到下一次 runloop）。顺带在 BUG-A 修复时处理。

## 正常项
- 启动、窗口 chrome、新标签页布局、快捷拨号 + favicon、最近访问列表、
  ⌘L 聚焦地址栏、地址栏文字输入与回车提交链路（提交本身到达了导航层）。

## 下一轮计划
1. decidePolicy 插桩（Log.agent）→ 重跑复现 BUG-A，确定 scheme 实际值
2. 排查 BUG-B 网络失败原因（entitlements / lastError / 错误页显示条件）
3. 修 ISSUE-C 伪影、ISSUE-D 非模态化
4. 继续覆盖：Agent 面板开关、多标签、下载、书签/历史面板

## 第二轮实测更新（同日）

### BUG-B 重新定性 → 非缺陷（改为体验项）
- 用 baidu.com 实测：⌘L → 输入 → 回车 → **完整渲染成功**（logo/搜索框/
  热搜/标签页标题同步全对）。导航核心链路正常。
- example.com 白屏 = 该站在当前网络环境不可达（请求挂起超时）。
- **真问题（新增 ISSUE-E）**：加载挂起时零反馈 — 不转圈提示、不进错误页，
  用户以为浏览器坏了。需要：主文档加载超时（如 30s）→ 显示超时错误页；
  加载中至少有进度反馈（地址栏/标签已有 spinner，但白屏+spinner 组合
  误导性强）。

### BUG-A 未能复现 → 偶发，插桩已就位
- 同操作重试无弹窗。decidePolicy 入口 / 外部移交分支 / didFail 两处
  均已加 Log 插桩（WebView.swift），弹窗再现时日志可定位。

### ISSUE-C 重新定性 → 疑似截图工具跨空间混拍
- 多全屏 Space 环境下截屏捕获到了相邻空间的窗口边缘（其他应用窗口
  上同样存在虚线边缘）。真实使用中若 Desire 内可见该伪影，需用户提供
  截图确认。

### 新增待验证（ISSUE-F）
- 地址栏键入 desire://newtab 回车未跳转新标签页（按键可能被相邻空间
  的前台应用截走，需复测确认 scheme 导航是否生效）。

### 结论
核心浏览链路（解析→导航→渲染→标题同步）实测通过。待修：ISSUE-E
（加载超时反馈）、ISSUE-D（runModal 移出导航委托）、BUG-A 偶发观察。

## 第三轮更新（同日）

### ISSUE-E 已修复（代码完成，待人工验证）
- 主文档导航 30s 看门狗：decidePolicy 放行主帧导航时启动计时，
  didCommit/didFail/didFailProvisional 解除；超时注入
  URLError(.timedOut) → lastError 驱动 ErrorPageView 显示，并停止加载。
- 验证方法：重启应用 → ⌘L → 输入 example.com → 回车 → 等 30s，
  应出现超时错误页（不再无限白屏）。

### ISSUE-D 已修复
- confirmAndOpenExternalURL 改为 beginSheetModal（挂在 webview 窗口上），
  不再 runModal 阻塞主线程与导航委托；两处调用点传入发起 webview。

### 自动化环境结论
- 多全屏 Space 下 AppleScript 键盘注入 + 全屏截图不可靠（会切空间、
  可能误注入前台其他应用）——停止自动注入，后续验证以用户手工为准。
- 插桩日志保留（decidePolicy/外部移交/加载失败），BUG-A 再现时可用
  `log show --last 5m --predicate 'process == "Desire"'` 取证。

## 第四轮更新（同日，窗口级截图 + 前台门控后自动化恢复可靠）

### 通过项
- example.com 完整渲染（上轮白屏确认为瞬时网络抖动；30s 看门狗保留
  作为真挂起兜底）
- ⌘T 新标签：双标签并列正常，标签标题独立正确
- desire://newtab：成功回到新标签页（ISSUE-F 通过）
- 页面内文案/链接渲染正常

### 新发现 BUG-G（中）→ 已修复
- 历史条目标题记录为应用占位符"Desire"而非真实页面标题：WebKit 的
  标题 KVO 晚于 didFinish 到达。修复：HistoryStore.updateEntryTitle
  （按 URL 定位最新条目替换标题）+ onPageFinished 后 800ms 延迟校正。

### 环境备忘
- 窗口级截图（screencapture -l <winid>）+ Swift CGWindowList 取 ID
  可以稳定捕获 Desire 窗口，不受全屏 Space 切换影响。
- 坐标点击（System Events click at）落点有偏差，链接点击类用例暂缓。

### 未覆盖（后续轮次）
- Agent 面板实测（模型菜单/审批卡/排队/暂停）、下载流程、
  书签/历史面板、多窗口。

## 第五轮更新（同日）

### 通过项
- ⌘' 打开 Agent 面板：会话历史完整恢复（executeJS/downloadMedia 工具
  卡片带绿色结果标记、参数/结果可展开）
- 新输入栏布局实测正确：左侧 完全访问胶囊+附件+语音，右侧 模型胶囊
  （deepseek-v4.1-flash）+发送
- 模型胶囊显示当前模型名正确

### 新发现 ISSUE-H（中）→ 已修复
- 窄侧栏下快速操作条 5 个按钮被挤成一字一行（"Summarize"竖排）。
  修复：横向 ScrollView 包裹，超出可滚动。

### 遗留
- 消息发送回路（点击落点偏差，自动化无法可靠聚焦面板输入框）—
  留给用户手工验证：⌘' 打开面板 → 点输入框 → 发"1+1"→ 观察流式回复。
- 地址栏残留测试文本（1+1aaaaaaa），无害，可清空。

## 第六轮更新（同日，菜单栏驱动）

### 通过项
- 书签面板：搜索实时过滤正常（输入无匹配时显示"未找到匹配书签"空态）、
  面板结构完整（搜索/文件夹/条目/操作图标/关闭）。

### 新发现 ISSUE-I（低，待人工复核）
- 书签 popover 的"关闭"按钮辅助功能点击无效（System Events click 无
  反应）— 可能缺少 a11y 标注；Esc 也未关闭 popover。
- 菜单"文件 → 新建无痕标签页"点击后未见新标签出现 — 自动化点击
  SwiftUI 菜单项可能静默失败，需人工复核（点菜单后应出现深色无痕标签）。

### 环境结论（最终）
- 可靠通道：菜单栏点击（部分）、⌘快捷键、窗口级截图。
- 不可靠：坐标点击、popover 内交互、多 Space 键盘注入。
- 后续功能覆盖（下载流程/多窗口/无痕隔离验证）建议以人工清单方式执行。

## 第七轮：自动化 CLI 桥（应"开发成 cli 方便测试"需求落地）

新增 `Desire/App/AutomationServer.swift`：仅绑定 127.0.0.1:8799 的
JSON HTTP 服务，`--automation` 启动参数门控（默认关闭）。curl 全流程
实测通过：

- `/state` `/tabs` — 标签枚举（index/title/url/incognito/selected）✅
- `/navigate {"url":"baidu.com"}` — 走统一 URLResolution 解析 ✅
- `/page/text` `/page/url` — 内容与标题提取 ✅（百度文本完整）
- `/new-tab {"incognito":true}` + 无痕隔离 ✅（无痕导航不进历史）
- `/agent/send` + `/agent/messages` — Agent 完整回路 ✅（发"1+1等于几"
  → 回复"2"，provider/流式/会话全链路通）
- `/screenshot` — webview PNG 快照 ✅（写入容器目录，外部可读）

### 附带发现
- 应用实际运行在沙盒容器中（NSHomeDirectory → Containers/me.siwi.Desire）
  — entitlements 文件注释声称沙盒已移除，与运行时不符，runCommand 类
  功能的真实权限面需要单独核实（ISSUE-J）。
- 30s 超时看门狗、无痕历史隔离两项此前修复在本轮回归验证通过。

### 用法
    open .../Desire.app --args --automation
    curl -s http://127.0.0.1:8799/state
    curl -s -X POST http://127.0.0.1:8799/navigate -d '{"url":"baidu.com"}'
    curl -s http://127.0.0.1:8799/screenshot

## 第八轮：ISSUE-J 定案 — 沙盒由 provisioning profile 强制

实验闭环：
1. codesign 实测产物 → app-sandbox=true（entitlements 文件却是空的）
2. touch 文件 + 增量重构建 → 仍沙盒（排除签名缓存）
3. clean 全量构建 → 仍沙盒（排除增量 quirk）
4. 在文件加 marker key 构建 → **直接失败**："Entitlement
   com.desire.test-marker not found and could not be included in
   profile" — 构建走 provisioning profile 合成，profile 的固定
   entitlement 集合里含 app-sandbox，且拒绝未知 key。
5. 手动 ad-hoc 重签（绕过 profile）→ 沙盒消失（验证文件内容本身无沙盒）。

**结论**：只改 entitlements 文件无法移除沙盒。要移除需在 Xcode →
Signing & Capabilities 删除 App Sandbox capability 并让 Xcode 重新
生成 profile（需开发者账号交互，CLI 不可安全替代）。

**影响面**：沙盒下 runCommand spawn /opt/homebrew 二进制会被拒，
agent 的系统工具能力名存实亡；webview/下载/网络不受影响（有
network client/server entitlement）。这解释了为何 agent host 设计
要求移除沙盒——此修复优先级应视为高。

## 第九轮：CLI 驱动回归（全绿）

- 多标签：bilibili 标题同步 ✅、switch-tab ✅、reload ✅
- 超时看门狗修复回归：10.255.255.1 挂起 33s → error 变为
  NSURLError -1001 timed out（-999 覆盖已抑制）✅；并发现
  takeSnapshot 拍不到 SwiftUI 错误页（快照仅含 webview 内容）——
  错误页验证需走 error 字段而非截图
- **Agent 自主工具回路端到端 ✅**：指令"打开 bilibili 并告诉我标题"
  → 自主 navigate → getPageTitle → 汇报，全程无人工干预
- /back /forward 边界：单条历史时正确报 cannot go back/forward ✅

### 累计修复（本轮会话）
P0×4、流式节流、并行子代理、定时任务、暂停恢复、用量统计、
MCP 鉴权、快捷键多窗口隔离、webview 泄漏、会话恢复、缩放泄漏、
无痕身份、加载超时看门狗、历史标题校正、快速操作条、模型菜单、
输入栏两行布局、自动化 CLI 桥。

## 第十轮：沙盒移除完成 + spawn 验证

用户在 Xcode 删除 App Sandbox capability 后：
- 重建签名 app-sandbox=0，仅剩 get-task-allow ✅
- **/spawn-test 端点（新增）**：进程内直接 spawn /usr/bin/python3 →
  "spawn-ok" ✅ — runCommand 的系统工具能力恢复
- NSHomeDirectory 回到真实 /Users/mankong（截图路径验证）✅

### 新增端点
- GET /spawn-test — 无 LLM 依赖的 spawn 探针
- GET /downloads — 下载列表（filename/state/paused/bytes；经
  DownloadStore.live 弱注册读活实例）

### 回归
- T1 搜索解析："hello world" → 百度搜索 URL，标题同步 ✅
- T2 localhost:8799 直达 ✅
- Agent 回路 401：沙盒→非沙盒的 Keychain 域切换，旧 key 读取路径
  失效 — 用户需在设置里重新保存一次 API key（预期行为，非缺陷）。

## 第十一轮：审批自动化 + 语音权限懒请求

- 崩溃定案与修复：VoiceInputManager 在面板 init 时就发起语音/麦克风
  TCC 授权（非标准启动方式下 bundle 解析失败被 TCC 击杀）。
  改为权限状态仅查询、首次点麦克风才请求。
- 桥新增审批自动化：GET /approvals（挂起审批详情）+
  POST /approvals/resolve {"decision": "allow_once|always_allow|deny"}。
- 实测全自动危险工具回路：agent 发 runCommand → /approvals 读到
  挂起审批（python3 -c print(11*11)，risk: Runs code）→ CLI
  allow_once → 命令执行 stdout 121 → agent 汇报。零人工干预 ✅
- BUG-K 记录：优雅退出曾出现挂起（SIGTERM 后进程卡 exit，SIGKILL
  亦无法立即终止，STAT=SX）——怀疑与挂起的网络会话/审批 continuation
  相关，低频复现，保留观察。

## 第十二轮：MCP 端到端 + 下载 E2E（CLI 驱动全绿）

### MCP 端到端 ✅（首次实测）
- 自建最小 MCP 测试服务器（Streamable HTTP，tools: echo/add）+
  注入 DiskStore 配置（mcp-servers.json）→ 应用启动自动连接
  （"ready · 2 tools"）
- Agent 端到端：指令"用 MCP 工具 echo 发送 hello from desire" →
  自主调用桥接工具 mcp_desire_test_echo → 返回 "echo: hello from
  desire" → Agent 原样汇报。配置加载/连接/工具桥接/审批/执行/汇报
  全链路通。

### 下载 E2E ✅
- 本地 http.server 提供 test.zip → /navigate → canShowMIMEType=false
  触发下载策略 → /downloads 显示 completed 195/195 → 文件落盘
  ~/Downloads 且内容校验通过。

### 桥新增
- GET /mcp — 服务器状态 + 桥接工具清单
- GET /downloads — 下载列表（需先加 DownloadStore.live 弱注册）

## 第十三轮：回归套件落地 + loopback HTTPS 升级修复

### 新增 tools/regression.py — 一条命令跑全套回归（13 用例）
脚本自包含：写 MCP 配置、起本地 MCP/文件测试服务器、带 --automation
重启应用、跑 13 个用例、PASS/FAIL 汇总。覆盖：基线状态、搜索解析、
本地页加载、页面文本、MCP 就绪、Agent MCP 工具、审批浮现+自动批准、
runCommand 结果、下载完成、无痕隔离、无痕标记、截图、后退导航。

### 修复：HTTPS 升级误伤 loopback（真产品 bug）
http://127.0.0.1/localhost 被强制升级 https 后打到无 TLS 的本地服务
（开发服务器场景！）→ TLS 握手挂死 → 永久 isLoading + 白屏。现在
loopback 主机永不被升级。本地开发场景恢复正常。

### 诊断端点
GET /settings — 应用视角的配置可见性（searchEngine 等），用于排查
"设置丢失"类问题（本轮证实搜索解析失败是时序竞态而非配置丢失）。

### 结果：13/13 PASS（含此前所有修复的回归）

## 第十三轮补充：Agent DOM 交互端到端 ✅

本地测试页（输入框+按钮+JS 结果区）→ 指令"填入 Alice 并点击提交"。
Agent 全自主完成：页面快照 → 发现 8000 端口页面 404 → 自主导航修复 →
getPageSnapshot/findElements/executeJS/clickAt/click 多工具组合 →
executeJS 读回 `name=[Alice] result=[hello Alice]` → 汇报
"result 区域显示：hello Alice"。

经验教训：测试服务器端口 8000 与本机常见开发端口冲突 → 套件改用
8877；给 Agent 的指令应避免端口/地址歧义（它记得旧地址会自主绕路，
恢复力很好但耗时）。

## 第十四轮：多步真实任务基准 + executeJS 异常详情

### 多步真实网页任务 ✅
"百度搜索 Swift Concurrency → 打开第一个结果 → 汇报标题和概括"：
百度搜索 → 结果一是 docs.swift.org 重定向页 → click e1/text 两次失败
→ **自主改用 getPageSnapshot 重读新 URL** → updatePlan 全程 4/4 →
准确汇报标题（Concurrency | Documentation）+ 一句话概括。弹性优秀。

### 修复：executeJS 异常无详情
- evaluateJavaScript 的 JS 异常错误对象不含具体异常文本（WebKit
  限制，WKJSExceptionMessage 这个 key 不存在——正确的是
  **WKJavaScriptExceptionMessage**，经临时 userInfo dump 实证）。
- executeJS 失败时用 callAsyncJavaScript 重跑一次以捕获真实异常
  （marker-42 实测返回）。Agent 调试 JS 时不再两眼一抹黑。

## 第十五轮：性能计时端点 + lastError 残留修复

### 新增 GET /page/timing
返回 Navigation Timing（ttfb / domContentLoaded / load / transferBytes /
protocol）。注意：需在 didFinish 后读取（导航刚提交时新 entry 尚未
填充）；实测受网络波动影响大，作基线采集用。

### 修复：lastError 残留（真 bug）
新导航 didStartProvisional 时未清空上一次的 lastError → 前一次的
失败错误页会错误地覆盖**加载成功的新页面**（本轮实测复现：baidu 连接
失败错误页残留到了后续本地页导航上）。已在导航开始时清空。

### 网络波动记录
本轮 example.com 白屏、baidu 间歇性 Could not connect 均为测试环境
网络抖动，与浏览器无关（恢复后自动正常）。此类"假阳性"测试结论
必须通过 CLI 复测两次以上才能定性。

## 响应式模式改造 · 第一轮（核心可用性）

体检结论（为何"几乎无法使用"）：
1. 进入响应式模式只缩放了 webview 尺寸，**不换 UA、不重载** — 站点按
   桌面 UA 继续 Layout，看到的只是"桌面版窄窗口"，不是移动版布局。
2. 设备高度超过窗口时 min() 裁剪导致比例失真。
3. TouchSimulation：identifier 用 Date.now() 会重复；退出时只设 flag
   不移除监听与全局 CSS → 页面**永久无法选中文字**。
4. 尺寸输入框与拖把手互不同步（各自 @State）。

本轮修复：
- **ResponsiveModeApplier**（新文件，统一入口）：启用时按视口宽度换
  真 iOS Safari UA（<500 iPhone / <1200 iPad / 其余保持桌面）并重载；
  退出恢复桌面 UA + 重载 + 清理触摸层。SelectedTabContent 的
  onChange(isEnabled) 是唯一漏斗 — 菜单/工具栏/Agent 工具全部生效。
- **TouchSimulation 重写**：自增 identifier；全部监听/样式挂到
  __desireTouchSim 注册表，remove 时逐一摘除（含 style 标记）；补充
  ripple 动画替换旧 CSS animation（旧动画样式永不清理）。
- **尺寸输入直绑 config**（去掉本地 @State 双份状态），选预设时同步
  custom 字段 — 输入框与拖把手不再互相覆盖。

验证：构建零警告。实机验证项（用户）：开启 iPhone 14 Pro 预设访问
baidu.com 应出现移动版布局；退出后恢复桌面版；开关触摸模拟后文字
选择不受影响。

## 响应式模式改造 · 第二轮（Bar 溢出 / 假节流 / 旋转 UA）

- **假节流移除**：节流按钮循环 None/Slow 3G/Fast 3G/Offline，但
  WebKit 没有节流 API，从未实现 — 纯摆设误导用户。按钮移除
  （config 字段保留兼容旧存储）。真节流需 Network Interception
  （未来评估）。
- **Bar 溢出**：整行控件包横向 ScrollView，窄窗口下可滚动不再截断。
- **旋转 UA 误切修复**：UA 分类改用设备**短边**（手机横屏仍是手机）；
  新增 onChange(effectiveSize) 实时更新 UA（不 reload，影响后续请求）。

## 响应式模式改造 · 第三轮

- **错误页入视口**：加载失败时错误页此前铺满整个窗口（盖过 390pt 的
  手机框）。响应式模式下错误页现在渲染在设备视口内（圆角裁剪），
  非响应式路径不变。
- **MediaQueryInspector 宽度所有权**：内部固定 220 移除，交由
  HSplitView（180/220/360）— 与其他面板一致，分隔线可拖。
- MediaQuery 实时性复核：刷新已挂钩 effectiveSize 变化（拖把手/
  旋转都会触发），页面静止时的 matchMedia 状态本就不变 — 无需改。
