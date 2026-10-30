## [Unreleased]
### Changed

- Agent: page observations are reused within the same turn (same tab, same settings, 8s window) instead of re-serializing the DOM; side-effect actions invalidate the cache and `refresh:true` forces a fresh read (v0.8.25)

### Fixed

- **YouTube 详情页「暂停再播放」修复（v0.8.25）**：自动播策略纠正从 `didFinish`（页面已开始播放）提前到 `decidePolicyFor`（导航提交前 cancel → 带 allowAll 策略重开 → 再加载）——首次直达视频详情页不再"播一秒 → 换 webview → 重播"。保留 didFinish 兜底（站点策略会话中途变化时仍会纠正）。实测：空白标签直达 watch 页只出现 `pre-rebake before commit`，9 秒后 `paused=false / t=6.37 / 无广告`，连续播放。

### Added

- **Agent 可靠性·第一批（v0.8.25）**：**动作后自动核验**——副作用动作（click/type/fill/navigate 等）执行前后各取一次页面指纹（URL/标题/正文长度/节点数），最多等 1 秒观察变化，给工具结果追加 `[verify] navigated|changed|unchanged`（动作没生效不再"看起来成功"）；**接管锁下沉到标签级**——Peek 只锁用户正在看的那一页，同窗其他标签 Agent 仍可操作（工具按 index/选中标签解析锁），`/peek` 与 `/diag/windows` 的 locked 计数含标签锁。harness 1882/0；mode-smoke 8/8 复跑通过。
- **Agent 登录态引导（v0.8.25）**：导航/点击等动作后检测页面是否有密码输入框；有则在工具结果追加 `[hint]`——可以调用 `requestUserHelp` 让用户通过 Peek 自己登录，或建议用 `/cookies/seed` 导入当前档案的 cookies；并明确"不要自己输入密码"。实测：本地登录页检测为 true、普通页为 false；harness 1884/0。
- **接管回放摘要（v0.8.25）**：Peek 展开时在目标页注入轻量记录器——点击元素文字、输入字段名、跳转标题（**不记输入值**，上限 60 条）；用户「完成/忽略」时读取并去重格式化为一行，作为第二条系统备注 `Peek actions observed: …` 交还 Agent——接管期间"页面变了"变成"用户在密码框输入、点了登录、跳到了首页"。harness 1888/0；fixture 实测点击/输入/跳转三类事件均被记录、输入只留字段名。
- **站点数据管理 2.0（v0.8.25）**：新增 `SiteDataManager` 与桥端点——`GET /site-data`（按站点列出数据类型，`container` 可指定容器）、`POST /site-data/remove`（按站点 × 类型清除：cookies/cache/localstorage/indexeddb 等，缺省全清）。替代此前"按保留天数清理"的撤项方案：WebKit 记录级删除不带时间，按站点点名才安全。实测：临时容器 51 条记录 → 删除某站 cookies 后 50 条，其他站点不受影响。
- 站点数据管理 UI 接线（v0.8.25）：设置 ▸ 隐私 ▸ 网站数据 每行新增「按类型清除」菜单——可以只删 Cookie 保留本地存储，或只删某一类；垃圾桶按钮仍是一键全清。统一走 `SiteDataManager` 的口径（与桥端点同一实现）。
- **观测节流（v0.8.25）**：Peek 浮层的页面快照轮询（2 秒）在应用失活或浮层不可见时自动暂停，回到前台/可见时续上——后台不空转 CPU。
- **worker 级隔离（v0.8.25）**：`crewDispatch` 新增 `isolation` 参数——`crew`（默认，整组共享一个临时容器）或 `worker`（每个 worker 独立临时容器，并行任务互不共享 cookie）；落定后逐个擦除并删容器。持久容器单写者约束不变。
- **隔离默认值首启引导（v0.8.25）**：首次切到专注/混合模式的一次性说明里直接给出选择——「隔离容器（推荐）」或「沿用我的登录态」，选中即写入设置（之后可在 设置 › 使用模式 改），不再只是读一段说明。
- **历史洞察（v0.8.25）**：新增纯逻辑 `HistoryInsightsBuilder`（总访问/站点数/Top 站点/24 小时分布/最近 7 天，`www.` 归一、同分按 host 排序）与桥 `GET /history/insights`——面板 UI 随后接线，数据口径已与桥同源。harness 1896/0。
- History: insights sheet (top sites, 24-hour distribution, last 7 days) opened from the panel header, sharing the same derived numbers as `/history/insights` (v0.8.25)
- Downloads: search by name or site + status filter (active/paused/completed/failed), failure count in the summary bar and "Copy Error" on failed rows (v0.8.25)
- Reading list: tags with filter chips, an editor sheet and a bridge endpoint (`/reading-list/tags`); tags travel in the existing sync payload (legacy clients keep local tags) (v0.8.25)
- Bookmarks: multi-select actions — move selected items into a folder (root included) and batch add/remove/replace tags, with a subtree guard against moving a folder into itself (v0.8.25)
- Agent: tool-level checkpoint resume — after an interrupted turn, read-only tool calls that never produced a result are re-run and their real output lands in the conversation instead of a generic "[interrupted]"; `/agent/resume` reports pending/replayable/replayed counts (v0.8.25)
- Trace page: one-click re-run for failed or denied steps with their original arguments — the result is appended as a fresh assistant+tool pair and the agent continues; also exposed as `POST /agent/rerun-step` (v0.8.25)
















## [v0.8.24] - 2026-10-30
### Added

- **模式收口·第一批（v0.8.24）**：混合模式 **Peek 浮层**——非激活 NSPanel + 每 2 秒页面快照 + 去处理/完成/忽略，默认不抢焦点（点击才激活 Agent 窗口），目标面锁定与前后页面对比沿用 PeekCenter；**专注面板升级为可用浏览器**——地址栏（URL/搜索）、前进/后退/刷新/停止、关闭标签，Peek 接管时能真正完成登录/验证码；新增**会话 → NSWindow 弱注册表**——`/diag/windows` 与 Peek"去处理"在新标签页（无 webview）也能定位窗口；**Agent 窗口标题**"Agent 工作台"（随窗口挂载校正，SwiftUI 重设后自动补回）；Mode 菜单加「打开 Agent 窗口」。
- **模式收口·第二批（v0.8.24）**：专注模式下 routine 通知一律进摘要（紧急仍直推，不再打断工作台）；关窗语义——专注模式关掉最后一扇窗口自动降级 browser（避免下次启动"浏览器不见了"）；新增 `WindowTargetResolver` 统一目标解析（专注→面板、混合→Agent 窗、浏览器→活动窗），Peek/工具面/开窗逻辑改走它；新增 `tests/mode-smoke.py` 桥级冒烟（模式往返/面板存在/用户窗与 key 不变/Peek 锁定与恢复，`--hybrid` 额外验证开窗）。
- **隔离与登录·第三批（v0.8.24）**：新增**一次性读** `POST /page/read-ephemeral`——用内存数据存储离屏取文（不碰用户 cookie/会话，也不复用已登录标签），适合不可信/一次性页面；新增**登录态快照** `POST /cookies/seed`——把本机 cookies 拷进指定容器（默认 Agent），并如实说明 localStorage/IndexedDB 不迁移、部分站点仍需重登；新增 `POST /containers/remove`（清空并删除容器，便于运维与测试收尾）；设置页「沿用当前登录态」改为**二次确认**（明确写出 Agent 将能看到所有已登录站点）。crew 的任务级隔离沿用既有 `isolated`（临时容器、落定即擦除）。实测：一次性读命中本地 fixture、243 条 cookie 快照进临时容器并成功清除（未触碰默认档案）。
- **模式收口·第四批（v0.8.24）**：设置页新增「一览」对比表（界面/浏览器位置/登录态/打扰方式 × 三模式，一眼看懂差别）；菜单 **Mode → 并排显示**（只调两窗 frame 平铺左右，不做应用内分屏）；新增用户文档 `docs/USAGE-MODES.md`（三模式速查、登录态四种策略、接管锁报错含义、重启恢复规则与常见问题）。





## [v0.8.23] - 2026-10-30
### Added

- **使用模式·第一批（v0.8.23）**：三模式地基——`AppUsageMode`（browser / agentFocus / hybrid）持久化 + 设置页「使用模式」+ 菜单 Mode（⌃⌘1/2/3）+ 桥 `GET/POST /app/mode`；**窗口角色注册表**（`window-roles`，sessionKey → user/agent/agentPane，随盘持久化）与收养过滤（用户窗口不再把 Agent/面板会话当成"上次会话"，孤儿清理也不归档它们）；混合模式自动补开 Agent 窗口（独立会话 + Agent 专用容器，Tab 继承容器落盘、重启按角色恢复）；专注模式单窗工作台（对话 + 可折叠内嵌浏览面板；面板是独立 TabManager，折叠时 webview 仍在后台可导航/取文/执行 JS——S1/S2 spike 验证）；`GET /diag/windows` 暴露角色/容器/选中 URL/key 供模式 E2E。实测：混合模式自动开 Agent 窗、角色与容器落盘、三种重启路径（browser / agentFocus / hybrid）均按角色恢复、用户窗未被 Agent 会话收养；50 次面板挂载无崩溃。下一批：Peek 协议、接管锁、工具目标规则细化。
- **使用模式·第二批（v0.8.23）**：**Peek 协议**——Agent 用 `requestUserHelp` 请求人工（登录/验证码/看一眼），立刻返回请求 id、回合继续；专注模式在工作台就地展开浏览面板 + 横幅（原因/完成/忽略），完成后自动收回；把"页面前后是否变化（URL）"写成系统备注交还模型；桥 `GET/POST /peek`（request/open/resolve/dismiss）。**接管锁**——Peek 期间该浏览面的 Agent 工具返回明确 `Error: surface is being used by the user`，`/diag/windows` 暴露 `locked`。**工具目标规则**——专注模式指向内嵌面板；混合模式下**用户窗口的 Agent 会话默认作用于 Agent 角色窗口**（包装型 ToolSurface 只替换 tabManager，其余依赖转发）。**焦点修复**——`newWindow` 在专注模式禁用，不再为建窗抢焦点。实测：request→open→locked→resolve→系统备注全链通过。
- **使用模式·第三批前半（v0.8.23）**：模式切换**不打断在跑回合**——回合进行中切模式只记下目标，回合结束再重配工具面（避免后续工具打到另一个浏览面）；工作台迷你条显示面板当前页标题与后台标签数；**拖 URL/文本进页面**（Safari 语义）——页面自己没接住时，链接开新标签、纯文本按默认引擎搜索（页面内的拖放/上传仍由 WebKit 优先处理）。
- **使用模式·第三批后半（v0.8.23）**：Mode 菜单改为**单选对勾**（⌃⌘1/2/3）；首次切到非浏览器模式弹一次说明（界面与打扰边界，避免"切了不知道发生了什么"）；新增**登录态策略**设置——默认独立 Agent 容器（隔离优先），可切「沿用当前登录态」（Agent 窗口/面板改用本机档案，新窗口生效；便利优先、隔离性更弱）。工作台迷你条显示当前面板页标题。
- **审批卡「看现场」（v0.8.23）**：审批条新增 Show Page——专注模式直接展开 Agent 的浏览面板再决定放行（不额外发通知；展开即接管锁生效），减少"盲批"。混合/浏览器模式下页面本来就在眼前，按钮等价于无操作。






## [v0.8.22] - 2026-10-30
### Fixed

- **拖文件进浏览器（v0.8.22）**：此前只有起始页能拖入文件——SwiftUI 的 `dropDestination` 挂在容器上，但网页内容是 WKWebView（AppKit 视图），拖放事件被它先吃掉；而且旧行为是"首个文件塞进当前标签"。现在：① 网页区域也能拖入文件，一律**开新标签**（继承来源标签的隐私/容器身份，查看器路由照旧：PDF/表格/图片/压缩包/文档；多文件首个前台、其余后台）；② **网页自己的拖放优先**——`WKWebView.draggingEntered` 表示页面接得住（file input / JS drop zone）时完全交还 WebKit，上传与拖拽排序不受影响，只有它拒绝的落点才由宿主接管；③ WebKit 若试图把拖入文件导航进当前页，按 URL 精确拦截（3 秒窗口、只认刚拖入的文件）改开新标签；④ 起始页提示改为"松开在新标签页打开"。

### Changed

- Spotlight 索引补可观测面：新增 `GET /spotlight/status`（enabled / 最近投递条数 / 最近错误）与 `POST /spotlight/rebuild`——索引失败不再静默；实测本机投递 445 条、无错误。

### Added

- **端上语义索引（v0.8.22 批一）**：把历史正文 / 书签 / 摘录 / 阅读高亮（Agent 会话默认关、可显式开启）切成条目做本地向量索引——中文走 bge-small-zh（查询侧带官方指令前缀）、英文走系统 NLEmbedding 句向量，按「来源 × 语言」分片落盘（原子写 + json 提交标记 + 内容哈希增量复用，模型换了自动重嵌）；设置新增「搜索与索引」：总开关、逐源开关、条数/体积/最近构建、重建与清空；桥新增 `GET /index/status`、`POST /index/rebuild|clear`、`GET /search/semantic`（含 minScore 诊断覆盖）。标定见 docs/SEMANTIC-INDEX-SPIKE.md：英文同义改写命中 0.52 / 无关 ≤0.36（阈值 0.38），中文改写 0.431 / 无关 0.364（阈值 0.40）；导航型短标题（如 "GitHub"）不入索引——实测它们对无关查询也能到 0.48，阈值分不开而字面搜索本就够用。索引只在本机，不同步、不进备份；harness 1837/0。
- **语义检索接入日常入口（v0.8.22 批二）**：⌘⇧F 集中搜索新增档位（智能/字面/语义，选择记忆）——智能档字面优先、语义补位（按来源去重、最多 8 条），语义档按相关度列出（含阅读高亮与会话命中，会话命中跳转并高亮那一轮）；摘录/书签/高亮行的右键"查找相关"弹出跨源近邻小窗（点一条在应用内打开来源，避开同窗口多 sheet 限制）；地址栏在字面候选只有"打开/搜索"一行时补最多 4 条"相关页面/摘录"（异步、可取消，索引关闭时自然为空）。记忆事实作为搜索源顺延（需要 Agent 窗口记忆页的深链，单列一批做，不半接）。
- **跨标签上下文（v0.8.22 批三）**：新增 `summarizeTabs`（后台逐页取文——已开标签直接借 webview 含登录态——逐页 1-2 句 + 总览，`[n]` 引用；立刻返回、完成写会话备注与通知，`GET /tabs/digest` 可查）与 `askTabs`（把问题交给打开的标签页回答，答案带 `[n]` 来源编号；一次旁路模型调用，上下文封顶 4 万字符）；桥新增 `POST /tabs/digest`、`GET /tabs/digest`、`POST /tabs/ask`。编号/拼装/封顶抽成 `TabDigestCore` 进 harness（1844/0）。输入框 `@` 标签引用顺延到下一批（需要输入框光标插入与 `<tab_refs>` 层，单列做）。
- **系统存在感（v0.8.22 批四）**：Spotlight 索引历史/书签/摘录——标识内嵌 URL，点结果直接回应用打开（冷启动也成立）；设置页新增「系统集成 › 加入 Spotlight 索引」开关，关掉即清空；数据源变更走 5 分钟防抖重建（复用语义索引的变更信号）。系统服务菜单两条（任意应用选中文本 → 收进摘录 / 打开链接；Info.plist NSServices + servicesProvider）。摘录右键新增系统分享。菜单栏快速入口新增「搜索」档：输入即查历史/书签/摘录前 5 条，回车在应用内打开（不唤起 Agent 回合；语义补位仍在 ⌘⇧F）。**Quick Look 一项撤项**：下载面板 0.7.19 已有内嵌 QLPreviewView 预览（Preview 动作），不重复实现。
- **收口（v0.8.22 批五）**：`searchConversations` 增加语义档（工具 `mode=semantic` + 桥 `GET /conversations/search?mode=semantic`）——按会话聚合去重、排除当前对话，索引关闭或未构建时给明确提示而不是静默空结果；阅读列表摘要链路把读到的正文顺手喂进（opt-in 的）历史正文索引，让"读过的长文"也能被字面/语义检索到。**同批其余项处置**：索引与存储自检并入新的「搜索与索引」设置页（各源条数/体积/最近构建/失败原因齐备，不另造诊断卡）；站点数据定期清理**撤项**——WebKit 的记录级删除不带修改时间、按保留天数只能整库清（会误伤登录态），不做会让人莫名退登录的功能；知识周报/复习队列/收件箱语义聚类同属"每日回顾"面，留待下一批统一设计 UI。
- **MCP 服务器补 Agent 对话面（编程工具 ↔ 浏览器 Agent）**：`--mcp-server`（8798，原有浏览器原语之外）新增 13 个工具——`askAgent`（发任务并等回合结束，返回回复/新增消息/超时态）、`getAgentMessages`、`getAgentTrace`、`getAgentStats`、`getAgentCost`、`getAgentBudget`/`setAgentBudget`、`getAgentDoctor`、`addAgentNote`、`setAgentDirective`、`rateAgentMessage`、`searchConversations`（字面/语义）、`semanticSearch`、`exportEval`；`serverInfo.version` 改为读 Bundle（原硬编码 0.2.12）。配套 `docs/MCP-SERVER.md`（Claude Code/Cursor/stdio 接入与"跑任务→看轨迹→下诊断→喂上下文→打标→导出 eval"闭环）与 `tools/desire-mcp-stdio.py` 垫片。实测：initialize / tools.list（53 个工具）/ listTabs / getAgentMessages 正常；`askAgent` 实跑一次往返 8.8s、回复正确（测试会话已删）。
- **Agent 工作自述与能力缺口（编程工具 ↔ Agent 改进闭环）**：新增 `reportCapabilityGap` 工具——Agent 遇到"没有这个能力/工具"时主动记录（capability/blocked/workaround/severity），系统提示词 `<tools>` 段已写入指引（先用替代方案、顺手记一条，不展示给用户）；`AgentGapStore` 按能力归一化去重累计、按被阻塞次数排序（上限 200，随盘持久化）。新增 `AgentWorkReportBuilder`（纯逻辑，harness 1862/0）：按用户消息切回合，逐回合派生 outcome（success/partial/failed）、步数、工具计数、`Error:` 原文、自评、验证与最终回答——全部从已落盘消息派生，不额外调模型。桥新增 `GET/POST /agent/gaps`、`POST /agent/gaps/clear`、`GET /agent/report`、`POST /agent/report/export`（Markdown：逐回合事实 + 缺口表，落 Agent 工作目录）。MCP 新增 5 个工具（getAgentReport / getAgentGaps / reportCapabilityGap / clearAgentGaps / exportWorkReport，共 58 个），docs/MCP-SERVER.md 补「Agent 自述」一节与消费示例。实测：缺口去重累计与严重度升级、报告端点、Markdown 导出均正常（测试数据已清）。
- **v0.8.22 收尾四件**：① **输入框 @ 标签引用**——输入 `@` 弹出当前窗口标签候选（↑/↓ 选择、回车附加，芯片可移除）；发送前把引用标签正文读成系统备注（`## Referenced tabs`，复用已开标签的登录态），不把大段正文写进聊天记录。② **知识周报**——本周摘录按端上向量贪心聚成主题（中文/英文分开聚），Markdown 落 Agent 工作目录 + routine 通知；桥 `POST /knowledge/weekly` 与 MCP `weeklyKnowledgeDigest`（确定性、零模型调用）。③ **复习队列**——摘录间隔重复（1/3/7/21/60 天五档：记得升档、忘了回第 1 档、跳过顺延一天），摘录面板「N due」入口 + 今日回顾 sheet；桥 `GET /review/queue`、`POST /review/grade|reset`。④ **收件箱按主题分组**——对当前条目做端上语义聚类（≥4 条才出现切换，可切回按类型；嵌入不可用时自动退回原视图）。harness 1874/0；实测：3 条测试摘录聚成 2 个主题、复习队列出入队正常（测试数据与产物已清理）。









## [v0.8.21] - 2026-10-29
### Fixed

- 查缺补漏（0.8.15→0.8.20 跨版本审查，本批 9 修）：备份调度 catch-up 与声明不符（`hour == 计划时` 改为 `>=`——应用在计划时刻未运行/睡眠时当天不再补跑的真 bug）；下载后处理链 async 后按 index 取行可越界/指错行（改为按 id 重查，写回同样重查）；磁盘空间卫士拒绝的下载原本只发通知不落行（改为插一条 failed 行可见）；记忆导入丢失 pinned 状态（导入后按内容找回并 togglePin）；crewDispatch 预设此前只有存储无工具入口（死代码——补 preset/saveAs 参数）；Remote 三命令（发起下载/批量操作/归档会话）此前只有 Mac 端处理器没有 iOS UI（补齐下载页新建+批量条、归档会话视图与导航）；任务 JSON 只有桥端点无 UI（任务页导出/导入菜单+结果提示）；⌘⇧V 未进快捷键目录（设置页可改清单补 clipboardHistory）；SkillGallery 只有实现无 harness 测试（补 8 断言：版本/空表/URL 安全）。
- 查缺补漏补遗（第二批审查）：readPdf 扫描件 OCR 兜底从未真正落进 DOMTools——0.8.16 提交信息声称交付、实际 diff 里没有（当时脚本旧锚点静默跳过，正是"脚本改源码必须逐条 assert"教训的再次实证）；本次补回并让 OCR 尊重 pages 页范围参数（此前即便接线也会忽略点名页范围）；摘录回源改为应用内打开（此前 http 来源跳系统默认浏览器——摘录是 Desire 的沉淀，回源也应在 Desire 里；⌘⇧F 摘录激活同口径）。
- 查缺补漏第三批（跨版本深挖 8 修）：PDF 阅读进度记忆对网页 PDF 全程失效——临时文件名带 UUID 每次不同，改用源 URL 作稳定身份键（本地文件回退路径键）；PDF ⌘F 逐键全文档扫描改为 250ms 防抖（大 PDF 不再卡手）；备份补 excerpts 与 clipboard 两域（条目+墓碑一起存，merge/replace 两口，导入面板枚举自动收录——此前 0.8.17 摘录库与 0.8.19 剪贴板历史完全不在备份里）；备份设置补"运行时刻"选择器（backup.scheduleHour 此前只有默认 9 点无 UI）；技能 Gallery 安装返回后重扫风险徽标（此前要等下次进入技能页）；同步区副标题观察 ProfileStore（此前切档案不重绘）；⌘⇧F 摘录激活与摘录面板回源统一走应用内标签（冗余分支清理）。已知边界（记录不修）：settings 域备份只覆盖 Settings store 键，0.8.19-20 新增的纯 UserDefaults 偏好（新标签页区块开关/成本预算/crew 模板等）不在备份内——如需覆盖走后续专用迁移，不硬塞进 SettingsSync 目录（会把机器相关项带进同步）。
- 查缺补漏第四批（收尾清理，7 项）：i18n 目录补齐 v0.8.18 之后新增的 63 个静态键三语条目（en/zh-Hans/zh-Hant 全覆盖，总键 2949、缺 0——此前这些键在中文界面回退英文）；PDF 表单文本编辑改为只标脏不重算批注数（每次按键都全页扫描批注是浪费，表单编辑不改批注数量）；备份导入摘录时被替换掉的本机条目现记墓碑（否则下次同步 pull 会把它们从服务器救活）；成本预算对账加 60 秒节流（derive 要扫全部会话消息，连续回合不必每回合重扫）；Remote 批量下载分支清理残留无用赋值；crewDispatch 的工具描述补齐 preset 语义（模型此前不知道这个参数能按名复用已存预设）。
- i18n 历史欠账清理（56 条）：此前只有英文的 32 条既有 UI 文案补齐简体与繁体（标签页/运行中状态汇总、下载保存回执、站点监视统计、死链检查回执、成本预算阈值越线提示、站点范围授权说明等），另有 24 条中文源键补齐繁体译文（白板/DPP 协议/便签等 0.7.x 文案）；术语沿用目录既有口径（智慧體/標籤頁/已儲存）。空骨架键（无任何本地化的纯符号/版本号等 556 条）不在本次范围。
- i18n 占位符审计（全目录 2948 键）：App Intents 三个快捷指令摘要的三种语言统统写成 printf 占位符（`%@`/`%lld`）——Shortcuts 里参数代入用 `${var}`，`%@` 不会被替换，会直接把符号显示给用户；已改回 `${prompt}`/`${url}`/`${name}` 等变量形式。另删除一条 0.7.x 遗留的 stale 重复键（`Search in %@ for %@`，占位符写成 `%1`/`%2` 缺 `$@`，源键已改为带引号版本、此条永不再命中）。已对全目录做占位符一致性校验（各语言占位符种类与数量必须与键一致，位置化 `%1$@` 与裸 `%@` 视为等价）：剩余 0 条不一致。
- i18n 空骨架第二批：79 条中文源键此前完全没有本地化——英文界面会直接显示中文（竖排标签栏的“固定/标签页”、白板评论与放映、成本明细、选区分享卡、渲染进程崩溃提示、页面性能指标说明等）；现补全英文与繁体（简体即键本身），占位符按目录既有口径统一（`%lld`/`%@` 原样保留）。剩余空骨架 477 条均为英文源文案/符号，留待后续批次。








## [v0.8.20] - 2026-10-29
### Added

- 自动化管线第一批（0.8.20）：工作流 → 技能转换（旗舰——录制的回放步骤序列转 SKILL.md：navigate/click/input/select/key/wait 逐步转自然语言指令+选择器，text: 前缀转"可见文本"描述；敏感字段转 {{vars}} 参数化——"值绝不落盘"口径在技能里延续为运行时填值；单向生成，手改不回写；WorkflowSkillExport 进 harness 12 断言）；标签自动刷新（pill 右键档位 10s/30s/1m/5m/关——TabManager 5s 中央 tick 到点 reload，挂起标签不刷，胶囊 arrow.clockwise 角标）；剪贴板同步第十四域（ClipboardHistoryStore 补墓碑/同步口——FIFO 淘汰与 24h 过期都记墓碑防复活，SyncEngine adapter 照 excerpts 纪律；opt-in 默认关；api-sync-smoke 13 步含 clipboard roundtrip 实证）。
- 会话分支（0.8.20 第二批）：assistant 消息一键 "Fork from here"——历史截断复制（含该消息）为新会话（Fork: 标题 + system 来源标注），当前会话不动、面板底部 toast 提示去会话列表找分支；流式中不挂菜单（回合未定局）。
- 会话分支与记忆导入（0.8.20 第二批）：assistant 消息一键 "Fork from here"——历史截断复制（含该消息）为新会话（Fork: 标题 + system 来源标注），当前会话不动、面板 toast 提示；流式中不挂菜单；记忆导入（对偶 0.7.7 知识库导出）——MemoryImport 解析 markdownKB 真实形态（### 分节/★ 前缀/括号元信息"范围 host · 来源"），逐条走 addFact 由既有去重与冲突复核接管，解析器进 harness 9 断言（1788/0），记忆页导入按钮。
- 自动化管线批（0.8.20 第三批）：数据集定时采集（DatasetSpecStore 命名规格持久化 + builtin kind dataset:<id> 白名单扩展 + deliverBuiltin 跑采集→快照落盘→diff 回执+routine 通知；采集 sheet 时钟菜单存规格并挂调度）；每日简报产物化（runNow 同步落 workspace brief-<date>.md 入账最近文件；briefs 帧推手机最近 7 份，iOS RemoteBriefsView 点按在 Mac 上打开）；下载后处理链（归档规则加 convertTo 动作——命中移入子目录后自动 convertDocument 转格式（pdf→md 等）产物入账，通知附转换结果；编辑器加目标格式列）。远程端依赖：剪贴板域与数据集域同步部署见 docs/OPS-SYNC-DEPLOY.md。
- 收官批（0.8.20）：PDF 全文朗读（工作条 speaker 三态——播/暂停/停，逐页合成游标即页码，SpeechCoordinator 独立 delegate 收口避免 ObservableObject 继承 NSObject）；下载磁盘空间卫士（剩余 <2GB 可配时新任务不入队 + routine 提示，防写满卷）；网页右键"收藏此页到摘录"（标题+URL+选区/meta description 快收——与划词摘录同一去向）；crewDispatch 预设（命名配置存 crew.presets，objective/tasks/compare/windowMode）；Remote 三件（手机粘贴 URL 发起下载、批量暂停/恢复/清完成、归档会话列表+一键恢复到 Mac——SessionArchive 真实 API 对偶）；定时任务 JSON 导出/导入（配置含链/夜间开关，导入按名跳过冲突；桥 GET/POST /agent/tasks/export|import）；备份自检（调度备份完成后 preview() 只读验证可导入，结果进通知）。






## [v0.8.19] - 2026-10-29
### Added

- 剪贴板历史（0.8.19 旗舰，第一批）：⌘⇧V 面板——最近 30 条文本/URL/文件路径复制记录（1.5s 轮询 changeCount 采集，24h TTL、同内容刷新时间戳不堆叠），搜索过滤、点击回灌、逐条删除/一键清空；隐私口径：密码管理器复制密文经 suppressNext 不入库、回灌自身也不自录、超长文本（>10k）不入库；Tools 菜单入口（快捷键走快捷键设置可改）。规划对账撤项两项（核实已交付）：标签悬停预览（TabBar hover 250ms + 后台缩略图缓存管线完整在）、地址栏粘贴直达（URLBarField 的 paste-and-go 菜单项已有）。
- 标签概览挂起管理（0.8.19 基础件 6）：瓦片右键"挂起/唤醒/关闭"（挂起动作防误触——当前选中标签不给挂），挂起瓦片显示时长（suspend 盖戳 suspendedAt、唤醒清除）；Tab.suspendedAt 随会话快照走（挂起治理不再黑箱）。
- Agent 存在感批（0.8.19 第二批）：技能 Gallery（旗舰——站上 skills/index.json 机读索引 + 应用内技能页"发现"入口：列表/一键安装（installFromURL 通吃 .md/.zip）/已安装徽标/失败原因就地显示；与 BoardGallery 同款不可信输入纪律，SkillGallery 解析进 harness 首批 4 个官方技能 .md 上站）；Remote 任务编辑（手机端创建表单外的编辑闭环：Mac updateTask 命令按名定位、prompt/节奏可改（builtin 拒改），iOS 行左滑编辑 + TaskEditSheet 预填解析既有节奏）。规划对账撤项两项（核实已交付）：子代理观察面（AgentPanel runningSubagents 实时行）；技能参数化进 Remote（vars 缺失 → Error 清单 → 模型 askUser → 手机问题卡，天然全链路）。
- 日常个性化批（0.8.19 第三批）：新标签页组件开关（区块头右键隐藏——常用网站/最近文件/最近访问，全隐藏时显示"显示全部区块"恢复入口，@AppStorage 持久化；排序做诚实版撤项——隐藏集推不出顺序，留待专门的顺序键）；摘录库进 ⌘⇧F（第七源：标题/内容/备注/来源命中，Clip 徽标，回车开来源含 PDF #page 深链）；成本预算告警（设置 Agent 节日/月预算线：回合收尾对账，≥80% routine / ≥100% urgent，每档每天至多一次；UsageStats 按日成本为新字段——无单价日走 ≥ 语义照既有口径）；定时任务失败诊断卡（RunRecord.error 启发式分类：网络/审批/模型/上下文/工具/其他 + 指引一行进通知，TaskFailureClassify 进 harness 9 断言）。
- 收官批（0.8.19）：crew 对比矩阵（crewDispatch 带 compare——落定时把各任务指令/状态/关键结论合成 Markdown 对比表自动上白板，≥2 个有结果任务才合成）；自动备份调度（每日/周一 → 设定小时跑全量备份 + 轮转保留最近 3/5/10 份（只动 desire-backup-* 前缀），重启错过的当天备份在设定小时后的任一 tick 补跑，完成 routine 通知；设置页新 Scheduled Backup 节 + 最近运行日期）；任务夜间窗口（编辑器开关：到点落在免打扰时段顺延到窗口结束集中跑，任务卡月亮徽标，Mac+Remote 语义一致）；摘录分享卡（单条渲染成强调色渐变图片卡——大引号+折行正文+我的批注+来源行，剪贴板+另存双通道）。规划对账（本版撤/顺延 5 项均有据）：监视历史时间线已交付（PageWatch historyCap 60 + 中心面板）；WebApp Dock 徽标受平台约束（macOS Dock 徽标是 app 级单数——per-WebApp 无系统支持，撤销）；剪贴板历史跨设备顺延 0.8.20（settings 域快照机制只收 Settings-store 键，需像 excerpts 那样的专用 adapter，不硬塞）；数据集定时采集顺延 0.8.20（builtin kind 白名单需扩 dataset:<id> 且 DatasetSpec 无 id，含选择 UI 一个批次）；每日简报进 Remote 顺延（简报文本未产物化，先产物化再推帧）。






## [v0.8.18] - 2026-10-29
### Added

- 同步收官三件（0.8.18 第一批）：多档案同步实施（方案 A——随档案换桶的书签/历史/快拨三域以 `@<profileUUID>` 后缀域键独立同步，服务端 is_valid_domain 放宽 base 域+后缀校验、迁移 0018 放宽 domain 列宽，游标/墓碑按档案隔离；默认档案域键与存量一致零影响，切档案自动全量对账一轮；api-sync-smoke 12 步含档案域 roundtrip+隔离实证）；Remote 摘录（iPhone 端看 Mac 摘录库前 20 条、点按在 Mac 上打开来源——http 开标签/文件路径进查看器路由）；同步服务端部署清单（docs/OPS-SYNC-DEPLOY.md：0017 归因欠账+excerpts+0018 三增量、部署机四步铁律、真端点验证命令）。
- 浏览器基础五件（0.8.18 第二批）：表格查看器冻结首列（行号列按横向滚动偏移反向平移+裁剪，视觉钉在左缘、各行同步偏移纵向对齐自动保持）；PDF 选区复制段落化（⌘C 去视觉行硬换行：单换行折空格、双换行保段落、行尾连字符并词——原样复制走 ⇧⌘C；TextParagraphize 进 harness 4 断言）；下载面板多选（工具条切换选择模式：行首勾选、批量打开/Finder 显示/删除、全选）；新标签页最近文件右键"重命名…"（同名冲突与存在性校验、.bak 跟名、台账换 URL）。规划对账撤项一项：⌘F 大小写敏感开关（FindBar 的 Aa 切换 + WebView JS flags 早已交付）。
- Agent 治理与摘录深化（0.8.18 第三批）：审批沉淀规则面板（能力页新增——`.alwaysAllow`/`.deny` 的工具×站点规则清单，逐条删除/全清，沉淀不再黑箱）；crew 报告模板编辑器（任务页入口：占位符速查、恢复默认、"customized" 徽标）；定时任务最近 7 天运行分布条形（成功/失败双色，口径对齐 store）；摘录库 Agent 起草（多选 → 带"标题·类型/正文/我的批注"拼 prompt 交活会话出周报/笔记）；摘录来源 PDF 跳转带页码（批注收录时 source 写 #page=N fragment，点击经 addTab 流到 PDFViewerView 解析成初始页——深链链路：面板→路由→查看器）。
- 收官批（0.8.18）：下载归档规则编辑器（设置 Downloads 节入口 + 表格 sheet：扩展名/来源域 → 子目录增删，存储与运行时同源 "downloadArchiveRules"）；crew 规模上限可配（"crew.maxTasks" 2-10 默认 6，crewDispatch 校验读配置）；归档规则桥端点（GET/POST /downloads/rules——Agent 与自动化可代管整表替换）。





## [v0.8.17] - 2026-10-29
### Added

- 摘录库（0.8.17 融合旗舰）：阅读高亮、PDF 批注、网页划选统一沉淀进一个本地库（来源/类型/时间），跨文档搜索、类型过滤、一键导出 Markdown 笔记本（按来源分节、引用排版、备注加粗）；三个入口——阅读高亮列表行级"存为摘录"、PDF 批注列表右键"收进摘录库"（带页码引用）、划词工具条新增"摘录"（本地收录零模型调用）；面板挂 Agent 窗口新"摘录"目的地（计数徽标）；同来源同内容自动去重（重复收录只刷新时间戳）；上限 500 条 FIFO 淘汰（淘汰记墓碑随同步）。
- 摘录同步第十三域（excerpts）：服务端 DOMAINS 白名单加行（通用表零迁移）+ 客户端 SyncEngine adapter（墓碑/LWW/HMAC 反查照 jobs 域先例）；设置页同步类目开关自动收录（枚举驱动）；api-sync-smoke 扩 excerpts roundtrip 用例。注意：服务端生产部署需更新 API 二进制后摘录才真正跨设备（客户端先行，未部署时该域报错不影响其他域）。
- 第二批（0.8.17）：技能参数化——SKILL.md frontmatter 声明 vars 槽位（vars: 名单 + var-<名>-default/-desc 修饰行），useSkill 工具带 inputs 填值（缺失按失败约定报清单、default 兜底、{{占位符}} 替换），技能页"使用"弹填值表单（有 default 预填）；listSkills 输出带 vars 提示；SkillVars 解析/占位/渲染进 harness（9 断言）。记忆时间线：记忆页按月分节（当月单列）、批量清理模式（选择模式行首勾选、分节全选、一次删除 N 条）。同步多档案设计稿（docs/SYNC-MULTI-PROFILE-DESIGN.md）：三方案对比（domain 后缀推荐/payload 前缀否决/虚拟设备否决），服务端零迁移路线与落地拆分——待过目后实施。
- 收官批（0.8.17）：定时任务完成链（任务 A 成功后自动投递 B——setChain API 防自环，链是便利语义非契约，目标忙/不存在静默跳过）；crew 报告模板可自定义（UserDefaults "crew.reportTemplate"，占位符 objective/done/failed/duration/usage/tasks，未设置=内置结构）+ crew 完成通知正文附报告文件名（先落盘后通知）；下载自动归档规则（默认关：UserDefaults "downloadArchiveRules" 存 [{ext|domain, folder}]，首条命中移入下载根子目录、防 ".." 穿越、移动结果进 routine 通知）；新标签页最近文件过滤框（>3 个文件时显示）；同步类目开关副标题带待删墓碑计数（长期非零=该域同步持续失败的信号）。规划对账撤项两项（spike 实证）：PDF 大纲书签编辑（PDFKit 程序化建树写入后重读 outlineRoot 为 nil——document.write 不保真大纲）；双指灵敏度/滚轮平滑滚动设置（WebKit 无公开 API，按"勿做假 UI"红线撤项）。同步多档案设计稿已交（docs/SYNC-MULTI-PROFILE-DESIGN.md，方案 A domain 后缀推荐），按规划约定待设计过目后另行实施。
- 图片编辑器缩放与平移（用户实测反馈）：此前图片永远按原始像素显示（大图爆炸、小图不可辨、无法放大细看）——新增完整缩放体系：工具条 -/百分比/+/适应窗口/1:1（⌘=/⌘-/⌘0），捏合缩放（5%~800%），双击画布在"适应 ↔ 实际像素"间切换；平移走原生滚动（放大后两指/滚轮随意移动）；默认适应窗口不再被大图初始视图淹没。顺带修正画布坐标系既有偏差（displaySize 原来量带 padding 的外框、裁剪选框/多边形预览挂在 ZStack 上与手势坐标系差一个 padding——统一为图片本地坐标，缩放后不再放大暴露）。






## [v0.8.16] - 2026-10-28
### Added

- PDF 深水区（0.8.16 第一批）：加密 PDF 密码解锁（打开即密码浮层、错码原地重试、解锁后大纲/批注刷新——此前加密件直接卡白）；AcroForm 表单填写（工作台新增"表单"侧栏——文本字段行内编辑、提交即写 ⌘S 落盘，按钮/勾选只读展示；PDFKit 往返探针先行验证通过：建字段→枚举→填值→保存→复读无损）；PDF 阅读进度记忆（按文件路径哈希记 lastPage+zoom，重开自动回到上次位置）；PDF 合并/拆分进 UI（最近文件右键"合并 PDF…"/"拆分页码范围…"，PageRangeParser 管道复用，产物入账并在 Finder 选中）。
- 办公互转补全（0.8.16 第二批）：CSV→xlsx 纯数据写入器（极简工作簿 zip+XML 零依赖，数值-looking 单元格按数字写、前导零保持文本；roundtrip 写→读回直测进 harness）——表格查看器新增"导出 xlsx…"、convertDocument 与右键转换菜单支持表格→xlsx；扫描件 PDF OCR 直读（readPdf 无文本层自动 Vision OCR 兜底、显式标注 SCANNED、页上限 20，convertDocument 同步贯通——扫描件也能转出 docx/md）；pdfPageScreenshot 工具（单页位图给视觉输入，图表/版面/表单类问题不靠整页截图）；会话产物气泡（工具回执里的产物文件自动识别成可点 chip，点击直接进应用内查看器——转换/导出/crew 报告产物一键回看）。
- 收口批（0.8.16）：crew 依赖编排（crewDispatch 任务可带 dependsOn 指向前序下标——前序 done 才派发、failed/cancelled 级联跳过，"先采集再汇总"两段式一条指令跑完；并行窗口模式轮询门控、标签串行模式顺序天然满足）；定时任务重试策略可配（设置页 Scheduled Tasks 节 1-3 次，指数退避 30/60/120s，耗尽才发失败通知）；下载中心本周统计（面板摘要行：近 7 天完成条数与体积，完成即刷新）；视频下载完成 ffprobe 回执（时长/分辨率/编码进通知，与文档摘要同 opt-in 开关、零模型调用）；历史与书签轻量导出（JSON/CSV，书签导出钮改三格式菜单、历史面板新增导出菜单）；Remote 最近文件搜索（iPhone 端按文件名/类型过滤）。规划对账：翻译引擎可插拔撤项（spike 证实 TranslationSession 无法脱离 .translationTask 独立初始化，整页分段管线耦合代价高，系统开放独立 session 后再入池）；DPP 跨源动作路由撤项（0.7 切片二已交付 sourceFrame→frameProtocols 执行）。




## [v0.8.15] - 2026-10-28
### Added

- PDF 工作台（第一批：导航/批注/页面管理）：大纲+缩略图+批注三 tab 侧栏（缩略图懒生成、右键旋转/删除/上下移/提取本页）、页码跳转框与 "n/N" 指示、⌘F 全文查找（命中计数/上下条跳转）；批注工具条——高亮/下划线（划选即落注）、文字便签（点击落点弹输入）、箭头/矩形（拖拽绘制），批注列表点击跳转、右键删除，⌘S 另存带批注 PDF（PDF 多来自临时下载文件，统一另存而非写回）；页面操作 ⌘Z 可撤销（删除/重排/旋转记录逆操作）。PDFKit 操作收口 PDFWorkbenchModel（Store 层），视图零业务逻辑。
- Agent×PDF 五件：readPdf 支持 pages 页码范围（"1-5,8"、"3-" 开放区间，解析器进 harness）并按页分节带 [pN] 标记（长文档分段读、引用可溯源）；convertDocument 一体转换工具（pdf→md/txt/docx/rtf/html、文档→PDF 离屏渲染分页、多图合成 PDF、表格→md/csv/tsv，全部端上、只写产物不碰源）；PDF 查看器 ⌘⇧A 问 Agent（取文预填提问进活会话，对齐文档问答管道）；Jobs 面板本地 md/txt/csv 产出行内一键转 docx/rtf（转好在 Finder 选中）；crew 收尾报告自动落盘工作区（crew-<时间>-<主题>.md，逐任务状态/耗时/报告全文）并入账最近本地文件。
- UI「转换为…」与表单锚点：最近本地文件卡片右键按源类型列目标格式（PDF→md/txt/docx/rtf/html、文档/图片→PDF、表格→md/csv/tsv，与 Agent convertDocument 共用 DocumentConvert 管道，转好入账并在 Finder 选中）；图片编辑器新增直线、多边形（单击加点、点回首点闭合、虚线预览）与序号气泡（点击落位自动编号）三种标注工具；fillForm 回执带字段截图（逐字段取矩形裁图、垂直拼一张附回执——模型可视觉自检、用户回执可见，上限 6 字段）。
- PDF 选区上白板：PDF 工作台工具条新增"上板"——当前选区文本块带页码引用（文件名 · pN）进白板，与网页选区/截图上板同管线；运营周报一键导出 docx/rtf（复制按钮旁新增导出菜单，exportDocument 管道，转好在 Finder 选中）；⌘⇧F 集中搜索第六源——最近 50 个本地文件按文件名与内容快照命中（后台预热索引、内容命中带片段、回车进查看器，桥 /search/everything 同步）；下载完成自动摘要（opt-in 默认关）：PDF/Word/RTF 等文档下载完成后旁路生成一句话摘要进通知（设置页 Downloads 段开关）。核实撤项两项（均已交付）：全局默认字号 UI（0.7.20 已有）、下载行拖拽到 Finder（CompletedFileDraggable 已有）；Remote 文件面类型 chip 与远端打开核实为已交付（recentFiles 帧含 kind + iOS macwindow 打开）。





## [v0.8.14] - 2026-10-27
### Changed

- YouTube 非可视区预览播放器暂停：首页/列表页 hover 预览预创建的 <video> 被 WebKit 反复拦自动播（实测 30 分钟 898 条 consent block）——yt-playback-guard 每 1s 暂停非可视区 video，消除 CPU/预取带宽浪费；详情页播放不受影响（watch 页直接跳过）

### Added

- 文档导出为 Word/RTF/HTML：文档查看器导出菜单新增三格式（textutil 正向转换，Markdown 标题/列表保结构）；Agent 新工具 exportDocument——产出正式 docx/rtf 交付文件（白名单路径，Markdown 结构保留）
- 表格编辑撤销/重做：⌘Z/⌘⇧Z 与头部按钮（快照栈上限 100 步）；SpreadsheetBuffer 快照栈纯逻辑进 harness（Swift 6.4 对 nonisolated struct 的 [[String]] append 重载解析 bug 以 Snapshot 包装 struct 绕过）
- 表格打印：表格查看器 ⌘P——网格转 HTML table 经隐藏 WKWebView 走系统打印面板（表头底色/边框/防跨页断行）
- /templates 会话模板命令：无参列出全部（内建周报/翻译/比价 + 自定义），带名输出骨架与待填变量清单
- 图片打印：图片编辑器 ⌘P（横竖向随图、居中适配上纸）
- zip 右键压缩为…：新标签页最近本地文件卡片右键一键压缩（同目录落同名 zip）
- readSpreadsheet 分页：offset 参数跳行 + maxRows 截断，大表可逐页遍历全量
- Agent 新工具 listRecentFiles（最近本地文件清单，可按类型过滤）与 batchRename（批量重命名，逐对校验存在/冲突）
- 产文件入账补全：zipFiles 产物记入最近本地文件
- 表格查看器选区画图：点击选格、按住 ⇧ 点击扩展成矩形选区，工具栏"Chart with AI"一键把选区子矩阵（TSV，行 60/列 12 封顶、超限注明截断）交给活 Agent 会话，由模型按数据形态挑图型渲染到白板。
- 表格查看器列宽调整：拖表头右缘 6pt 手柄调宽（56-640pt，手柄不吃排序点击），按文件路径哈希+工作表记忆、重开保持；列宽改固定值后表头与数据列严格对齐（原 minWidth 自适应在长内容下会跨行错位）。






## [v0.8.13] - 2026-10-27
### Added

- xlsx 多工作表：表格查看器底部工作表标签栏（SpreadsheetReader 新增 sheetList），切换重载（排序/筛选/编辑态随切换重置）
- 图片操作历史面板：编辑器工具条新增历史按钮——每步操作带名入栈（旋转/裁剪/标注/调色…），点击任意一步跳回（其后步骤丢弃），栈底为原图
- 引用角标深化：Agent 回答下方渲染本回合工具结果里的来源 chips（[1][2] + 文件名/域名），点击浏览器/访达直达
- 会话模板 /templates：内置周报/翻译/比价三骨架（{{变量}} 占位、未填保留），自定义模板 UserDefaults 持久化；/templates 列表、/templates <名> 输出"复制即用"骨架
- Agent 压缩三件套：zipFiles（多路径 → 单 zip，工作区内）、unzipArchive（解压到指定目录或工作区默认文件夹）、tableExport（xlsx/csv/tsv → csv/md，写工作区）——与 listArchive 凑齐压缩包与转换工具面
- batchDocuments 逐文件进度：JobRecord.progress/detail 逐文件更新（N/M: 文件名），Jobs 面板与桥可见——整批不再黑盒
- 截图直通编辑器：截图保存的 PNG 自动在当前标签打开（图片编辑器），立刻标注/裁剪
- 文档打印与导出 PDF：文档查看器头部新增打印（⌘P 同款系统面板）与"导出 PDF"（整页高度 createPDF，NSSavePanel 选落点）
- 文档问答：文档查看器一键取文预填 Agent 提问（DocumentText 取文 8000 字注入），问文档不用复制粘贴
- 定时/批量产文件自动入账：batchDocuments 生成的 .summary.md 记入最近本地文件（新标签页与 Remote 文件面可见）——产出可追溯




## [v0.8.12] - 2026-10-27
### Fixed

- 本地文件打开断链修复（自查抓到，发布前）：isOpenableFile 白名单缺 csv/zip/docx 等新查看器类型——地址栏/拖入全被当搜索词；桥 /navigate 的 file 路径被 URL 启发式吞掉且缺四个新查看器分支（各自 setState）；本地路径直通（navigateToURL 与桥 /navigate 同语义：存在的文件路径先于 URL 启发式）；查看器挂载期间地址栏与 /state 报文件路径而非 webview 里残留的旧页 URL

### Added

- 表格直开查看/编辑器（旗舰 A）：CSV/TSV/XLSX 拖入/本地打开进网格标签页（冻结表头/行号/双击单元格编辑/列头点击排序/关键字筛选/A1 跳转/状态栏）；⌘S 保存带 .bak 快照 + 原子写，xlsx 提示缓存值口径
- Agent 表格编辑工具 editDocument：.csv/.tsv 单元格 A1 写回（与查看器同一 SpreadsheetBuffer 写层，.bak 快照 + 原子写）；xlsx 明确报错无公式重算、富文本文档只读提示导出
- 图片编辑器（旗舰 D 核心，macOS 预览量级、零第三方依赖）：png/jpeg/heic/tiff/gif 拖入直开——旋转 90°/翻转、拖拽裁剪（自由/1:1/4:3/16:9 比例锁）、标注（画笔/箭头/矩形/椭圆/文字/像素化马赛克）；⌘S 保存（.bak 快照+原子写，heic 走 CoreImage）、⌘Z 单步撤销（20 步栈）
- ZIP 直开浏览（旗舰 C）：zip 拖入 → 条目树（嵌套缩进/大小/中文文件名），文本/图片条目单条预览；"解压到…"后台 ditto + 完成通知（rar/7z 明确不支持）
- Word/RTF/ODT 直开查看器（旗舰 B）：textutil 转 HTML 保结构渲染（标题/列表/图片自适应）；⌘F 文档内查找（高亮+计数）；标题大纲侧栏（h1-h3 点击滚动）
- 图片调色（旗舰 D 21）：亮度/对比度/饱和度/锐化滑杆（CIColorControls 实时管线），Apply 烙进 ⌘Z 栈；导出为 PNG/JPEG/HEIC（NSSavePanel 选落点）
- 图片 OCR 取文字（旗舰 D 22）：编辑器工具条一键 Vision 识别（中文/英文），结果浮层可复制——复用 ocrImage 管线
- Agent 压缩包探查工具 listArchive：zip 条目清单（路径/大小/目录标记，60 条封顶）——zipFiles/unzipArchive 后续批次补齐，解压现走 UI 或 runCommand ditto
- 最近本地文件：openLocalFileInTab 统一记账（20 条），新标签页"最近本地文件"区一键重开；多文件拖入各自开标签（首个当前、其余后台）
- 表格 → 指标导入直通：运营指标导入 sheet 预填当前打开的 CSV/TSV 文件（跳过文件选择器）
- 文档加入阅读列表：文档查看器头部一键（正文前 400 字作 detail）
- Agent 批量文档处理 batchDocuments：白名单文件夹内全部 csv/tsv/txt/md 各跑旁路摘要 → 同目录 .summary.md，JobRecord 进 Jobs 面板（≤20 文件）
- Remote 最近文件面：手机看 Mac 最近打开的本地文件，一键在 Mac 重开（recentFiles 帧 + openRecentFile 命令）





## [v0.8.11] - 2026-10-27
### Added

- Remote 定时任务面：手机新建/启停/删除/查看 Mac 上的定时任务（tasks 帧 + 五个远端命令；内置任务保护不可删），Agent 首页新增"定时任务"入口
- crew 完成远端通知：urgent 级直推（目标 + 完成/失败计数 + 总耗时），点击直达 Agent 面板——长任务不必盯着
- 审批卡透传互斥：手机在线时 Mac 面板不弹审批卡（改一行"已发送到手机"指引，Handle Here 随时收回），远端先响应为准；Settings ▸ Agent 新增透传开关（默认开）
- 标签快照恢复面板：概览按钮右键"Recently Closed Tabs…"列出本窗最近关闭队列（新→旧），逐条点恢复（保留无痕/容器身份，恢复即从队列摘除）
- ⌘⇧F 预览面板：检索结果分栏——右侧跟随键盘选择渲染命中首屏（源类型/标题/URL/会话正文片段或最近对话摘录），回车才真正跳转
- 夜间批处理档：免打扰时段预算放宽 ×3（不是硬扣）——夜间跑的 crew/定时任务产物照常通知，早晨一并看到；设置随 NotificationPolicy 持久化
- 下载"另存为"：完成行右键选目录移动产物（可改名），移出下载目录即从台账移除
- 历史按域名批量清理进面板：右键"Delete All from domain (N)"任意分组模式可用（确认带估删条数）
- 稍后读闭环：列表右键"Continue Reading (N%)"续读；"Auto Mark Read at 60%"开关（默认关）开启后打开高进度条目自动勾已读
- 技能检查更新：URL 安装的技能右键"Check for Updates"——重下远程内容 SHA-256 比对，变更即重装（来源与 hash 持久化，reload 并回）
- Agent 输出长度档：设置 ▸ Agent 三档（简洁/标准/详尽），注入 <output_rules> 层（档位在前、standard 不注入）；会话级指令仍可覆盖
- 工具结果引用回链：readTab/readFile 等结果卡自动识别首条 http(s) URL 或存在的文件路径为可点链接（浏览器/访达回看）
- Jobs 三栏并行看板：面板头按钮切换 正在跑/排队/今日完成 三栏视图（每栏封顶 12 条）
- Remote 免打扰透传：手机查看 Mac 免打扰时段/预算/扣留数，一键切换夜间批处理档
- Remote 下载监控：手机看下载列表（状态/进度条），单条暂停/恢复
- 稍后读/监视收件箱核实记档：监视变化已全量进收件箱（v0.8.8 Ask-Agent 已覆盖无分析场景）——规划稿该条为存量重复，无需新代码




## [v0.8.10] - 2026-10-26
### Added

- crew 可靠性三件：跨窗 worker 失败自动换窗重试一次（空闲会话池选 alternate）；crewStatus 摘要带逐 worker 耗时与重试标记；crewCancel/cancelAll 级联取消目标窗口已派发的回合（不再只标本地状态让那边继续烧模型）
- 会话移交 handoff v2：源窗口跑着回合也允许移交——排队消息与待批审批整体随会话带走（待批操作如实拒绝并留说明），源回合自然完成后结果落盘同一会话；空闲源保持原"移交+源回空会话"语义
- JobStore 同步域（第十二域）：作业账本跨设备（dismiss 走 tombstone、upsert 不盖戳防 LWW 反转）；服务端 DOMAINS 白名单加 jobs
- Agent 写入回滚：回合内对书签/阅读列表的增删记成可撤销改动组（快照含原 id/时间戳，逆序回放还原）；GET /agent/undo 列组、POST /agent/undo/revert 一键还原
- 定时任务审计页：轨迹页新增 7/30/90 天窗口的按任务聚合（次数/失败率/平均耗时/最后错误）
- 标签分组 v2：groupTabs 工具按"正在进行的事"聚合（≥2 个未分组标签成组、名称从页面标题自动建议）、分组面板整组挂起（跳过选中标签）
- 历史去重向导：识别语义重复（同规范 URL——scheme/尾斜杠/utm 等追踪参数归一），一键合并（保留最新、次数相加、标题取最长）；历史头部 Dedupe… 入口
- 每日简报纳入页面监视：近 24h 有变化的监视（名称/变化次数/AI 分析摘要）进运营简报 digest
- 技能分享：右键 Share… 出直链 + 可扫 QR，对方 Skills → Install from URL 即装（导入照跑风险扫描）
- 下载中心 v2：同源重复提示（近 7 天同文件复用最新副本，剥签名参数归一）、菜单"Retry All Failed"失败批量重试




## [v0.8.9] - 2026-10-26
### Fixed

- YouTube 详情页自动播放（0.8.7 用户实测回归）：新标签页建起的 webview 烙的是默认 requireUserAction，之后导航到视频站策略不变——自动播被 PageConsentRequired 拦、kick 的信任手势在 WebContent 进过一次后台后失效（统一日志实证）。修复：didFinish 发现"视频站 + 本应 allowAll 但创建期烙了限制"时按工具栏授予同款路径就地重开一次（保留无痕/容器身份，站点显式 block 不触发）；真机验证 watch 页 paused=false 自动播。/state 的 tabs 增加 autoplayPolicy 探针字段
- 阅读进度被"未滚动过的打开"清零（E2E 套件 189✓/1✗ 抓到）：关标签时 tracker 对从未滚动的页面采集 scrollY=0 覆盖已有进度，重开不再恢复——capture 对 ratio<2% 且已有 ≥2% 进度时跳过写入

### Changed

- 执行套件确定性化：20 处"回合结束立刻读会话文件"改为带 marker 轮询（DiskStore 500ms 防抖窗口内读旧文件是预算等 5 项时序不稳的根因）；/agent/trace 取会话 id 同样轮询

### Added

- 崩溃/强杀恢复安全网：应用激活时若窗口仍零标签自动重跑会话恢复编排（锁屏/未激活启动时首窗内容不构建、恢复整段不执行的兜底；排除终止流程，最多补跑 3 次）
- 强杀恢复探针 tools/crash-restore-probe.sh：N 轮真·强杀（不先 quit）→重启→标签恢复断言，实测 19/20 与 20/20 通过
- 自研整页翻译（v0.8.8 旗舰 9）：翻译条默认走用户自配模型的 AI 双模式——替换式（原文就地换译文、可完整还原）与双语对照；Google 挂件降级为"更多"里的后备（页面内容出第三方的固有缺陷在提示里写明）
- 运营登录态指引（A3）：账号健康检出 opsLoginRequired 时给出一步式引导——打开登录页（适配包可声明 loginURL，缺省站点根）、OAuth 弹窗预期说明、登录后一键重新检查；saveDPPAdapter 工具同步支持 loginURL 参数
- 密码填充多账号：同域多条凭据时提示条展开账号胶囊选择；登录表单字段识别放宽（autocomplete → 名称关键词 → placeholder → 相邻 label 逐档打分），div 登录布局（无 <form>）此前完全不触发检测、现可识别
- 跨窗 crew v2：crewDispatch 新增 windowMode——子任务轮转派给其他窗口的空闲 Agent 会话（每窗独立工具作用域与档案、真并行回合），报告与用量（含逐 worker token/模型）经 crewStatus 汇总回领队；无其他空闲窗口时明确报错并提示退回标签模式
- PageWatch 变化一键追问：收件箱监视行新增"Ask Agent"——带监视名与 AI 分析摘要发起新回合
- 整页翻译术语表：记忆里 category=translation 的条目按站点作用域（scope=本站或 global）注入翻译系统提示，"这个站把 X 译成 Y"经记忆面板维护即生效
- 启动审计进诊断包：LaunchAudit 快照（总耗时/逐阶段/预算判定）随诊断导出为 launch-audit.json，回归对比不再翻日志




## [v0.8.7] - 2026-10-25
### Fixed

- 切换到标签建议修复两处断链：openTabs 此前无人赋值（UI 与桥都没喂，功能从未生效）；桥 /suggest 被 buildImmediate 参数默认值绕过属性——现 URL/标题命中均首位返回 openTab（桥实测）
- 集中搜索会话片段：命中 range 改在原文上现算（此前取自小写副本，跨串索引是崩溃形态）
- 集中搜索跳转：命中会话即当前会话时直接滚动（此前 onChange 只覆盖切换会话路径，同会话永不跳）
- 下载建议条：清空输入才复位"忽略"，不再骚扰刚生成的下载指令
- 技能导出：单 md 技能落点强制 .md 扩展名（Save 面板敲 .skill 会让 import 拒收）
- 内联计算器/切换标签建议的选中行为：计算结果复制到剪贴板（此前回车会导航 calculator:// 报错）、openTab 选中即切标签（此前重复导航）
- release-smoke 锁屏免疫：等激活真正生效（≤8s），屏幕锁定时阅读模式检查显式 SKIP 而非假阳性（实测锁屏下 isActive 恒 false 会连挂两条）
- 锁弹层"本站拦截"计数提示的格式键对齐（%d→%lld）
- Skill 分发闭环（计划验收补跑）：自家导出的 .skill 包此前导入器不认（只收 zip/目录/md）——.skill 按 zip 容器导入；桥 /skills/delete 对目录技能删整目录（只删 SKILL.md 会留 companion 残壳占名挡重导入）；新增 POST /skills/export 端点，E2E 全链路（导出→删除→导入恢复 SKILL.md+伴随文件）实测通过



### Changed

- 快捷键速查表修正：Agent 发送键为 ↩（Shift/⌘↩ 换行）、Find Next/Previous 去重（已在可自定义列表）

### Added

- 查缺补漏批：Vim 模式设置开关（设置▸键盘，含搜索登记）、下载建议静音站点管理行（设置▸下载，一键解除）、批量下载批次卡片汇总分片速率、Tab-to-Search 关键字匹配纯核进单测
- i18n：v0.8.6 新增界面文案三语补齐（73 键：隐私面板/时间线/速查表/技能分发/下载建议等）
- 书签标签 HTML 往返：导出写 TAGS 属性、导入读回（属性序不定/空白清理），此前导出→导入一轮 tags 全丢
- 桥新增 GET /permissions（规则 + 矩阵快照）、/settings 暴露 vimModeEnabled；release-smoke 固化地址栏旗舰探针（计算器首条 + openTab 首位）



## [v0.8.6] - 2026-10-25
### Added

- 地址栏旗舰：切换到已打开标签（URL/标题命中建议 ⧉ 跳转）+ 内联计算器（输入算式首条出结果）+ Tab-to-Search（输入引擎关键字按 Tab 进入搜索模式）
- 隐私与安全面板：站点 × 权限（相机/麦克风/联合/位置）矩阵三态管理（未设置→允许→拒绝）、拦截统计与保护开关一站查看、按列/按站批量重置
- 锁弹层增强：HTTPS 证书摘要补组织与有效期窗口、本站累计广告拦截计数行
- 批量下载引擎逐项实时速度（媒体秒进度显示倍速、分片进度显示 seg/s）
- Vim 模式（实验）：j/k/h/l 滚动、gg/G 顶底、x 关标签、t 新标签、/ 查找，仅页面焦点生效
- 书签标签系统：书签可打 tag、编辑器 comma 分隔输入、面板标签条点击过滤、搜索命中 tag
- Skill 打包分发：右键导出 .skill 包（目录整包/单 md）、从 URL 直接安装（GitHub raw zip/md）、导出成功可直达 Finder
- 集中搜索会话正文：命中显示片段副标题，回车载入会话并跳转高亮该轮（查找框预填查询词）
- 阅读模式 AI 摘要：旁路流式调用（不占 Agent 回合），摘要/要点两档，可复制
- Agent 工具统计：统计页新增工具使用卡（调用数/失败率/平均耗时条形），能力页每个工具带 30 天调用徽标
- 历史时间线视图：第三分组档，按天 24 小时访问直方图 + 峰值小时
- 下载智能建议：输入框检测到媒体/文件链接提示"用下载引擎"，多链接建议批量，可按站点静音
- 启动路径审计：首窗出现时打印总耗时 + top5 耗时阶段，超 700ms 预算标红（fault 日志）
- 诊断内存快照按钮：本进程 phys_footprint/resident + 各窗口标签数一键入日志
- 键盘快捷键速查表：设置▸快捷键一键打开全量速查表（含硬编码键），支持打印/导出 PDF
- 下载完成通知动作按钮：直接打开文件 / 在访达中显示
- 地址栏 Tab 补全、固定标签关闭确认、阅读高亮导出 .md


## [v0.8.5] - 2026-10-25
### Added

- **运营数据同步域 promotion（0.8.5）**：PromotionStore 七类数据（目标/帖子/账号/实验/互动/战役/竞品来源）进同步（第十一类域），HMAC client_id + AES-256-GCM 密文 + LWW 合并 + tombstone 删除追踪；服务端白名单加入 `promotion` 并修复 `workspace` 遗漏。纯逻辑 `SyncPromotion.merge` 进 harness。
- **跨窗口 Agent 会话指示器（0.8.5）**：Agent 面板头部新增 `⧉ N` 指示器——其他窗口有 Agent 会话时显示，运行中高亮；点击弹出列表查看状态并一键切换窗口。
- **下载完成通知操作按钮（0.8.5）**：下载完成通知新增 Open / Show in Finder 操作按钮（UNNotificationCategory DOWNLOAD_COMPLETE）；NotificationRouter 处理两个 action（打开文件 / 在 Finder 中选中）。
- **地址栏 Tab 补全（0.8.5）**：URLBarField 新增 Tab 键补全——按 Tab 自动填入首个建议的 URL（Shift+Tab 无操作）；`suggestion(at:)` 方法加入 AddressSuggestionsModel。
- **固定标签关闭确认（0.8.5）**：固定标签的右键菜单新增 "Close Pinned Tab" 操作（普通关闭按钮对固定标签已隐藏，此处补上右键关闭入口并提醒用户）。
- **阅读高亮导出为 .md 文件（0.8.5）**：ReaderHighlightsSheet 新增 "Export as .md" 按钮——NSSavePanel 选路径，高亮 + 备注保存为 Markdown 文件（使用已有 ReaderHighlightStore.markdown）。


## [v0.8.4] - 2026-10-24
### Added

- **每日运营循环（0.8.4 第一批）**：新增 OperationsLoop——把散落的采集/提及/排期/回复/竞品/归因收进一条循环，汇总为一条 Jobs 条目 + routine 通知（"今日运营：N 件事"）；可定时 09:00 或手动 ▶ 触发，触发后把待办清单交给 Agent 逐件处理。纯逻辑 `OperationsLoopPlan` 进 harness（1513/0）。
- **归因→选题回流（0.8.4 第一批）**：Attribution 面板新增"表现最佳"——已发帖按浏览增长排序，top 3 + 最差，每条可一键生成同角度选题（交给 Agent 改写入库）；周报新增归因洞察段。
- **DPP Studio 圈选（0.8.4 第一批）**：新增 `pickElement` Agent 工具——激活当前标签的元素拾取器，等用户点击 30s 内返回 CSS 选择器 + outerHTML；模型用它获取精确选择器再调 `saveDPPAdapter`，闭环自定义渠道适配。
- **密码健康（0.8.4 第二批）**：`passwordHealth` Agent 工具——扫已保存密码的弱密码（短/常见/无混合）/重复（同密码跨域名）/过期（180 天+），只报域名和问题，不暴露密码。纯逻辑 `PasswordHealth` 进 harness。
- **文件整理作业（0.8.4 第二批）**：`organizeFiles` Agent 工具——按扩展名/日期/正则计划文件移动，先预览 → 用户批准 → execute=true 执行；跳过文件如实报告。纯逻辑 `FileOrganizerPlan` 进 harness。
- **素材库渠道变体生成（0.8.4 第二批）**：`addCampaignAsset` Agent 工具——复制源图到战役素材目录，按渠道规格（X 1200×675 / 小红书 1080×1440 / OG 1200×630 / 掘金/V2EX）用 CoreGraphics 居中裁剪生成变体，挂到战役 `assets`。纯逻辑 `CampaignAssetPlan` 进 harness。
- **表单填充（0.8.4 第三批）**：`fillForm` Agent 工具——按 selector+value+kind（text/select/checkbox）填表；提交按钮只定位不点击（人工批准红线）。纯逻辑 `FormFillPlan` 进 harness。


## [v0.8.3] - 2026-10-23
### Added

- **DPP 运营契约 `ops/1`（0.8.3 第一批）**：把运营工作台需要的能力变成 DPP 的稳定声明名——`opsAccount/opsPosts/opsMetrics/opsComments/opsMentions/opsSearch/opsComposer/opsAnalytics/opsCompetitor` 视图，`opsCompose`（只填表，local）/`opsPublish`（persist，必须批准）/`opsReply`（outbound，必须批准）/`opsSearch`/`opsRefresh` 动作，`opsReady/opsLoginRequired/opsBusy/opsPosted/opsError` 信号。纯逻辑校验器强制安全不变量（填表与提交分离、发布/回复必须走审批、run/视图结构完整），并输出能力集与警告；进 harness（1408/0）。
- **DPP Studio 自定义适配包工作台（0.8.3 第一批）**：设置 › AI › DPP 协议 › 第三方适配新增 Author…——载入 ops 模板或已安装包、编辑协议 JSON、校验契约、在当前标签页**只读试抽取**（打印前几条字段值，不执行 compose/publish/reply 动作），保存为**禁用草稿**（可显式勾选立即启用）。运营页新增 DPP Ops 就绪矩阵：每个渠道显示适配包/`ops/1` 能力/健康度（ok/suspect/autoDisabled），无适配时明确标注"通用降级"并提供 Author 入口。
- **官方运营适配包（0.8.3 第一批）**：`docs/dpp-adapters/ops/` 新增经公开 DOM 核对的 `v2ex-ops`（主题回复）、`hackernews-ops`（条目/用户评论）、`juejin-ops`（文章评论 + 只填不发的回复）、`juejin-compose-ops`（沸点填表 + 人工批准的发布）；README 写明契约、安装、验证与"需登录的渠道用 Studio 自建"的边界。适配包元数据新增 `opsVersion/verifiedAt`，健康记录持久化（最近成功/失败/错误），桥 `/dpp/adapters` 透出能力、ops 版本、校验错误与健康明细；Agent `saveDPPAdapter` 接入 ops 校验，默认保存为禁用草稿（`enabled=true` 才直接启用）。
- **运营日历 + 今日队列（0.8.3 第二批）**：运营页新增月视图，聚合草稿排期、已发帖、战役开始日与 Runbook 步骤；今日队列列出到期/逾期的草稿与步骤，可直接改期（明天/下周/清除）或交给 Agent。纯逻辑 `PromotionCalendar` 进 harness（月视图 42 格、逾期判定、周渠道计数）。
- **发布日 Runbook（0.8.3 第二批）**：战役菜单新增 Runbook…——按版本发布/功能发布/复盘模板生成 T-1/T0/T+1/T+7 时间线（每平台 4 步），落到日历并显示完成进度；发布步骤由同战役同平台的已发帖自动满足，其余步骤可手动勾选；重新生成会明确提示清空手动勾选。
- **互动回复台（0.8.3 第二批）**：互动台账改为按待处理/超时/优先级排序的回复台（SLA 24h 提醒、72h 逾期），每行显示等待时长与回复率；点开回复台可套模板、让 Agent 拟稿，或「Open & Fill」——优先用 DPP `opsReply` 声明的选择器填入回复（只读取声明，不执行动作），退回复用安全选择器，**永远停在发送前**；用户自己发送后 Mark Replied。
- **账号健康检查（0.8.3 第二批）**：DPP Ops 每个渠道新增 Check——在**后台标签**打开 composer，只读检查 `opsLoginRequired` 可见性 / `opsAccount` 条目 / `opsComposer` 是否可达，给出 Ready / Login required / Adapter missing / 无信号，然后自动关掉标签；不读 Keychain、不发布。判定逻辑进 harness。
- **运营简报 2.0 + 一键开始今天的运营（0.8.3 第三批）**：每日简报新增运营段——今日到期/逾期事项、待回复（含逾期）、进行中战役进度、DPP 运营适配就绪渠道数；空工作台不写"0 件事"。运营页标题栏新增 ▶ 入口，一键把「今日队列 + 互动台账 + Runbook 到期步骤」交给 Agent 开始当天运营（发布/回复仍需人工批准）。
- **增长实验生命周期（0.8.3 第三批）**：新增 Experiment——假设、主指标（浏览/点赞/评论）、变体、每个变体的计划样本数、战役范围、决策（进行中/采纳/否决/证据不足）。按 `variantLabel` + 已发状态 + 战役过滤统计；**每个变体都达到计划样本量才允许下结论**，并列不选赢家，样本不足只报进度；周报新增实验段，决策与结论随报告导出。纯逻辑 `PromotionExperimentAnalysis` 进 harness（1467/0）。
- **竞品/市场监测（0.8.3 第三批）**：运营页新增 Market Watch——添加竞品价格/功能/更新日志页面，Check 时在**后台标签**只读打开，优先用适配包 `opsCompetitor` 视图展平成行、否则读正文文本；与上次快照按行归一化 diff，只报告新增/删除行，无变化保持安静。变化可一键交给 Agent 转成选题；不登录、不点击、不做批量爬取。纯逻辑 `PromotionCompetitorDiff` 进 harness。
- **平台指标导入（0.8.3 第三批）**：无 DPP 适配/无采集端点时的兜底——导入平台导出的 CSV/TSV，自动识别分隔符与中英文列名（浏览/播放/阅读、赞/点赞、评论、URL/标题、日期），按 URL 优先、标题精确匹配帖子；导入前预览匹配结果，同一天快照覆盖而不是重复堆叠。纯逻辑 `PromotionMetricsImport` 进 harness（1488/0）。
- **归因转化 v1（0.8.3 第三批，跨栈）**：desire-api 新增迁移 `0017_growth_events`、公开匿名事件 `POST /growth/event`（page_view/download_click/first_launch，120 次/分钟/IP，限定产品页 CORS）与登录态聚合 `GET /growth/summary?days=`（总量/逐日/战役/来源）；**只存事件与 UTM 标签，不存 IP/Cookie/UA/账号标识**，表结构已核验无 PII 列。产品页新增 `website/growth-beacon.js`（UTM 透传、下载点击、DNT/localStorage 关闭、无 Cookie）；App 新增 Attribution 面板（与同步登录态共用，展示页面浏览→下载→首启漏斗 + 点击/安装率 + 逐日柱状 + 战役/来源 Top；未登录/无数据/未部署都有明确空态）与首启上报开关。本地 E2E 已验证：4 条事件入库、非法事件 422、未登录 401、campaign/source 聚合正确、CORS preflight 通过。**发版日需要部署 API 迁移与新二进制、并部署产品页 beacon**，步骤见 `docs/GROWTH-ATTRIBUTION.md`。





### Fixed

- **思考等级按服务能力映射（0.8.3）**：部分网关的取值表不是标准词——实测 AMD 网关返回 `Supported types are xhigh (default), medium, and low`，发 `high` 会 400（用户看到的"最高不支持"）。现在从服务端报错里解析支持列表并按 `endpoint|model` 记住：UI 选 Highest（high）映射到该服务的最大档 `xhigh`/`max`，Medium/Low 各取对应词；菜单只列这个模型真正支持的档位，明确不支持时才显示 Off + 原因。不再自动把全局设置改成 Off，也不再往对话里塞降级提示。
- **记忆面板搜索行溢出（0.8.3）**：搜索框 + 三段式筛选（全部/Pinned/Pending review）在窄面板下会横向超出窗口，右侧 "Pending review" 被裁掉。三段控件的最小宽度由系统决定，`ViewThatFits` 也压不下去；改为「搜索框吃掉剩余宽度 + 紧凑筛选菜单（当前项打勾）」，菜单只占自身内容宽，300pt 离屏渲染实测不溢出。
- **批量下载卡死占用并发槽（0.8.3）**：看门狗此前只处理"有进度时间 + 有 jobID"的项；从未回调进度、或 cancel 后 completion 丢失的项会永久占槽（第 10 个卡住、11/12 不开始）。现在无进度时回退到进入 downloading 的时刻；cancel 后 60s 仍无收尾则本机强制失败（attempts+1、释放槽位、继续队列），纯判定逻辑 `BatchStallPolicy` 进 harness。
- **B 站反广告拦截占位卡（0.8.3）**：B 站检测到广告拦截后会把广告位换成「该内容被 AdGuard/AdBlock 类插件屏蔽…」的灰色占位卡。离屏 WKWebView 实测真实 DOM：占位组件是首页推荐轮播里的 `.extension-tips-v2`，宿主为 `.vui_carousel__slide/.carousel-area`——**没有 card/feed/li 类名**，此前按类名扫描完全命中不到；且 CSS 隐藏后 `innerText` 为空，文案兜底也失效。现在按 `.extension-tips-v2` 整卡移除、CSS 用 `:has()` 首帧就不渲染、文案兜底改 `textContent`；同时补了新版播放器/信息流选择器与 1s 统计节流。本机本地规则覆盖已更新（`VideoAdRules/bilibili.js|.css`），重启并刷新 B 站可立即验证；下个构建内置后即可删除覆盖文件。
- **YouTube 假加载 / 自动播放时灵时不灵（0.8.3）**：实测同一条视频在 `allowAll` 策略下正常自动播放；在 `requireUserAction` 下画面已缓冲 20s 却 `paused=true, currentTime=0`，点播放立刻起播——根因是 WebKit 播放策略只在 webview 创建期烙入（空白新标签/从非视频页同标签跳进 YouTube 时已定格）。原补播只试两次（1.2s/3.2s），且页面在后台时直接跳过，开在后台标签的视频永远等不到。现在补播延到 30s 多档重试、每次按页面可见性等待、切回该标签时再起一轮；用户点在播放器/视频上即停手，SPA 换视频重置。离屏实测：requireUserAction 下 6s 补播从 `paused/0s` 进入播放。
- **批量视频任务在重新构建后消失（0.8.3）**：启动恢复此前只落盘 `running` 批次，完成的批次（面板里可回看/重试/删除的任务记录）从不写盘，进程一换就整行消失。现在 running 全部 + 最近 12 条 finished 一起持久化；启动时按原状态恢复（running 仍以暂停态等待继续，finished 保留完成/失败/跳过行，不自动续跑），取消的批次仍不落盘。文件仍沿用 `batch-media-unfinished.json`，旧文件没有 state 键按 running 处理。
- **YouTube 自动播放后一直缓冲（0.8.3，用户实测"自动播放了但马上失效"）**：广告拦截 CSS 把广告浮层/模块设为 display:none，但 DOM 节点仍在；旧版 `adShowing()` 只查选择器不看可见性，广告结束后隐藏节点仍让状态机永久判定"广告中"，媒体源被摘掉、静音，正片永远缓冲。现在浮层类信号必须真的可见（`.ad-showing/.ad-interrupting` 仍按播放器 class），并加 15s 兜底：媒体源摘除超时仍处广告态就还原并继续播放（宁可放跑一支广告也不毁正片）。本地 fixture 回归（隐藏浮层 + 广告 class 移除后 src 恢复、播放器退出广告态）通过。




## [v0.8.2] - 2026-10-22
### Added

- **运营战役 Growth Cockpit（v0.8.2，第一批）**：运营工作台新增 Campaign 层（目标 → 渠道 → 内容 → 数据），帖子可用 `campaignID` 关联战役；新增 6 个渠道档案（X / 小红书 / V2EX / 掘金 / 即刻 / Hacker News，含语气、长度上限、标签、composer 起点）。`PromotionCampaignBuilder` 从版本 + 事实亮点确定性生成各平台草稿（标题/正文按渠道裁剪、每条带 UTM 链接、排期按渠道错开），**全部以 draft 入库，绝不自动发布**；无亮点拒绝生成，避免空泛营销稿。运营页新增 Campaign 区块（进度/下一排期/状态菜单/交给 Agent 继续），新建 Campaign 表单可填版本、亮点、渠道与起点。桥新增 `GET /promotion/campaigns`、`POST /promotion/campaign/generate|status|remove`；Agent 新增 `promotionCampaign`（list/generate/status）。验收：桥生成 X/V2EX/小红书 3 平台 3 草稿，campaignID 正确关联、正文均含 UTM，状态可切 scheduled，测试数据已清理；harness 13 项（1293/0）。发布流水线（填 composer + 人工确认发布）、提及雷达、产品内分享入口仍待后续批次。
- **运营发布准备（v0.8.2）**：草稿行新增 Safari 按钮——打开渠道 composer（预设 composerURL，可覆盖）并把标题/正文填进常见输入框（contenteditable/textarea/input，按平台选择器尽力匹配），**绝不点发布**；界面与回执明确要求用户检查后自己按 Publish，成功后再 Mark Published 记 URL。填入失败会说"页面可能改版、请手动粘贴"，不假装成功。桥新增 `POST /promotion/publish/prepare`。验收：本地 fixture composer → 标题+正文均填入（`filledTitle/filledBody=true`），未触发发布按钮；测试草稿已清理。
- **提及雷达（v0.8.2）**：运营页新增 Mention Radar——可添加搜索引擎/社区入口（`{query}` 模板，预置 DuckDuckGo/Bing/V2EX/HN），离屏 webview 扫描关键词，抽取包含关键词的链接与上下文，按 URL 去重后写入互动台账（kind=mention）；不登录第三方、不自动回复。支持来源开关/删除、关键词扫描、上次扫描时间；桥新增 `GET /promotion/mentions/sources`、`POST /promotion/mentions/source|scan`。验收：本地 fixture 搜索页 → 首次 added=1、重复扫描 added=0，台账只有一条 mention，测试来源与条目已清理；harness URL 模板/去重/过滤 7 项（1300/0）。
- **产品内“分享 Desire”（v0.8.2）**：Help 菜单新增 "Share Desire…"——渠道化文案（X / 小红书 / V2EX / 掘金 / 即刻 / Hacker News）、带 UTM 的产品链接与二维码；文案可编辑、可复制，链接可复制/打开产品页；不发网络请求、不自动打开社交平台。桥新增 `POST /promotion/share`（channel/version → caption/url）。验收：桥对三渠道返回正确 slug/UTM/文案长度；harness 文案/UTM/回退/不过度承诺 7 项（1307/0）。UI 面板需真机打开 Help → Share Desire 过目。
- **提及雷达定时化（v0.8.2）**：每日 09:45 的内置任务直接跑确定性扫描（离屏 webview，不需要活会话/模型），扫描关键词取运营存储的 `mentionQuery`（默认 Desire），新提及进互动台账并发 routine 通知；运营页 Automation 新增开关，桥 `/promotion/review kind=mentionScan` 可安排/取消。验收：本地 fixture 来源 → 排程任务创建 → `/agent/tasks/fire` 立即执行 → 台账新增 1 条 mention；测试任务/来源/条目已全部清理。
- **Work Queue 2.0（v0.8.2 第一批）**：新增统一作业账本 `JobRecord`/`JobStore`（state/进度/产物/回执/错误/来源/外部 id，300 条上限只淘汰最旧终态），工具栏 ⋯ → "Jobs…" 面板按 Needs review / Running / Failed / Finished 查看，可打开 http 产物或本地文件、Dismiss 活动作业、删除/清空已完成。发布准备现在自动建作业（填完 composer → `needsReview` + 产物 URL + 回执；失败/找不到输入框 → `failed` + 原因），`Mark Published`/桥 status=published 会把对应作业标 done 并记 URL；提及扫描也自动建作业并写扫描回执。桥新增 `GET /jobs`、`POST /jobs/action`。验收：fixture 发布准备 → 作业 `needsReview` 且 artifact=composer URL → 标已发布 → `done` + URL；Dismiss 活动作业 → cancelled，clearFinished 生效；harness JobRecord 4 项（1312/0）。下载/定时/批量等旧子系统的 adapter 仍在后续批次接入。
- **Work Queue 旧子系统 adapter（v0.8.2）**：Jobs 面板与 `/jobs` 现在合并下载、批量媒体、媒体导出、定时运行、Agent 回合与 crew（经 ActivityCenter 只读投影），不复制状态、不写回；稳定哈希 id 保证刷新不跳行，旧子系统条目只提供 Activity 入口、不提供 Dismiss/删除。验收：`/jobs` 返回 8 条历史下载（activity 来源，done）且 summary 正确；harness 状态/类型映射、稳定 id、finishedAt 6 项（1318/0）；clean Release 零警告。
- **运营 Playbooks（v0.8.2 第一批）**：新增参数化可运行定义（名称/说明/指令/参数/输出方式/可选技能），首次启动种子 4 个运营模板：发版宣传、每周运营复盘、回复提及、网页引用简报。运营页新增 Playbooks 区块与运行表单（必填校验、默认值、选择项、Copy Prompt）；运行把参数与指令组合成一条 prompt 交给现有 Agent 回合（不是新执行引擎），并强制写明"发布/发送/提交/购买必须人工批准"与输出方式。桥新增 `GET /playbooks`、`POST /playbooks/run`（缺必填参数在发送前拒绝）。验收：4 个模板列出、缺参拒绝、prompt 含参数/规则/输出方式；harness 7 项（1325/0）；clean Release 零警告。自定义编辑器与定时运行留后续批次。
- **Playbooks 自定义编辑器 + 定时（v0.8.2）**：运营页 Playbooks 支持新建/编辑——名称、说明、指令、可选技能、输出方式（聊天/文件/笔记）、参数列表（key/label/默认值/choices/必填），保存前校验名称/指令/参数 key 唯一。每个 Playbook 时钟菜单可按默认参数排每日 09:00 或每周一 10:00，必填参数无默认值时禁止排程；桥 `POST /playbooks/schedule` 支持 schedule/remove。验收：每周复盘模板排程成功并出现在任务列表，随后移除；页面简报模板因无默认必填参数被拒，不产生任务；clean Release 零警告。
- **增长分析：A/B 变体标记与对比（v0.8.2）**：帖子新增可选 `variantLabel`（A/B/标题钩子等），promotionSave 工具与桥 `/promotion/post` 均可写；周报新增「A/B 变体」段，按平台 × 变体统计篇数与平均浏览（样本 <2 不出结论、无浏览数据不计入）；草稿/已发行显示变体徽标。验收：桥写入 X 平台 A/A/B/B 四条并采数据 → 周报输出 `B 平均 400 / A 平均 150`；旧帖子缺字段解码为 nil；harness 7 项（1331/0）；clean Release 零警告。
- **后台 Agent Runner（v0.8.2）**：没有活窗口时，定时/Playbook 等 Agent 任务不再直接记 "missed"，而是在**无头标签 + 隐藏会话**里跑完整工具循环（`TabManager(headless:)` 不注册、不落盘、不起挂起/内存计时器；会话不抢投递目标、不注册成窗口）。约束：同一时刻只跑一个后台作业；强制 `.confirmChanges`（后台不允许静默 fullAccess）；需要审批时作业停在 `needsApproval`，Jobs 面板可批准/拒绝，超 `agent.background.approvalSeconds`（默认 120s）自动拒绝；整作业 wall-clock 上限 `agent.background.timeoutSeconds`（默认 600s）；桥 `/jobs/action approve|deny` 可程序化决策。自动化钩子 `agent.background.force` 可强制走后台（不动用户标签页）。验收：假端点 + force 键 → 定时任务在后台跑完，Job `done`、run success、用户 5 个标签不变；审批/超时/预算路径已接线；测试任务/run 记录/假端点/偏好已全部清理；clean Release 零警告。
- **列表 → 表格采集作业（v0.8.2）**：新工具 `collectDataset` / 桥 `POST /dataset/collect` / 工具栏 ⋯ → "Collect Table…"——给起始 URL、行选择器、字段（`key=selector` 每行一条）、翻页方式（单页/下一页按钮/URL 模板 `{page}`/滚动）、上限与去重键，确定性抓取（不逐行调模型），去重后写 CSV 到 Downloads，作业进 Jobs 并带回执/产物路径。验收：3 页 fixture 共 30 行、重叠 10 行 → 去重后 20 行 CSV（表头+20 行，末行正确），pages=3；CSV 转义/字段解析/短名翻页解析 harness 6 项（1338/0）；测试 CSV 与作业已清理；clean Release 零警告。
- **收件箱接入作业控制面（v0.8.2）**：需要复核/审批或失败的本地作业（source 非 activity）现在进 Agent 收件箱 "Needs you"，带状态与类型、Open Jobs 入口（通知 Toolbar 打开 Jobs 面板）；工具条接收跨面板通知。验收：发布准备产生 `needsReview` 作业 → `/inbox` 出现 kind=jobAttention 条目（标题/详情正确）→ 清理后消失；harness 作业条目/id 反解 3 项（1341/0）；clean Release 零警告。
- **"Do this for me" 入口（v0.8.2）**：工具栏 ⋯ 顶部新增 Playbooks 快捷段（最多 6 个）——点选后弹出参数表单，运行结果直接送进当前 Agent 会话；无活会话时按钮无效（不会静默丢）。与运营页 Playbooks 共用同一份定义与 prompt 组合。验收：种子 4 个 Playbook 出现在菜单；运行表单参数/必填校验沿用；clean Release 零警告。














## [v0.8.1] - 2026-10-22
### Fixed

- **Keychain 授权不再卡死主线程（v0.8.1）**：2026-10-22 实测新构建启动时 SecurityAgent 授权窗未答，主线程卡在 `SecItemCopyMatching`，桥/UI 全部无响应（与"启动即死"只差一个看不见的系统弹窗）。现在 app vault 的读取走 `AppSecretsVault.preload()` 后台任务（主 actor 只 await），AppState 启动与同步首轮都先 preload；授权进行中 `syncNow` 返回"等待钥匙串授权"，`loadAPIKey` 返回 nil 而不是同步阻塞。验收：新构建带 pending 授权窗时 `/state` 仍响应、`sample` 主线程空闲在 run loop；`pkill SecurityAgent` 后应用继续可用（同步显示未登录，可重启/重新授权恢复）。稳定签名生效后授权窗本身也会消失。

### Added

- **稳定签名流水线（v0.8.1）**：新增 `scripts/setup-signing.sh`（生成固定 self-signed 代码签名 identity + p12/口令，打印 GitHub secrets 命令，**不自动上传**）与 `scripts/sign-app.sh`（CI 用临时 keychain 导入 p12、`codesign --force --deep --options runtime --timestamp=none`、验签）。`release.yml` 两个架构在版本校验后调用签名；secrets 缺失时明确打印 "leaving app unsigned (adhoc)" 并保持旧行为。`docs/SIGNING.md` 记明：adhoc 的 designated requirement 是 cdhash，固定证书后变成 `identifier + certificate root`，跨版本稳定；本机用临时证书对两份 app 副本签名验证 requirement 完全一致、`codesign --verify --deep --strict` 通过。**待你一次性执行脚本并上传 4 个 secrets 后生效**；私钥目录已进 `.gitignore`。
- **设置全文检索 + 深链（v0.8.1）**：设置侧栏顶部搜索框（53 条目录：分区/标题/副标题/中英文关键词，多词 AND、标题精确/前缀优先），命中后切换到对应分区；桥新增 `GET /settings/search?q=`（返回 section/title/subtitle/score/total）。验收：中文「同步」→ sync 5 条、「低电量」→ general Downloads、「keychain」→ AI/Sync/Autofill 相关；harness 7 项（1216/0）。
- **Agent 操作审计与撤销（v0.8.1）**：`writeFile`/`editFile` 成功后记录一条审计——动作前内容快照（≤8MB，存 `Application Support/Desire/agent-undo/`）、动作后 SHA-256；撤销前先比对当前文件哈希，文件被用户/其他工具改过就拒绝覆盖（不猜）；新文件撤销 = 删除。工作流回放记一条不可撤销审计。工具栏 ⋯ → "Agent Actions…" 面板可查看/撤销/清空；桥新增 `GET /agent/actions`、`POST /agent/actions/undo|clear`。验收：harness 模型 4 项（1220/0）；真模型/假端点 writeFile→editFile→undo 的全链 E2E 待补。
- **Agent 按站点审批（v0.8.1）**：审批策略从"按工具名"扩展到"工具 × 站点"——审批卡在已知页面 host 时提供 `Always on <host>` 与 ⋯ 菜单里的 `Never allow <tool> on <host>`，决定写入持久规则，之后只在**该站点**免问/直接拒绝；离开站点回到全局规则，host 规则优先于全局规则。dangerous 普通工具（executeJS 等）仍保持每次必问、不提供站点长期放行；DPP pageAction 沿用更细的「站点 × 动作」授权。审批历史带 host，桥 `/approvals/policy` 支持 `host` 增删、`/agent/approvals/resolve` 支持 `siteGrant`。验收：harness 匹配语义 7 项（host 归一/优先级/旧文件兼容/Codable，1232/0）+ 桥 CRUD 实测（`Bank.Test.` → `bank.test`，host 规则可增删）。
- **研究助手与引用（v0.8.1）**：新增只读工具 `researchSources(query, scope, limit)`——把当前页正文、打开的标签、历史正文索引、浏览历史、阅读列表与书签汇总去重后排序，返回带 `[n]` 编号、URL 与命中片段的引用块，模型据此写带来源的答案；无命中时明确要求"不编造引用"。排序复用历史正文检索的中英文切词（标题命中加权、当前页/标签优先、近因决胜），纯逻辑进 harness 8 项。研究模式提示词要求先收集来源并用 `[n]` 标注。桥新增 `GET /research?q=&scope=&limit=`（同一工具实现，非模型调用）。验收：fixture 页「量子火锅」→ 当前页 [1] 带正文片段；`scope=history` 命中同一 URL 的历史条目；无结果返回明确的"无来源"提示（1240/0）。
- **监视每日摘要与噪声过滤（v0.8.1）**：页面监视的文本归一新增噪声掩码——日期/时间、相对时间（刚刚/3 分钟前/5 hours ago）、千分位与带单位计数（views/次/点赞/浏览…）不参与 diff，避免时钟与计数器每分钟制造假更新；正文普通数字保留（精确价格盯梢仍走 numericSelector）。设置 → Page Watch 新增 "Daily digest"：每天指定小时把 24h 内变化/告警/错误汇总成一条 routine 通知（无内容不发、跨启动记住今天已发）；桥 `POST /watches/digest/config` 与 `GET /watches/digest` 的 digestEnabled/digestHour/lastDigestDay 可读写。验收：fixture 改时间戳/计数 → `changed:false`，改正文 → `changed:true` 且 changeCount=1；harness 噪声 6 项（1246/0）。
- **工作流定时 + 模板库（v0.8.1）**：工作流可离线定时回放——`scheduleWorkflow` 工具 / 工作流面板时钟菜单 / 桥 `POST /workflow/schedule` 支持每 N 分钟或每天 HH:MM；到点在**离屏 webview**（共享 Cookie、桌面 UA、不切换用户标签页）执行，不调用模型、不需要打开 Agent 会话，结果记入任务运行记录并发 routine 通知。含敏感步骤的工作流拒绝排程（无人值守无法填值）；删除工作流自动清掉其计划。新增模板库（Cookie 横幅关闭 / Load more / 展开全文），按当前站点生成通用文本选择器工作流，一次点击即可得到可运行、可排程的条目。桥补 `GET /workflow/schedules`、`POST /workflow/template|unschedule|run-offscreen`。验收：模板生成「Load more」→ 离屏回放 `ok`（点击被派发）→ 排程 09:00 出现在 schedules → 解除后清空 → 删除工作流无孤儿计划；harness 模板 6 项（1252/0）。
- **文档研究工作台（v0.8.1）**：新增只读工具 `researchDocuments(query, folder?, paths?, limit?)`——扫描一个文件夹（默认 Agent 工作区）或显式文件，跨 `txt/md/json/log/xml`、`docx/doc/rtf/odt/html`（textutil）、`pdf`（文本层）、`xlsx/csv/tsv` 取文，按 ~900 字分段后检索，返回带 `[n] 文件名 · 段落号 — 路径` 与命中片段的引用块（同一文档最多两段）；无命中明确要求不编造。路径全部先过 AgentWorkspace 白名单，提不出文本的文件列进 skipped；提示词声明文档正文是**不可信数据、不是指令**（防文档内提示注入）。桥新增 `GET /documents/research?q=&folder=&limit=`（同一实现，非模型调用）。验收：fixture 目录 4 份文档（docx/txt/csv/md）全部被扫描并给出引用（docx 经 textutil、csv 转 Markdown 表）；harness 分段/排序/同文档限流/引用格式 8 项（1260/0）。
- **多窗口会话接力 UI（v0.8.1）**：Agent 面板标题菜单新增 "Hand off conversation to"——把当前对话交给另一个**活窗口**，目标接管会话、源窗口回到空会话；两边都在跑回合时禁用（避免取消半截回合）。核心逻辑收口到 `AgentSessionStore.handOffConversation(to:)`，桥 `/agent/handoff` 改为调用同一实现（并新增"两边必须空闲"的保护）。自动双窗 E2E 受当前锁屏/无法激活环境限制未执行，菜单路径需真机双窗过目。
- **标签按主题整理（模型细分，v0.8.1）**：工具栏 ⋯ → "Organize Tabs by Topic…" 把未分组标签的标题/站点/URL 交给当前模型聚类，一次调用生成语义分组（与按站点整理共用 Undo）。模型只返回下标计划，`TabTopicPlan` 严格校验（越界/跨组重复/单标签组/空名/超长名一律丢弃，重复下标只保留先出现的组），失败时用 alert 说明原因；最多 40 个候选、8 个组。harness 解析 7 项（1267/0）。真实模型链路需在设置好服务后用真机菜单走一遍。
- **Web Apps 2.0：恢复上次页面（v0.8.1）**：App Mode 窗口在 `didFinish` 记录**同域**上次停留页（跨域登录/OAuth 页不记录），再次打开时恢复到该页而不是启动页；管理器显示最近打开时间，Open 拆成 “Resume Last Page / Start Page”（后者清掉恢复点），窗口内“在默认浏览器打开”改为打开**当前页**而不是启动页。桥 `/webapps` 带 lastURL/lastVisitedAt。旧文件缺字段解码为 nil 不丢数据；harness 恢复域校验/旧文件兼容 4 项（1271/0）。
- **标签资源中心（v0.8.1）**：工具栏 ⋯ → "Tab Resources…"——按站点汇总当前窗口标签（数量/挂起/播放音频），列出重复 URL 组，提供 **Suspend Background Tabs / Close Duplicates / 按站关闭**（关闭前确认，保留当前标签）。挂起会跳过正在出声的标签（自动挂起策略同步修正，不会再把音乐掐掉）；当前/分屏/固定/无痕标签不会被批量挂起；固定标签不参与去重、私密与普通页不跨模式合并。明确不展示 WebKit 拿不到的“每标签内存”。桥新增 `GET /tabs/resources` 与 `POST /tabs/resources/action`。验收：两个相同 URL 标签 → duplicates 1 组 → closeDuplicates 关闭 1 个；harness URL 归一/重复识别/站点汇总/可挂起排除/固定与私密去重 9 项（1280/0）。
- **站点动作栏（v0.8.1）**：锁图标弹层的站点设置新增 "Site Actions"——**Reader Mode**（当前阅读状态）、**Watch This Page**（30 分钟盯这一页，已盯则显示 Watching 并禁用）、**Record Workflow**（立即开始录制本站操作，录制中禁用）。把“针对本站做一件事”的入口集中到同一弹层，动作仍走既有 store/动作层，不新增平行实现。UI 需真机点开锁图标过目。












## [v0.8.0] - 2026-10-22
### Changed

- **密钥单条目 `app-secrets-v1`（v0.8.0）**：AI Key 与同步主密钥/access/refresh 合并进一条 Keychain 条目——启动/同步/Agent 首次读取都只碰这一条（一次授权），不再按档案/令牌各弹一次。同步沿用上一版 `sync-secrets-v1` 自动做种子并写回；旧 AI Key 首次使用某档案时才读那一条并迁入（不批量读），删除/更新也只改单条。`refreshKeyState` 继续只查属性，启动零逐档案读取。验收：启动 keychain 日志只有 `read app-secrets-v1`；同步状态指纹/登录态正常；harness 新增 AppSecrets round-trip（1181/0）。

### Added

- **密码填充显式入口（v0.8.0）**：页面检测到登录表单且本站有存档凭据时，显示非模态 "Fill Saved Password" 提示条——**页面加载零 Keychain 读取**（v0.7.31 为消除逐条弹窗关掉了自动填充，本版补上显式入口），点击才读这一条（一次授权）并注入；"Not Now" 关闭、无存档不显示。桥 `/passwords/delete` 支持按用户名删除单条（此前整域全删）。验收：fixture 登录页——加载前/加载中零 data 读、chip 出现、点击后恰好读一条并填入、取消不留痕。
- **浏览器数据导入（v0.8.0）**：设置 → System → Import Browser Data——自动检测 Chrome / Edge / Brave / Arc 档案与 Safari，也可手动选目录或数据文件。书签保留来源文件夹结构、按 URL 去重后挂到 "Imported from X"；历史按 URL 合并（visitCount 相加、时间取较新、500 条上限，不产生云端墓碑）；主页/启动页可选导入。SQLite 先复制到临时目录再交给 `/usr/bin/sqlite3 -json`（避免浏览器锁库与子进程 TCC 限制）；密码不解 Chromium Safe Storage/Safari Keychain，面板明确引导 CSV。桥新增 `GET /import/browsers`、`POST /import/preview|run`，`GET /bookmarks?tree=1` 与按 id 删除用于回滚/清理。验收：Chromium fixture 预览 3 书签/2 历史 → 导入 2 书签（1 条导入内重复跳过）+2 历史；Safari plist/History.db 预览 1/1；导入的根文件夹按 id 删除后子树清空。
- **网页应用 App Mode（v0.8.0）**：工具栏 ⋯ → "Install as Web App…" 把当前站点装成独立窗口（红绿灯 + 后退/刷新/标题/默认浏览器打开/关闭，无地址栏/标签栏）；安装时可选**独立 data store**或共享主浏览器登录。⋯ → "Web Apps…" 管理器列出已装应用，可打开/卸载（卸载清空独立数据并关窗）。桥新增 `GET /webapps`、`POST /webapps/add|open|delete`（open 经 NotificationCenter 交给有 openWindow 环境的主窗）。明确不是 Dock 级 .app bundle；`target=_blank` 留在同一窗口。验收：桥安装 example.com → 独立窗口标题/页面正确（截图）→ 删除后窗口关闭、列表清空；harness WebApp 模型 3 项（1190/0）。
- **历史正文检索（v0.8.0）**：设置 → System → "Search Page Text"（默认关闭）开启后，页面加载时抓取正文前 3000 字建立本地索引（无痕跳过、不进云同步、最多 800 页/同 URL 覆盖）；历史面板搜索时同时匹配正文，结果给命中片段，标题命中加权。英文按词、中文按单字（相邻双字加分），纯本地确定性排序。可一键 Clear。桥新增 `GET /history/content?q=`、`GET /history/content/stats`、`POST /history/content|clear`。验收：fixture 页开启→索引 1 页→搜「量子火锅」/「zorbax」均命中并带片段→清空+关闭后 count=0；harness 分词/命中/标题优先/片段 5 项（1195/0）。
- **更新后 What's New + 迁移助手（v0.8.0）**：按构建号每版自动弹一次（`--automation` 启动跳过，避免 sheet 遮挡桥/套件操作），列出本版亮点（浏览器导入、网页应用、正文检索、崩溃多窗恢复、单钥匙串、显式密码填充）；旧安装同步凭据待迁移时给 "Re-authorize" 按钮直达 Sync 设置。Help 菜单 → What's New 可随时重开；桥新增 `GET /whatsnew`、`POST /whatsnew/show|dismiss|reset`。验收：桥 show → presented=true（截图确认排版）、dismiss → hasUnseen=false、reset → true。
- **下载中心 2.0（v0.8.0）**：定时下载（下载面板时钟 → URL/文件名/开始时间；应用关闭期间到点的任务下次启动补跑；面板顶部 Scheduled 区可单条取消/全部取消；桥 `GET /downloads/scheduled`、`POST /downloads/schedule|cancel`）；重复下载检测（同一来源已有进行中传输，或完成的文件仍在盘上 → 跳过，不新建行；完成行走 Download Again 可强制重下）；低电量自动暂停并在恢复后只续跑"被我们暂停"的行（默认开，设置可关）；完成文件按类型归档（Images/Documents/Archives/…，默认关；用户在保存面板手选的目标绝不移动）。验收：fixture 定时 2 秒后完成、同一 URL 再排被跳过（下载列表仍只 1 行）、Scheduled 清空；harness 定时模型 3 项（1198/0）。低电量切换与归档移动为代码路径 + 设置开关，需实机低电量/下载走查。
- **标签整理（v0.8.0，第一档按站点）**：工具栏 ⋯ → "Organize Tabs" 把当前窗口**尚未分组**的标签按站点聚合——同站达到 3 个才成组（颜色按 host 稳定），已存在的分组与固定/无痕/新标签页不动；"Undo Organize Tabs" 一次还原到整理前快照。桥新增 `POST /tabgroups/organize|undo`。验收：4 个 example.com 标签 → 1 组 4 个、undo 后组消失且原组恢复；harness 分组/阈值/归一/颜色 4 项（1202/0）。模型按主题细分留待后续（当前规则确定性、零模型调用）。
- **工作流站点触发（v0.8.0）**：每个工作流新增 "Offer" 开关（Workflows 面板行）；访问匹配站点（同域/子域）且工作流**没有敏感步骤**时，页面加载后显示非模态「Run workflow “X” for this site?」——点 Run 才回放（零模型调用），Not Now 关闭；同一 URL 只提示一次，导航后重置。桥新增 `POST /workflow/offer`、`POST /workflow/suggestion/dismiss`，`/state` 每标签暴露 `workflowSuggestion`，`/workflow/list` 带 `offerOnVisit`。验收：fixture 录一个 click → offer=true → reload 后 `/state` 出现建议 → dismiss 清空 → 删除工作流；harness offer Codable/旧文件兼容 2 项（1204/0）。定时触发留到后续批次（本批只做站点触发，未假装完成）。
- **监视中心 2.0（v0.8.0）**：Page Watch 设置顶部新增 "Watch Center" 面板——列出所有监视（状态/最近变化/最近分析/数值/告警/错误），顶部给 24h changed/alert/error 计数；一键 Check All、Copy Digest（确定性文本，不调用模型）。桥新增 `GET /watches/digest`（text/changed/errors/alerts）。验收：空库摘要 "No changes"；新增 fixture watch 后变成 1 watched；harness 摘要（无变化/变化+分析+数值/错误/告警）5 项（1209/0）。每日定时推送与噪声过滤留后续（本批只做中心与可复制摘要，未假装完成）。









### Fixed

- **首次安装的钥匙串连环授权（下一版）**：旧启动路径把 6 个 AI 档案 Key、3 条同步令牌和 5 条网站密码全部用 `kSecReturnData` 读一遍——macOS 的 ACL 授权按**条目**弹，每条不同 key 各弹一次（用户实测 26 条 = 26 次，条目一多就无法使用）。现在**启动只查属性、不取 data**（ACL 只保护 data，属性查询不弹窗）：AI 档案用 `exists` 判断"已配置"，密码中心只列域名/用户名，同步只查存在性；真正需要秘密时才按需读一条（Agent 回合的当前档案 Key、面板显示/复制某条密码、显式同步）。同步凭据合并为单条目 `sync-secrets-v1`（主密钥/access/refresh 一个 bundle + 进程内缓存），旧安装的首轮迁移放在同步设置里显式触发（不自动读旧三条），迁移后每次升级最多只弹一次。页面加载不再自动填充存档密码（读密码会弹授权）——改为密码面板显示/复制或 Agent `fillLogin` 时按需读取。
- **崩溃/强杀后的多窗口会话恢复（v0.8.0）**：`persistAll` 每 15 秒把当前存活窗口的会话 key 写进 `session-index`；崩溃后首个窗口仍按最新会话文件恢复，其余 live key 入队，随后自动补开的窗口在普通恢复前认领各自那份（最多补开 4 扇）——此前强杀只会恢复一扇窗，其他窗口的标签留在磁盘但没人认领。验收：两窗口（用户标签 + example.com）等 20 秒后 `pkill -9`，重启得到两扇窗且各自恢复原标签。



## [v0.7.30] - 2026-10-21
### Fixed

- **钥匙串连环授权弹窗修复（v0.7.30）**：一个模型回合里正文/标题/记忆/自评/guard 会各自读一次 API Key（5–6 次），每次 `SecItemCopyMatching` 在 ACL 认不出 adhoc 构建时都会弹钥匙串授权。现在 `AgentPreferenceStore` 做**进程内 Key 缓存**（读取命中即复用；写入/删除同步更新；用户点"拒绝"后本进程不再重试），`refreshKeyState` 逐档案只做非交互读、**交互读仅限当前活动档案**（此前保存/切档案会把所有档案各弹一次）。验收：构建零警告；同一构建内一次授权后可覆盖整回合的 5–6 次调用。已知边界：ad-hoc 重建/升级后首个调用仍可能询问一次（ACL 认签名），点"始终允许"可持久。
- **下载面板弹出卡顿（v0.7.30）**：popover 的显隐此前绑在 `AppState.showDownloadsPanel`（@Published）上——每次打开/关闭都会让整个 ContentView（含 WKWebView representable）重绘，用户实测"下载窗口弹出卡顿"。现在改用独立的 `DownloadsPresentation` 单例（桥 `/panel` 与 `.showDownloads` 命令同源，只有工具栏观察它）；下载面板也不再观察批量媒体/媒体导出 store（进入"视频任务"后才由子视图观察），并去掉重复的文件存在性扫描。验收：构建零警告；桥 `/panel show:true` 能正常弹出（截图核对）。
- **YouTube 视频页黑屏与不自动播放**：全局"需要用户手势"档下，播放器的 `play()` 被拒后 YouTube 会把海报图留成 `display:none!important`——只剩纯黑 + 播放键，看起来像广告过滤"假加载"。现在视频平台（YouTube / B 站 / 腾讯视频 / 爱奇艺 / 优酷 / 芒果 TV / Vimeo / Dailymotion）在全局档下默认允许自动播放，站点控制中心与工具栏菜单可把单站改回阻断；同时新增 YouTube 起播补刀（画面停在 0 秒时调用 `playVideo()`，后台标签不抢播）与海报守卫（策略确实阻断时恢复缩略图）；空白新标签里再输入视频地址的"策略已在创建期定格"边界，也在 `didFinish` 用一次可信求值补播。桥新增 `POST /site-settings/autoplay` 与 `GET /site-settings` 的 `autoPlay/globalAutoPlay/siteAutoPlay` 字段。




## [v0.7.29] - 2026-10-21
### Fixed

- **会话批量删除崩溃/卡死修复（v0.7.29）**：崩溃报告显示 SwiftUI `ForEach.IDGenerator` 在分组 diff 时越界（SIGTRAP），根因是 `AgentHistoryGroup.id = UUID()` 每次重建都变；改为稳定的分组标题 ID。另修「全选 → 取消几条 → 删除」卡死：删除确认从阻塞 run loop 的 `NSAlert.runModal()` 换成 SwiftUI `.alert`，并把删除拆成两拍（先退出多选/清空选区，下一拍再改 store）。验收：用户实测通过。
- **工具栏溢出菜单显示不全/UI 不和谐（v0.7.29）**：30+ 项的自定义 popover 在 14 寸屏被截断。现在按 **Browse / Collections / This Page / View / Tools / App** 分组，统一 28pt 行高、图标列对齐、快捷键右对齐、hover 高亮、300pt 宽度；高度按屏幕可见高度的约 2/3 封顶并内部滚动，最后一项不再截半行。验收：用户实测通过。


### Added

- **网页工作流录制与回放（v0.7.29 旗舰）**：把用户在页面上的点击/输入/选择/SPA 导航录成可重放的步骤——注入 `workflow-recorder.js`（主框架、capture 阶段），每步存**多候选选择器**（data-testid → id → name → aria-label → 文本 → nth-child 路径）；**敏感字段（password / cc-* / 名字含 pass·card·cvv·token·otp·secret）只存占位符，值绝不落盘**。`WorkflowStore` 做站点过滤/200 步上限；`WorkflowPlayer` 按步骤执行（不调模型），支持起点导航、失败即停、逐步回执；入口 = 工具栏 Tools 菜单/⌘K 的 Workflows 面板、桥 `/workflow/start|stop|list|run|delete`、Agent 工具 `listWorkflows/startWorkflowRecording/stopWorkflowRecording/runWorkflow`；另可**从 Agent 轨迹回合一键提炼**（只取 navigate/click/fill，纯逻辑进 harness）。验收：本地表单 fixture 录制 4 步（密码敏感且值缺失）→ 重放终态一致；工作流/高亮纳入备份。
- **阅读高亮与笔记（v0.7.29）**：阅读视图选中文本 → 高亮（黄/绿/蓝/粉 + 可选备注），按页面 URL 持久化；锚点 = `quote + 前后各 40 字`，字号/主题重建 DOM 后仍能定位（`ReaderHighlightAnchor.locate` 纯逻辑进 harness）；阅读工具栏新增高亮/列表按钮，列表可跳转/改色/编辑备注/删除、**Copy Markdown**；数据纳入备份域 `readerHighlights`。验收：harness（锚点/唯一化/Markdown/Codable）+ 用户 UI 实测通过。
- **备份口令加密 v2（v0.7.29）**：导出时可选用口令保护——PBKDF2-HMAC-SHA256（60 万次）+ AES-GCM 包裹**整个归档**，文件头只留 `format/version/kdf/iterations/salt/ct`；导入自动识别加密文件并要求口令，**错误口令明确拒绝**，v1 明文备份继续可读；UI 在保存面板后询问「Encrypt / Plain JSON」，导入预览显示加密标记。验收：桥 E2E（加密导出无 `payloads`/书签名、预览 encrypted=true、错口令拒绝、正确口令按域导入、v1 预览 encrypted=false）。
- **活动中心（v0.7.29）**：⌘K / Tools 菜单新增 Activity——聚合**下载、批量媒体任务、媒体导出、定时任务、运行中的 Agent 会话与 crew**，统一状态/进度/相对时间，运行中置顶；面板每 3 秒刷新，可按来源筛选；桥 `GET /activity` 同源。验收：纯逻辑构建/排序/摘要进 harness（+8）；桥探针字段齐全。
- **崩溃后滚动位置恢复（v0.7.29）**：注入 `scroll-memory.js` 节流上报 scrollY，内容进程崩溃时先记住位置、重载完成后 `scrollTo` 恢复（普通导航不清错位置）；`/state` 暴露 `scrollY` 便于探针。验收：构建零警告 + 捕获路径桥探针；真实崩溃恢复走查。
- **设置直达与阅读站点偏好（v0.7.29）**：⌘K 收录 10 个设置分区（General/Agent/Floating Ball/Page Watch/Sync/Remote/Privacy/Autofill/Keyboard Shortcuts/Batch Downloads），执行即打开设置并选中该分区；阅读工具栏新增「Remember for this site / Use global settings」，字号/行距/主题可按 host 记忆。验收：构建/面板走查。







## [v0.7.28] - 2026-10-21
### Fixed

- **标签挂起的内存压力标志是粘性的（v0.7.28 修复）**：`TabManager.memoryPressureActive` 置 true 后从未复位——首次内存警告之后**每次 60s 巡检都会把全部后台候选挂起**，后台标签越用越少。现在：巡检消费后复位；内存事件补 `.critical`（立即巡检，不等下轮）与 `.normal`（清除标志）；标签右键新增 **Unload Tab**（手动释放，选中/新标签页禁用，点标签即恢复）。

### Added

- **统一备份与恢复（v0.7.28 旗舰）**：设置 → 通用新增 Backup & Restore——把**设置（同步目录 23 键）/书签树/历史/阅读列表/快拨/Agent 记忆**打包成一个版本化 JSON（`BackupArchive`：按域存 payload + counts，未来版本拒绝导入）；**不包含 Keychain/API Key/同步主密钥/对话正文**。导入支持 **Merge**（书签按 URL 去重后放进 "Imported <日期>" 文件夹；历史/阅读列表/快拨只补缺；设置保持现状；记忆事实按近似重复去重、摘要按会话 id 去重、画像只填空白）与 **Replace**（整体还原，UI 二次确认）。桥 `POST /backup/export|import`。验收：harness **1120/0**（+7：归档 round-trip/域解码/未来版本拒绝/坏数据/设置值 round-trip）；**桥 E2E 2/2**（真实数据导出 144KB、六域 counts 正确；原样 merge 导入 0 新增；密钥模式扫描零命中）。
- **阅读模式修复与增强（v0.7.28）**：① `readerContent` 现在携带 `location.href`，阅读视图用页面 URL 作 baseURL——**相对图片/链接不再全裂**；② 阅读视图接管链接（含 target=_blank）：点击关闭阅读模式并在原标签打开，不再困在阅读视图里；③ 主文档导航提交到新 URL 时自动退出阅读模式（地址栏/前进后退切页不再显示上一篇的阅读内容）；④ 按 URL 记忆滚动位置（字号/主题切换会重建 webview，重新打开也不回顶部）；⑤ 提取器清洗内嵌 nav/aside/footer/script/表单、还原 data-src 懒加载图片、把 a/img 相对地址转绝对。验收：Debug 构建绿；相对资源/链接/滚动恢复需本地 fixture 走查（提取器逻辑可在页面上下文单测）。
- **浏览器诊断（v0.7.28）**：新增 `BrowserDiagnostics`——内容进程崩溃**持久计数 + 最近 20 条**（URL/时间/是否自动重载）；设置 → 诊断行显示 "N content crash(es)" 并悬停给最近一次详情；桥 `GET /diag/browser`。修复防崩溃循环命中时横幅仍写"页面已自动恢复"的误导文案（现在如实写"已停止自动刷新"）。验收：桥探针 1/1（字段齐全、初始 0）；崩溃路径走查（白屏/横幅文案）。
- **可访问性横切（v0.7.28）**：`HoverIcon`（66 处调用）统一把 `help` 作为 accessibilityLabel（无 help 时退回 SF Symbol 名）——VoiceOver 不再只念"按钮"；全部动画令牌（hover/transition/spring）接 `NSWorkspace.accessibilityDisplayShouldReduceMotion`，系统开启"减弱动态效果"时返回 nil（状态照常切换，只是不动画）。验收：构建零警告；Reduce Motion 开关前后行为走查。
- **历史批量删除与站点筛选（v0.7.28）**：历史页新增 **Select** 选择模式（复选框 + 底部 Delete N）、站点组头新增漏斗按钮（只看该站，可一键清除筛选）；搜索与站点筛选可叠加。验收：构建绿；面板视觉走查。
- **备份选择性恢复与预览（v0.7.28 旗舰补全）**：导入前先读文件头展示**格式版本/导出时间/应用版本/各域条数**，并按域勾选要恢复的内容（设置/书签/历史/阅读列表/快拨/Agent 记忆）；Merge 与 Replace 的文案随选区分开，未来版本文件明确拒绝。桥补 `POST /backup/preview` 与 `import` 的 `domains` 过滤。验收：桥探针 **3/3**（真实数据导出六域计数正确；预览字段齐全；`domains:["history"]` 合并只返回 history 且 0 新增）。
- **历史云归档搜索 UI（v0.7.28）**：历史页搜索框旁新增云图标——登录态下按需拉取加密归档、**本地解密过滤**（服务端不可读，这是端到端加密的必然形态），结果显示在独立 "Cloud archive" 分节、可点开；未登录时明确提示。验收：构建绿 + 面板走查（登录态真库命中沿用 v0.7.25 的桥探针 3/3 口径）。
- **阅读列表搜索与筛选（v0.7.28）**：面板顶部新增搜索（title/url/摘要）与分段筛选 **All / Unread / Offline**，可与搜索叠加；纯逻辑 `ReadingListFilter` 进 harness（4 项：摘要命中/未读/仅离线/叠加）。
- **记忆面板搜索与筛选（v0.7.28）**：长期记忆列表新增搜索（content/category/source）与 **All / Pinned / Pending review** 筛选；纯逻辑 `MemoryModels.filterFacts` 进 harness（5 项）。
- **Agent 回复朗读（v0.7.28）**：助手消息操作行新增喇叭按钮——端上 TTS 朗读（零费用/数据不出机），朗读中变停止；切换会话自动停；轻量去掉 Markdown 标记避免念出星号。验收：构建绿 + 手动走查（中英文/停止/切会话）。
- **诊断包升级（v0.7.28）**：设置页导出的诊断 zip 现在额外包含**最近 30 分钟的进程内 OSLog**（`OSLogStore(scope: .currentProcessIdentifier)`，只含本应用）与 `browser-crashes.json`（崩溃计数/最近 20 条）；桥 `POST /diag/export` 同源。验收：桥探针导出 zip，oslog 文件 232KB 非空、崩溃摘要存在。
- **可发现性收口（v0.7.28）**：⌘K 命令面板与文件菜单收录 **Export Backup Now** / **Export Diagnostics…**——新能力不再只藏在设置页深处；两者都走既有 CommandBus（不新增平行执行路径）。













## [v0.7.27] - 2026-10-21
### Added

- **crew 运行观察面收尾（v0.7.27 旗舰）**：逐 worker 记录模型与 token，面板/桥按 worker 展示 token 与金额（未定价只显 token，沿用 `AgentUsage` 口径）；终态 worker 不再从条子里消失（保留已用时/工具数/结果悬停）。顺带修两个真 bug：tab 消失与模型异常这两条提前失败路径此前**不调用 `settleIfDone`**，最后一个 worker 这样失败时 crew 永远不落定；`WorkerTask.task` 从未赋值（取消实际靠 state 标志），已移除死句柄并让取消立即发布终态。验收：harness（解析/汇总）、Debug 构建绿；逐 worker 金额待真端点 crew 探针。
- **收件箱批处理补齐（v0.7.27）**：多选批量**重试失败任务**（`AgentScheduler.fireNow` 逐任务触发，旧失败条目自动稍后一小时隐藏）、任意条目右键「稍后 1 小时 / 忽略」、按类型筛选 chips（只隐藏 UI，不改数据）、桥 `POST /inbox/batch`（retry/ignore/snooze）。任务名从条目 id `run-<任务名>-<时间戳>` 解析（名字可含连字符），纯逻辑进 harness（5 项）。验收：harness **1100/0**；桥探针 **2/2**（`/inbox` 正常、`/inbox/batch` 对不存在的任务返回 skipped 且不产生副作用）。
- **旁路成本入账收尾（v0.7.27）**：新增 `AgentSessionStore.recordBypassUsage`（记到最新活会话的尾助手消息），补齐此前完全不记账的六类旁路——**心跳巡检 / 阅读列表摘要 / 双语对照 / 技能提炼 / 网页分享卡 / 标签聚类**（`kind` 分别为 heartbeat/readingList/bilingual/skillDistill/shareCard/tabGroup）。没有活会话时静默丢弃（这些调用不属于任何对话成本）。至此除 failover（复用主回合用量）外，所有旁路模型调用都进入 `bypassUsage`，面板成本弹层/轨迹/统计自动可见。验收：Debug 构建绿；六类调用点均带 `onUsage`（逐类真端点回执待 crew/心跳探针）。
- **轨迹复盘卡增强（v0.7.27）**：每回合展开新增**耗时分布条**（按工具聚合、占比前三分色标注）、**同参数失败重试计数**（`(工具, 参数)` 归组且至少失败一次 → 多出的次数；折叠摘要显示 `N retries`）、**按模型/旁路的成本拆分**（复用 `CostBreakdown`，主回合/子代理/旁路逐组 token 与金额）。纯逻辑 `TurnReview.timeDistribution/retryCount` 进 harness（4 项）。
- **评估集闭环（v0.7.27）**：轨迹页的导出菜单可把一份 JSONL 导出**登记为 agent-eval fixture**（应用层 `SecretRedactor` 脱敏后写 `~/Documents/DesireAgent/eval/fixtures/fixtures-<时间>.json`，格式与 `tests/agent-eval.py --fixtures` 完全一致），并可在应用内列出/删除 fixture；桥新增 `POST /agent/eval-fixture/register`、`GET /agent/eval-fixtures`、`POST /agent/eval-fixture/delete`。纯逻辑 `EvalFixture.convert` 进 harness（8 项：坏行/空 goal/去重/上限/截断/round-trip）；**桥 4/4**（登记 2 条并去重、列表 1、删除、列表 0；fixture JSON 与 CLI 同构）。
- **记忆冲突注入保护（v0.7.27）**：自动抽取的新事实若进入待复核队列，**在用户确认前不再注入 `<user_memory>`**（此前已入库并参与提示，矛盾内容会直接影响回复）；面板冲突横幅新增「Keep all new / Keep all old」批量决议（保留新 = 删相关旧条，保留旧 = 删新入库条），一次清队列一次落盘。纯逻辑 `MemoryModels.injectableFacts` 进 harness（2 项）。







## [v0.7.26] - 2026-10-21
### Added

- **路由审计与失败回退（v0.7.26，在既有 RoutingProvider 之上）**：应用早有成本感知路由（端上/ollama 优先、`RoutingDecision` 纯逻辑、`via X` 标签）——本轮补三个真缺口：① **审计**：每条助手消息新增 `routeReason`（`via Cloud/On-device/…`，路由在工具链中变化时如实反映最后一次决策），桥消息透传 `model`/`routeReason`/token；② **失败回退**：自动路由（端上/ollama 优先）失败且未流出任何内容 → **强制云重试一次**（本地模型不可用绝不换卡死）；③ **桥状态**：`GET/POST /ai/routing`（costAware/providerKind/lockedToCloud/lastProviderUsed）。验收：harness **1081/0**（审计字段编解码兼容）；**真端点探针 4/4**（routing 模式下短问句回答正常、`routeReason=via Cloud`、lastProviderUsed 一致）。**规划期教训**：原计划"新增成本感知路由"是错的——漏查既有实现（`costAwareRouting`/`RoutingProvider`），平行实现已全部回滚。
- **划词就地卡（v0.7.25 旗舰）**：划词条的"解释/翻译"不再绕道 Agent 面板烧回合——**旁路模型流式**输出贴在划词处的就地小卡（解释/翻译/词典三模式；**词级输入自动走词典**：读音/词性/释义/例句），卡上动作 = 复制/朗读/进白板/追问（追问才开面板并带上文）；无 Key/失败优雅降级（失败态 + 转面板指引）。桥 `POST /selection/assist`（与服务同源；不产生会话消息）。验收：harness **1052/0**（+10：模式判定 CJK/拉丁/超长/空、提示词契约、三模式标题）；桥探针 **7/7**（真端点：serendipity→词典含音标例句、句子→解释、hello world→"你好，世界"、**会话消息数不变 = 不烧回合**、空文本/非法 mode 拒绝）。已知边界：就地卡视觉走查留用户；旁路调用暂不计入对话成本（与标题/记忆整理同类，沿用既有缺口）。
- **工作区同步域（v0.7.25，第十域）**：标签组快照（`WorkspaceStore`）跨端——每工作区一文档（client_id = HMAC(工作区 UUID)），**savedAt LWW**；`sessionState`（页面还原 blob，机器本地）在载荷里剥掉，远端标签按 url/新标签页/pin 重建（tabID 新生成）；删除走**显式墓碑**（单独键持久化——不动既有 `[Workspace]` 文件形状、旧文件零迁移）；默认关（同白板——个人上下文），设置页类目行随 `SyncDomain.allCases` 自动出现。验收：harness **1061/0**（+9：payload 组装/编解码 round-trip/载荷不含 sessionState/LWW 新盖旧忽略同刻幂等/墓碑新旧两支/体量护栏）；dev-server 双客户端 E2E 待下次 dev-server 会话（本机容器未起，手法沿用既有域）。
- **每日简报内置流水线（v0.7.25，第二个 builtin）**：复用 v0.7.24 的 builtin 任务框架——`builtin=dailyBrief`：今日会话/消息数、token 用量与轮数、新记忆（带样例）、收件箱待办（带明细）→ 会话备注 + routine 通知（`agent.dailyBrief.toBoard` 开启则顺带上板）；**纯确定性、零模型调用**，空日不编造（只有两行）。触发面：内置定时任务（桥 `/agent/tasks/create` builtin=dailyBrief；未知值拒绝）/ 桥 `POST /agent/daily-brief`。验收：harness **1068/0**（+7：富输入六行/空日不编造/样例与明细/日期头）；桥探针 **7/7**（真机数据出简报 + 任务创建/列表/清理 + 未知 builtin 拒绝）。
- **同步状态指示器（v0.7.25 可发现性）**：工具栏常态同步健康点（**未登录灰 / 同步中蓝 / 错误橙 / 正常绿**，悬停给一句话，点击打开设置）——此前只在失效时才有通知/横幅，日常"同步还好吗"无处可见（11 天静默断联事故的另一半收口）。状态优先级 = 未登录 > 同步中 > 错误 > 正常（同步中的瞬时错误不闪红，下一轮落定）。验收：纯逻辑 `SyncHealth` 进 harness（**1073/0**，+5：四态派生与提示齐全）；指示器视觉走查留用户。
- **截图浮层分享卡（v0.7.25）**：截图工具条新增"分享卡"动作——**选区裁剪图 + 页标题/域名**合成白卡 PNG 存下载目录 + routine 通知（复用网页分享卡渲染器；选区是图片、不跑摘要——摘要走整页分享卡）。验收：构建绿 + 渲染器已由整页分享卡探针证明（尺寸/digest 三方/成图目视）；浮层交互走查留用户。
- **归档历史检索（v0.7.25，范围修正）**：原计划"服务端历史检索接口"被 **E2E 加密**挡住——服务端存的 `sync_history_items.payload` 是 AES-GCM 密文（设计如此，服务端不可读），服务端全文检索会破坏端到端加密。正解：**客户端按需全量拉取 → 本地解密 → 过滤**（从 since=nil 分页拉、页数设上限、本次运行内缓存，退出登录清空）。Agent 新增只读工具 `searchHistory`（本地 500 条优先 + 归档去重补充，标注 `[local]`/`[archive]`；未登录时本地照常+归档不可用的说明）；桥 `GET /history/archive-search`。验收：harness **1079/0**（+6：大小写不敏感/同 URL 去重保留最新/空查询倒序/limit 封顶/URL 命中/无命中）；**生产真库实测 3/3**（未登录路径曾被意外覆盖——你已重新登录：`man kong` 账号、密钥在；`q=crates.io` 命中 3 条带时间戳、空查询返回最近 5 条上限内、无命中 ok+0）。
- **会话接力（v0.7.25，多窗口互通）**：把当前对话**交给另一窗口接管**——桥 `POST /agent/handoff {"window": <live session id>}`：源窗口先落盘（`flushConversation`）→ 目标 `loadConversation` 接管（同一 conversationId）→ 投递目标（deliveryTarget）切换到目标窗口 → 源 `clear()` 回空会话（不持有旧对话，避免退出时旧副本覆盖目标的新内容）。验收：双窗真机探针 **7/7**（源会话建立/接力带同一会话/目标接管/投递目标切换/源回新会话/目标续写落在同一会话且消息增长/轨迹会话一致；两段测试对话已清理）。**测试发现**：桥 `/command newWindow` 走 SwiftUI `openWindow`，在桥上下文里**静默无效**（返回 ok 但没开窗）——自动化开第二窗要系统级激活 + ⌘N 键盘注入（已记入 AGENTS.md 测试要点）。
- **预算可视化（v0.7.26）**：成本路由开关旁新增 **Session Budget** 选择器——0（关闭）/ 10 万 / 50 万 / 100 万 / 200 万 token，**自定义历史值原样显示**（用户机器上遗留的 500 正是此前"只能经工具/桥/UserDefaults 改、界面不可见"的后果）；副标题说明"到档位上限回合停在步骤边界"。验收：构建绿 + 选择器与 store 同源（`tokenBudget`）；视觉走查留用户。
- **划词卡成本入账（v0.7.26）**：`SelectionAssistService` 收集流式 `usage` → 归账到**会话内最近一条助手消息**（`bypassUsage` kind=`selectionAssist`，token 并入其总量）——v0.7.25 留的最后一个旁路缺口；UI 卡片与桥 `/selection/assist` 同一归账路径。验收：真端点探针 **2/2**（词典调用后该消息 `promptTokens` **75470 → 75668，+198**）。
- **启动预算进 /state（v0.7.26）**：`GET /state` 新增 `startup: {firstWindowMs, budgetMs}`（首窗可交互毫秒数，预算 400ms 沿用既有日志口径）；套件在启动后断言 `firstWindowMs ≤ 2000ms`（阈值放宽以避开 CI 冷缓存抖动，只抓"启动路径真的坏掉"的大回归）。此前该指标只有统一日志，没有任何程序化消费。
- **本对话成本明细（v0.7.26）**：面板状态行新增**成本 chip**（token 常显；金额只在全部可定价时显示，沿用 `AgentUsage` 的 `≥` 口径）——点开弹层按 **模型 × 类型** 拆开：主回合 / 子代理（工具消息上的用量）/ 旁路（标题/记忆/自评/守护/划词卡逐笔），每行 token + 金额（未定价如实写"未定价"），底部合计与面板同一 `AgentUsage` 口径。纯逻辑 `CostBreakdown.derive` 进 harness；桥 `GET /agent/cost-breakdown`。验收：harness **1088/0**（+7：主回合扣旁路/未定价 nil/子代理分组的 kind/旁路按 kind/排序/合计与 AgentUsage 同源）；**真端点探针 3/3**（实际对话拆出 main 75468 / 旁路 selectionAssist 104 / 旁路 title 94，未定价→不显示金额）。
- **路由审计进轨迹（v0.7.26）**：轨迹每回合新增 `route` 字段（既有 RoutingProvider 的 `via Cloud/On-device`），轨迹页展开时显示 Route 行，桥 `/agent/trace` 的 JSONL 同步可读。验收：**真端点探针 2/2**（routing 模式下该回合 `route=via Cloud`，模型/成本字段齐全）。
- **定价编辑增强（v0.7.26）**：成本区**按服务档案分组**（各服务的模型与其候选清单归组，已填价的其它模型落 "Other models"），并新增 **Import / Export**：导出形状 = **桥 `/ai/prices` 同款** `{model: {input, output}}`（同一份文件 UI 导入与桥 POST 都能直接用，可批量填价）；导入按模型 id 合并（列出的覆盖、未提及的保留）、负值钳 0、坏 JSON 明确报错。纯逻辑 `ModelPriceTable` 进 harness。验收：harness **1095/0**（+7：导出→解析 round-trip/简写键/负值钳制/非对象跳过/坏 JSON/空表/合并语义）；桥 `/ai/prices` 写入→读取→清理 **2/2**；分组与文件选择器视觉走查留用户。





### Fixed

- **OAuth 弹窗登录修复（v0.7.25）**：crates.io 的"Log in with GitHub"永远登不上——根因 = 新窗口策略把 `window.open` 弹窗**一律转成标签**，而回跳页（`crates.io/github-redirect.html`）靠 `window.opener.postMessage` 把授权码交回原页；转标签后 **opener 为 null**，回跳页静默什么都不做（现场证据：该页 DOM 空、`window.opener === null`）。修复：`createWebViewWith` 区分两类新窗口——**脚本文档开的（navigationType == .other）或带显式尺寸的 → 真弹窗**（用 WebKit 交给我们的 configuration 建 WKWebView 放进独立窗口，opener/cookie/进程池自动接好；页面 `window.close()` 经 `webViewDidClose` 关窗、KVO 同步窗口标题）；**链接的 target=_blank 仍转标签**（既有 UX 不变）。验收：本地 fixture（opener postMessage + window.close）修复前 FAIL（登录页标题不变且多出标签）、修复后 PASS（标题变 "GOT ABC"、弹窗自关无残留标签）；**真站实测**：crates.io 点击 Login with GitHub → 弹窗完成授权 → 原页登录成功（截图确认 SiwiLiZhao 个人页）。
- **首启无主窗缓解（v0.7.26）**：强杀（`pkill -9`）/崩溃后首启偶发"桥活着但 tabs=0、无 Agent 会话"（根因指向 SwiftUI 场景恢复；优雅退出可修复）。处理：主窗/设置/引导三个场景关掉 SwiftUI 恢复（`.restorationBehavior(.disabled)`）——应用本就有自己的会话恢复（`SessionRestore` 采纳 index 最近会话），SwiftUI 的窗口恢复是冗余且不可靠的那一层；主窗由 `.defaultLaunchBehavior(.presented)` 每次重新呈现。验收：**连续 5 次强杀重启均 1–2 秒出主窗（5/5）**；工具侧（预检/发版 verify/套件）改为 tabs≥1 判据 + 优雅退出重试（昨日已落地）。


## [v0.7.24] - 2026-10-19
### Added

- **白板批注与评论（v0.7.24 旗舰）**：白板从"独自创作"变"可批注"——评论**挂在块上**（选目标块或整板），侧栏按**未解决在前**排（新→旧），一条评论可"标记已解决/重新打开"、可删除；工具条气泡按钮带未解决红点计数。评论随**白板域整板文档同步**（零新增域、零成本搭车；旧文件/旧载荷缺键按 nil 解码兼容），改动走既有 apply 路径 = **白送撤销/落盘/同步标脏**。配套：桥 `POST /whiteboard` 新增 comment/comment-resolve/comment-delete 三动作 + `GET /whiteboard` 回读评论（blockNumber 1-based，0=整板）；远端快照载荷带评论段（未解决在前、文本截 200、≤6 条、真实编码字节预算内）——**iOS 板详情页可读**（只读，写评论在桌面）。验收：harness +18（编解码 round-trip/旧文件兼容/200 条上限丢最旧已解决/排序/载荷落地/远端契约）；桥探针全 PASS（创建/读回/解决翻转/远端排序/删除/空文本与越界拒绝）；macOS 与 iOS 双端构建绿。已知边界：画布上不做块徽标（前端 bundle 不动，块号标签已足够定位）。
- **同步会话失效提醒（v0.7.24）**：针对 10-19 走查发现的真实事故（本机同步会话失效后**静默断联 11 天**无人察觉——自愈登出只写 lastError，未登录表单不展示）。现在自愈登出时发一条 **routine 系统通知**（"服务器拒绝了会话，请重新登录；数据与密钥不受影响"，一次性——回到未登录态后自动同步停摆，不会重复打扰）；未登录表单顶部新增**失效横幅**（橙色警示 + 恢复指引），用户不再面对"莫名其妙退出了"的空白表单。验收：双端构建绿 + 路径走查；**401 实弹演练**（dev server 旋转 JWT 密钥 + 删 refresh 行）待下次 dev-server 会话补断言。
- **白板 PDF 导出（v0.7.24）**：导出条新增 PDF——整板离屏渲染（与 PNG/分享卡同源的 BoardRenderService）→ **A4 逐页纵向切分**（纯布局数学 `WhiteboardPDFLayout` 进 harness：横向不切防切断图表、恰满一页不多出空白页、NaN 防护）；不画分享卡头部（PDF 是打印/归档形态，板名走 PDF 元数据 kCGPDFContextTitle）。桥 `GET /whiteboard?format=pdf`（base64 + 页数；空板明确报错）。验收：harness +6；桥探针（PDF 魔数/%%EOF 尾标记/页对象数==API 页数/空板拒绝）+ PDF 目录对象 `/Count` 独立核对 = 2 页 + 首页成图目视（内容与边距正确）。
- **报告流水线（v0.7.24）**：把三件现成部件连成一条**确定性、零模型调用**的管线——WeeklyDigest 汇总（会话备注 + routine 通知 + 到点记账）→ **空板铺"周报"模板并改名** → 追加摘要 note 块（**非空板只追加、绝不覆盖**）→ 可选写备忘录（NotesBridge；失败非致命、如实回报）。两个触发面：设置页"生成并上板"按钮 + **内置定时任务**（`ScheduledTask.builtin`：`builtin=weeklyReport` 到点不投递 prompt、改跑管线，run 记录 success/failed；桥 `/agent/tasks/create` 支持 builtin 参数，未知值明确拒绝）。桥 `POST /agent/weekly-digest {"action":"run-pipeline"}`（`writeToNotes`/`conversationId` 可选，探针用显式会话避免触碰正在看的板）。验收：桥探针 **14/14**（首跑铺模板+摘要/二跑只追加/板名带日期/末块=摘要 note/首块=模板/内置任务创建/列表/未知 builtin 拒绝/清理；**触发步因有活会话会写用户板而跳过**——分支代码走查）。备忘录实弹留待用户（AppleScript 首次授权弹窗）。
- **截图标注增强（v0.7.24）**：两件——① **放大镜工具**（工具条新增）：拖框选源区域 → 圆形镜头以框中心为锚 **2× 放大**（直径 = 框长边、下限 24pt、圆环描边），渲染走既有 ScreenshotAnnotationRenderer 单 case 扩展；**像素级探针**（tools/screenshot-render-probe.swift，编译即跑）断言判别位：镜头内 (44,50) 采样源 (47,50) 越过分割线 = 蓝——**未放大时该点为红**，证明放大真的生效；外加镜头外不变/圆环可见/小拖框钳制，**6/6**。② **OCR 表格转 Markdown**：Vision 结果补归一化包围盒（与 lines 对齐，左下→top-down 翻转），纯逻辑 `OCRTableDetector`（进 harness）做行聚类（0.6×中位行高容差）→ 取"列数一致且 ≥2 列"的最长连续段 → 列对齐校验（中位偏差 ≤0.05，**宁可漏不可错**）→ 重建 Markdown（管道转义）；OCR 浮层在识别出表格时多一个"复制表格"按钮。验收：harness **1014/0**（+6：2×2 重建/散文不误判/列不对齐拒绝/单行拒绝/3 行+转义/y 抖动聚类）+ **真 Vision 链路探针 6/6**（渲染真表格图 → 实际识别 → 重建出完整三行表，tools/ocr-table-probe.swift）。
- **网页分享卡（v0.7.24）**：浏览器 ⋯ 菜单新增"Page Share Card"——活跃标签 → 首屏截图 + 标题/域名 + **旁路模型摘要**（bypassPreferences 优先；无 Key/失败静默降级、卡片照出）→ 白底卡片 PNG（头部/首屏/摘要 4 行封顶/页脚）存下载目录 + routine 通知。折行/清洗/高度全是纯逻辑 `PageShareCardLayout`（进 harness：CJK 45 字/行估算口径、超行末行削齐补 …、纯 URL 行剔除、太短 nil、总高公式）。桥 `POST /share-card`（index/summarize 可选，与服务同源）。验收：harness **1025/0**（+11）；桥探针（真 fixture 页 + 真端点摘要）：标题/域名/PNG 落盘/**sips 像素尺寸 == 回报尺寸 ×2**/摘要非空全过——期间踩到"0.5pt 卡片高让 @2x 位图与回报的 Int 差 1 像素"，卡片高改向上取整修掉；成图目视（标题/首屏/摘要/页脚齐全）。
- **白板模板社区站内化（v0.7.24）**：白板"从模板创建"菜单新增"**从社区获取…**"——应用内拉取 `gallery/index.json`（**新增机读索引**，随站点部署）→ sheet 列表（名称/描述/块数）→ 单板导入走**信任摘要确认**（追加/替换语义与本地 .board 导入同款）。索引来自网络、**当不可信输入**：版本不认识拒绝、file 只认相对路径（禁绝对 URL/协议相对/`..` 跳出/反斜杠），纯逻辑 `BoardGallery` 进 harness（+13：解析/版本/空表/坏 JSON/额外字段忽略/五类 URL 拒绝）。桥 `GET /board/gallery` + `POST /board/gallery/import`（`baseURL` 可指 fixture；`mode` auto/append/replace）。验收：harness **1038/0**；fixture 全链探针全过（列表 5 块/导入块数与块型顺序核对/二次 auto=append 累加/显式 replace/未知 id 与不可达 base 拒绝）。**注意**：默认地址 `https://desire.mankong.icu/gallery/` 需站点部署 `index.json` 后生效（部署是手工步；未部署时面板给出明确的"社区不可达"提示）。
- **DPP 内容管线收尾（v0.7.24）**：三处收口——① **跨源 iframe 逐帧抽取**（0.7 切片二能力回归验证：声明在跨源子框架的 view/action 全进所属框架执行，框架导航离开时明确失败让模型刷新协议）；② **shadow DOM `>>>` 下钻**（L1 扫描进 open shadow root 回归验证）；③ **登录墙指引**（新）：抽取 0 条目且非合法空态时探测登录信号（**可见密码框优先、登录词次之**），把"为什么空"变成一句可行动指引（"先登录再重试、别空转换策略"）——纯逻辑 `LoginWallAdvisory` 进 harness。验收：三 fixture 探针 `tools/dpp-finish-probe.py` **3/3**（双源 8892/8893 fixture：跨源抽到子框架数据、shadow `>>>` 抽到 shadow 内数据、登录墙出指引）；harness **1042/0**。期间修掉一个真 bug：**`callAsyncJavaScript` 不取末尾表达式值**——IIFE 形态返回 null 静默失效（信号探测首版就这么哑掉），已改显式 return 并全仓扫过无同类。

### Fixed

- **navigate 工具竞态修复（v0.7.24）**：完成判定此前只看"`!isLoading` 且旧页面标题非空"——`load()` 后 isLoading 尚未翻转时**第一轮就误判完成、提前返回**（快速连发 navigate → listTabs/readTab 会读到旧页面；真实模型的秒级间隔掩盖了它，2026-10-19 发版套件在假模型下两处翻红才暴露）。现在完成判定要求**"导航确实开始过"**（观察到 isLoading 或 URL 已变化）；15s 内 URL 从未变化且未到目标 → 如实报 "did not commit" 而不是拿旧页面假成功（同 URL 重载无法区分，放行）。
- **WhiteboardComment 显式 nonisolated（v0.7.24）**：Release 构建 main-actor 隔离警告——纯数据类型的 `isOpen`/`ordered` 被 nonisolated 的 `RemoteBoardContent` 引用（预检逮到；此前增量构建把 warning 过滤掉了才漏过）。

## [v0.7.23] - 2026-10-19
### Added

- **iOS 白板可读化（v0.7.23 旗舰）**：手机端从"块类型+200 字符预览"升级为**读得动**——桌面快照的板载荷按类型补只读内容：note 全文（截 1200）、table 解析成行（≤12×8，跳过 `|---|` 分隔行）、image 内联缩略 data URI（**帧内最多 2 张、按真实编码字节数预算 18K 逐块填充**，装不下退回 preview；旧字段 preview/contentLength 原样保留=旧客户端兼容）。构建逻辑抽成 Foundation-only 的 `RemoteBoardContent`（单一真相：快照发送与契约单测同源）；iOS 端 `BoardStripView` 直出 note 文本/迷你表格/内联图（无新字段时退回 preview），点条子开**只读详情页**（逐块完整呈现，flow/mindmap/chart 如实降级为类型+预览，编辑仍在桌面）。验收：单测 +8（表格解析/列行封顶/note 截断/**预算退回**/缩略封顶 2/编解码 round-trip=跨端契约）；定点探针 5/5（清板→长 note+表格+1×1 PNG→载荷三块：全文 1200/两数据行/缩略内联/总字节 ≤18K）；iOS 端编译随 SPM 依赖拉取验证（视图渲染走查由用户过目）。
- **同步冲突明细（v0.7.23）**：设置页 Sync 区块新增「Conflict Details」——本机**LWW 输掉**的条目逐条列（域 + 解密后可读标签 + 相对时间，上限 60 随 UserDefaults 持久化，可一键清空）。实现：push 被服务端判 conflict 时（此前只有计数与短码诊断），把胜者密文用新增的 `SyncCrypto.decryptRaw` 解密、经纯逻辑 `SyncConflictLabel` 提取可读标签（书签 title+host / 设置 KV `key = value` / 记忆 content / 首字符串值兜底，截 60；提取不出退 client_id 短码）——`decrypt` 拆出 raw 层不改变既有解码路径。桥 `GET /sync/conflicts` + `POST /sync/conflicts/clear`。验收：单测 +8（五形态提取/非 JSON/无字符串值/截断）；桥探针（结构/清空）通过；**真实冲突产生的端到端需第二设备**——手法记录在案（dev server + curl 第二客户端 + tools/api-sync-smoke.sh 的冲突步骤叠加），下次 dev-server 会话补断言（不碰用户生产登录态）。
- **设备面板（v0.7.23）**：同步设置页新增「Devices」小节——该账号的全部设备（名称/平台/最近一次拉取距今，「从未拉取」如实写；90 天没拉过的置灰=与 GC 活跃窗口同口径；吊销设备红字标注）+ 刷新按钮。服务端新增只读 `GET /sync/devices`（devices ⟕ sync_pull_cursors 台账聚合，限自己、上限 20）。客户端 `SyncAPIClient.fetchDevices` + `SyncStore.refreshDevices`（不持久化，服务端权威；失败如实记录不清空旧数据）；应用桥 `GET /sync/devices` 同源（未登录时优雅早退空列表）。验收：**本地 dev 全链 3/3**（注册→未拉过 cursor=null（全量提拉不算台账、设计如此）→增量拉一次→cursor/seen 就位且名称平台带出→账号级联清理）；`cargo build` + `cargo fmt` 干净；macOS 构建零警告。**注意**：该端点在**服务端镜像**里——部署三连（migrate 无迁移可跳、api 镜像已随本批重推）后生产手机端设备面板才可用。
- **任务结果未读接力（v0.7.23）**：手机不再错过"你不在时跑出的结果"——桌面在会话列表帧的每行带 `unread`（**手机最后一次"看过"该会话之后新增的助手回合数**，封顶 99）。"看过"的两个真实输入：手机 select 该会话（回执上行，即"打开即清"）与**该会话正被快照推送**（停在对话页 = 浏览中）；首次配对播种已读基线（`remote.seenEpoch`），历史不制造一整屏红点。iOS 侧 `RemoteSessionInfo.unread` + 会话列表红色计数角标。桥 `GET /remote/sessions-frame`（同一构建函数）+ `POST /remote/mark-seen`（select 回执同一路径）。验收（**真端点**）：预热播基线 → 小回合产出 → 帧里该会话 unread≥1 → mark-seen 后再取帧 **unread=0** → 历史会话不被误标，4/4 全过；macOS 与 iOS 双端构建通过。
- **新设备接入引导（v0.7.23）**：设置 → Sync 新增"接入引导"——四步 checklist（账号 → 同步密钥 → 类目 → 首次同步）把散在多页的要检查项收拢，**完成度全部从既有状态派生**（登录态/密钥指纹/启用类目数/最后同步时间，零新增状态）：未完成步给一行指引，首次同步未完成时直接带"立即同步"按钮；密钥步完成时展示指纹供核对。首次进入已登录态自动弹一次（UserDefaults 记账，之后不打扰），日常从 Sync 区"接入引导 → 打开"呼出。验收：桥 `GET /panel/snapshot?name=syncchecklist` 离屏成图（完成/未完成两分支同屏、与 `/sync/status` 逐项一致）+ `SyncOnboardingSteps` 派生逻辑进 harness（978 项全过）。






## [v0.7.22] - 2026-10-18
### Added

- **通用墓碑服务端 GC（v0.7.21 服务端批次，镜像已推）**：`sync_items` 的墓碑不再永久保留——拉取带 `device` 时把该设备复合游标记进新表 `sync_pull_cursors`（迁移 0016）；GC 只回收**所有活跃设备（90 天内有拉取）都已越过 + 超过 30 天宽限**的墓碑，无任何游标时兜底只删超 180 天的；过期设备游标（180 天没拉过）顺带清理——**残留风险写明**：这类设备的"没见过的删除"可能被回收、重连时把本地副本当新写入推上来（复活），与"离线设备重连"同语义。触发：拉取后每用户每小时限量跑 + `POST /sync/gc`（可 dry-run）+ `desire-admin sync gc [--dry-run]`；客户端 `device` 上报随 app 0.7.20+ 已随包发出。验收：本地 E2E 冒烟 `tools/api-sync-gc-smoke.py` **20/20**（游标记账/判定支回收与保留/dry-run 不删/兜底支两态/过期游标清理/账号级联清理）；**生产部署 = 部署机跑 build-migrate→migrate→build-api→run.sh 三连（镜像已推注册表）**。
- **从会话提炼技能（v0.7.22 旗舰）**：把刚跑通的一段工作流**一键存成技能**——Agent 面板标题菜单新增「从本对话提炼技能…」：一次旁路模型调用（`MemoryExtractor` 同管道，当前档案口径）读会话的**运行记录**（`SkillDistill.transcript`：跳过 system、工具调用带名与参数、结果截断、超长保尾部），按约定回 JSON 草稿（容错解析：剥围栏/杂谈、名称截 60、描述压单行截 160、正文自带 frontmatter 剥一层、必填缺失整份拒收）→ **预填进既有技能编辑器**，用户剪裁后保存才落盘（草稿不自动写库——不静默存烂技能）。桥 `POST /skills/distill`（`save=true` 时落 `<name>.md` 并 reload）为同源等价。验收：单测 +11（解析六档拒收/描述压行/名称截断/嵌套 frontmatter/运行记录三条）；定点探针 8/8（草稿三字段/默认不落盘/落盘可见于 /skills/删除还原/档案端点模型还原核对）；E2E 新增 MUSCLE28。
- **记忆冲突复核向导（v0.7.22）**：新增记忆与既有事实**可能相关**时不再静默并存——口径先说清（**近似判定**：类别或作用域同桶 + 显著词 containment 重叠 ≥0.34；近似重复 ≥0.8 单列一类。没有端到端语义理解，文案照"可能相关/建议复核"写）。两个入口：**手动添加**即时弹向导（无相关内容直接入库，不打扰）；**自动抽取**不打断回合、相关候选进**复核队列**（UserDefaults 持久化），记忆面板横幅"N 条新学记忆待复核"逐条向导。四种决议：保留新的（删相关旧条）/保留旧的/两条都保留/**合并成一条**（预填兜底拼接「；」衔接、可手编；合并前先删两边再写入，避免去重守卫误伤）。桥 `GET /memory/conflicts` + `POST /memory/conflicts/resolve`（factID=复核态 / newText=手动态）为同源等价。顺带加固：桥的 `relatedIDs` 逐元素容错解析（`as? [String]` 遇数组内 null 会整组退化静默吞参——探针照出并修复）。验收：单测 +6（候选桶规则/近似重复分类/异桶不打扰/合并拼接去重）；定点探针 8/8（四决议语义 + 队列查询 + 清理零残留）；E2E 新增 MUSCLE29；面板交互留用户走查。
- **轨迹复盘卡 → 输出规则（v0.7.22）**：轨迹页每个回合卡片底部新增「把失败模式写进输出规则…」——从该回合的步骤里**模板化派生**规则草稿（不经模型、可解释）：被用户拒绝过的工具（"先征求确认"）/返回过错误的工具（"先校验 Error: 前缀、失败换方案"）/平均耗时超 8s 的慢工具（"先告知预期耗时"），按 工具×种类 去重、封顶 3 条；点开 sheet 可编辑/删行，「Add to Output Rules」逐行追加进设置里的输出规则（`<output_rules>` 层，去重），之后每一轮都带上。纯逻辑 `TurnReview` 进 harness；桥 `GET /agent/rule-draft` + `/ai/output-rules`（get/add/remove）同源开放。验收：单测 +9（步事实抽取/顺序与去重/均值聚合/干净回合不硬凑/封顶/模板渲染）；定点探针（草稿命中 errored·readFile + 规则增删去重，按轮包转的假端点）；E2E 新增 MUSCLE30（注意 `MUSCLE30` 含 `MUSCLE3` 子串——假端点分支必须排在 MUSCLE3 之前）。
- **周报（v0.7.22）**：每周固定时间（默认周一 09:00，可改星期与时间）把"近 7 天"的**确定性回顾**落进会话备注 + routine 档系统通知——**纯模板、零模型调用**（同心跳互补：那是模型自决"要不要打扰"，这是定期给个交代）。内容：活跃会话数与消息数、窗口 token 与轮数（逐日桶求和，窗口精确）、新记忆条数与样例、收件箱待办分类计数（复用 `AgentInbox.build` 全量现状）、新技能名；**金额刻意不进周报**——逐日桶只有 token，塞一个全时段金额会撒谎（费用看使用统计页）。调度用自持 60s tick（同心跳模式）：到点且本周未投递过才跑、回合进行中推迟；上次投递时间与文本持久化。设置页（Agent ▸ 周报）：开关 / 星期 / 时间 / 「立即生成」。桥 `GET|POST /agent/weekly-digest`（状态 / run-now·enable·disable）同源。验收：单测 +7（compose 各段/空窗省略/不含 $/紧凑 token）；定点探针 9/9（初始态/enable/生成文本/备注落会话/幂等 due/lastDelivered/收尾）；E2E 新增 MUSCLE31。
- **收件箱批处理（v0.7.22）**：收件箱页进入「选择」模式后多选条目，底部批量条——**稍后 1 小时 / 明天 9 点 / 忽略**；头部出现「已隐藏 N · 恢复」chip 一键全部恢复。实现关键：条目是每次从各 store **实时派生**的（`AgentInbox.build` 纯函数），所以隐藏记在**稳定条目 id** 上的持久台账（`AgentInboxDismissalStore`：忽略=永久隐藏、稍后=到期自动回列表），构建后过滤；周报的"待办计数"复用同一过滤（隐藏的不在回顾里复活）。桥 `POST /inbox/dismiss`（ignore|snooze，hours 或 until epoch）+ `POST /inbox/restore`（缺省=全部）+ `/inbox` 行带 `id`/`hiddenCount`。验收：定点探针 11/11（入箱带 id/忽略隐藏与回执/恢复重列/稍后未来隐藏/改过去即回/清理零残留）；E2E 新增 MUSCLE32。
- **Crew 运行观察面（v0.7.22）**：Tab Crew 条子从"一排状态点"升级为**实时观景台**——运行中逐 worker 展开详情行：当前步骤（"思考中（第 N 轮）"/"调用 X"/"撰写报告"）、工具调用计数、**自走的已用时**（TimelineView，不依赖发布）；概要行保留状态点、目标与「Cancel」；全部落定后新增 **✕ 一键收起**（原 v1 只有文案说"可关闭"、实现缺失，本次补齐 `AgentCrewStore.clear()`）。实现要点：`WorkerTask` 是引用类型、字段变更不触发 `ObservableObject`——store 侧加 `noteProgress` **节流发布（≥1s）** 防每 token 重绘；顺手清掉条子里一处 `Color.accentColor`（违反强调色规范的历史遗留）。桥 `GET /crew`（逐 worker 的 state/currentStep/elapsedSec/toolCalls/result 前缀 + tokens + settled）+ `POST /crew {clear|cancel}`。验收（**真端点**）：worker 实时步骤与工具计数在场（假端点首轮）→ 真端点双 worker 全落定、真实答案回执、clear 生效；token 计数的既定语义重申：网关不在流里上报 usage 就是 0（没上报不计入，不猜）。
- **评估集管理（v0.7.22 收官）**：轨迹页头部新增「评估集」菜单——**一键把 👍 过的回合导出为 JSONL**（一行一回合：conversation/title/goal/answer/steps/startedAt；派生**复用 AgentTrace**，与轨迹页/评估同源不另养定义），默认落 `~/Documents/DesireAgent/eval-thumbsup-<时间戳>.jsonl`；菜单内直接列出最近 5 份导出（点击在访达显示），回执在页头如实显示导出回合数（0 回合也写空文件、不谎报）。桥 `POST /agent/eval-export` / `GET /agent/eval-exports` / `POST /agent/eval-export/delete`（**只许删 `eval-thumbsup-*.jsonl`**，防误删用户文件）。验收（**真端点**小回合）：反馈 up→导出回执 turns≥1→文件存在且首行含 goal/answer→列表在列→删除生效且文件消失→测试会话与反馈收尾清理，7/7 全过；E2E 新增 MUSCLE33。









## [v0.7.21] - 2026-10-18
### Fixed

- **回合末 usage 偶发少记一轮（预算/成本读数漂移，v0.7.21 修复）**：预算 E2E 在 "920/500" 断言处 8 连绿后偶发一红照出的真竞态——流式处理的 `assistantMsg` 是 `messages` 里的**值拷贝**，而 usage 常作为该轮**最后一个事件**到达：没有后续 text/toolCall 事件触发 write-back 时，token 只留在本地副本里；`conversationUsage` 从 messages 派生，于是预算停机提示与成本统计偶发**少记最后一轮**（读数停在 460 而断言要 920）。修复：流结束后在工具执行/下一轮之前**无条件把副本写回 messages**（差异才写，id 找回防错位）。复测：修复作用于下一轮套件验证；缺陷行为在 8 次全量中有 1 次可观察。

### Added

- **命令面板升级为全局混合检索（v0.7.21 旗舰）**：⌘K 从"命令清单"升级成五源聚合入口——命令 / 打开中的标签 / 书签（叶子）/ 历史（最近 300）/ Agent 会话（最近 120，副标题=首条消息摘要）。分组展示带**每源命中数徽标**（显示 8 / 共 23）；↑/↓ 只踩行不踩组头、回车执行、**⌘回车对可打开的行（标签/书签/历史）走新标签**、esc 关闭；空查询 = 初始态（命令按**最近使用**序——持久化在 `commandPalette.recentCommandIDs`，其后目录序；标签按窗口顺序）。检索与分组收口在新纯逻辑 `PaletteSearch`（评分六档：标题前缀 100 > 标题词首 80 > 标题子串 60 > URL 子串 50 > 副标题 40 > 模糊子序列 20，同分保持输入序、每源截断 8 条）；四源行构造收口 `PaletteSnapshot`（UI 首开快照与桥 `/palette` **同一处构建**，两个入口的结果不会漂移）。验收：单测 +17（评分档位/分组截断与 total/同分稳定/初始态/显示序列头行交替）；定点探针 10/10（书签前缀命中与 ⌘Enter 资格、标签+历史 URL 命中、命令前缀优先、空查询初始态、清理零残留）；E2E 新增 MUSCLE24（五源 + 初始态 + 截断进套件）。UI 键盘走查（↑↓/回车/⌘回车）留用户过目。
- **站内查找升级（v0.7.21）**：查找栏新增**大小写敏感开关**（"Aa"，开时强调色高亮；粘性偏好存 `findCaseSensitive`）与**命中片段预览行**（首个命中 ±40 字符、两端截断带省略号，显示在查找框下方——纯读操作、无高亮副作用）。计数与片段共用同一套匹配语义（`findCountJS`/`findSnippetJS` 携带同一 caseSensitive 标志；原生 `WKFindConfiguration.caseSensitive` 同步设置，高亮/跳转行为与计数口径一致）；跨标签命中列表（0.7.14）原样保留。**多词 AND 明确不做进本期**：那需要 JS 全量接管高亮与导航，否则会出现"计数按 AND、回车跳转按字面量"的双口径——留后续专项。验收：定点探针 6/6（不敏感命中 3 / 敏感三态各 1 / 无命中时片段为空）；E2E MUSCLE24 增补同组断言（fixture 大小写三态页）。
- **站点控制中心（v0.7.21）**：点地址栏锁图标弹出的一站式"本站设置"——缩放（−/100%/＋，点百分比即重置）、暗色、自动播放、页面字体（摘要行 → 打开既有站点字体弹层）、已拦截元素计数（→拦截面板），底部「清除本站覆盖」把缩放/暗色/自动播放/字体一次还原（**拦截规则不动**——内容级决定走拦截面板单独管）。实现两处收口：`SiteSettingsStore.clearOverrides`（store 级清除，UI 与桥共用）+ `BrowsingActions.clearSiteControls`（页面就地还原：暗色样式撤除、缩放复位、字体注入重施），桥 `POST /site-settings/clear` 同序等价。验收：定点探针 6/6（四项覆盖就位 → 页面侧 16px+样式标签生效 → 清除 → 四项回默认且页面 10px/样式与暗色标签齐撤）；弹层视觉与交互走查留用户过目。
- **下载面板拖拽与快捷操作（v0.7.21）**：完成行可**直接拖到 Finder/邮件/任意 App**（`NSItemProvider(contentsOf:)` 携带真实文件 URL；仅"已完成且文件存在"的行挂拖拽——进行中/失败行没有可交付实体，不挂假手柄）；**双击完成行 = 打开文件**（与右键「Open」同路径）；右键菜单补 **Copy Path**（复制本地路径，与既有 Copy Link 并存）。现状核实说明：右键的 Open / Show in Finder / Preview 0.7.19 起已在（原计划里的"补打开"无实际缺口，不做）；"批量面板条目跳单条面板"经核实无真实落点——批量引擎的条目不在 DownloadStore 单条面板里，跨面板跳转没有目标可去，同样不做（不做清单会写进 ROADMAP）。验收：构建零警告 + 手势/拖拽交互留用户走查（拖拽属于无法用桥断言的系统交互——AX 也够不到拖拽会话）。
- **阅读进度记忆（v0.7.21）**：阅读列表里的页面自动记滚动位置，重开回到读到的地方——条目新增 `progress`/`progressAt` 可选字段（旧文件零迁移、随云同步走且**盖 LWW 戳**，否则 FlatSyncMerge 会当旧值拒收）。采集用**零常驻注入**的取舍：每 15 秒对"当前标签恰在阅读列表里"的页面做一次纯读（`WebView.scrollProgressJS`，不可滚短页返回 0），切标签前先补采一次再换跟踪对象；恢复走既有 didFinish 钩子模式（`ReadingProgressTracker.restoreIfNeeded`，每条 URL 一次、比例 <2% 不恢复）。列表面板行显示进度戳（已记录且未读完时；悬停提示 Resume reading）；桥 `/reading-list` 行带 `progress` + `POST /reading-list/progress` 可直接写。验收：定点探针 6/6（写入回执/行字段/页内读取口径 ≈0.62/**关标签重开自动滚回 ≈50%**/清理零残留）。
- **会话内查找（v0.7.21）**：Agent 面板 ⌘F 弹出查找条——跨消息子串查找（大小写不敏感，**只扫正文 content**：纯工具调用消息与折叠推理不参与，避免命中噪音），命中消息**强调色描边**、自动滚动定位（复用既有 ScrollViewReader 的 `.id(msg.id)`，proxy 由底部锚点捕获）；Enter/↓ 下一个、↑ 上一个、计数 "n / m" / "No matches"、Esc 关闭。面板级 Esc 的处理顺序为**查找条优先**（开着先关它，不影响"取消回合"语义）。纯逻辑 `AgentMessageSearch` 进 harness（Foundation-only，+5 项），桥 `GET /agent/find?q=` 同源开放（E2E MUSCLE26）。
- **历史站点分组收口（v0.7.21）**：核实后按"只做真缺口"落地——date/site 双模式分组与按站点删除 0.6.x 起已在，本次补三件：① **站点组可折叠**（组头 chevron 点击折叠/展开，折叠态保留组名与计数）；② **站内相对时间**（站点模式下每行行尾显示"2 小时前"这类相对时间，核扫描"这站最近看了啥"）；③ **聚合口径抽纯**（`HistoryGrouping`，Foundation-only 进 harness +6）——面板与桥 `GET /history?grouped=1` 同源（分组按"组内最新访问降序"，常用站浮前；桥返回 groups/total/groupedTotal 供守恒断言）。验收：定点探针 4/4（结构/计数守恒/本域在组/降序）；面板折叠交互留用户走查。
- **书签死链清理向导（v0.7.21）**：把 0.7.20 的巡检报告变成**可勾选、可批量清理**的界面——书签面板头部新增听诊器按钮打开「书签健康」：空闲态选限量（50/100/200）点开始；运行态进度条；完成后**死链默认全选**（可逐条取消，取消过的不再被重算勾回）、每条带原因徽标与「打开」试看，跨站重定向只列信息（手动更新，这里不改动）；「删除所选」走既有 `store.remove` 路径（墓碑 + 落盘 + 同步），**唯一清理出口、绝不自动删**。桥 `POST /bookmarks/health/cleanup {urls}` 是同序等价（返回 removed/missing）。验收：定点探针 6/6（入队/真 404 命中/好链零误伤/removed 与重复 missing 路径/死链删好链留/清理零残留）；E2E 新增 MUSCLE27（fixture 恒 404 靶页）。









## [v0.7.20] - 2026-10-18
### Fixed

- **书签 HTML 导入对带文件夹的导出文件整份解析为空（v0.7.20，去重探针挖出）**：解析器只在"紧跟 `<DT>` 之后"才检查 `</DL>`，而真实导出（Safari/Chrome/Firefox）里 `</DL>` 出现在**两个 `<DT>` 之间**——文件夹永远不回弹、子项被无限嵌套进栈，`root` 最终为空：手选任何真实导出文件都会得到"没找到书签"。修复：`<DT>` 与 `</DL>` 按出现顺序取最近者统一处理，收尾 flush 改为先 pop 再挂（原版会把未闭合文件夹挂进它自己）。解析实现拆到 Foundation-only 的 `BookmarkHTMLParser` 并进单测（嵌套/兄弟文件夹/平铺/未闭合四类用例，harness +7）。

### Added

- **标签页自动分组（v0.7.20 融合旗舰）**：一句话把满屏标签按主题理好——新工具 `autoGroupTabs {dryRun?}` 取全部标签的标题/站点做**一次旁路模型聚类**，复用 `TabGroupStore` 建组归位（配色顺延、同名组沿用不重开）。**dryRun 先看方案**（"先看看怎么分"→只回分组提议、什么都不动）、应用后再用；模型输出不可信一律擦干净：剥代码围栏/前后杂谈、越界与重复下标剔除（每个下标只归一组、先到先得）、单标签组丢弃、重名组加序号、组名截断——纯逻辑进 `TabGroupCluster`（tests/run.sh +9 项）。验收（真机探针）：dryRun 零改动 ✓、应用后精确建出两组各 2 条并与既有组互不影响 ✓（探针只对自己的 fixture 标签分组，正在使用的标签决不碰）。
- **日历与提醒双向（v0.7.20）**：OS 协作从"能记能读"补齐到**能改能删**——三件新工具：`updateCalendarEvent`（改名/改时/改时长/地点/备注/换日历）、`deleteCalendarEvent`（**risk=dangerous**：不可逆操作每次显式确认，没有 Always-Allow 可偷渡）、`updateReminder`（改名/改期/备注/换列表）。三件共用同一条匹配纪律：按标题子串 + 可选日期窗口定位，**命中唯一才动手，多命中一律拒绝并列出候选**（"删错比删不掉更糟"）；改动的每一项都以"旧值 → 新值"如实回述。工具定义/能力页（OS 协作簇归入「系统与技能」）同步。真机验收 8/8 ALL PASS：提醒 建→改→列表读回新名新期→完成清理 ✓、多命中拒改列候选 ✓、日程 建→改（改名+改时，列表核回）→**删（走审批放行）**→复读已消失 ✓——探针对象全清、你的日历与提醒未被误动。
- **书签死链校验（v0.7.20 替人干活）**：新工具 `checkBookmarkLinks {urls?, limit?}`（桥 `GET /bookmarks/health` + `POST /bookmarks/health/check` 同源）——**长任务模式**：立刻返回"已开跑 N 条"，后台 4 并发探测（**HEAD 优先、Range GET 复测**——不抓正文，8s 超时），完成后把**死链 + 跨站重定向**清单落成会话备注 + 系统通知；**绝不自动删任何书签**，报告交给用户点头后再清（清理走既有 removeBookmark）。判定口径写死并注释：2xx/3xx 可达；**401/403 不算死链**（存在但需权限/被反爬拦——误伤比漏报更扰人）；终态 origin 与原始不同才算跨站重定向（同站跳转/补斜杠不报）；`urls` 过滤保证按批触发不误碰列表其它书签。真机验收 5/5 ALL PASS：入队 4 条 ✓、死链仅命中真 404 ✓、好链零误伤 ✓、同站 302 零误报 ✓、进度与时间戳就位 ✓（fixture 书签全清）。
- **鼠标手势与超级拖拽补上设置入口（v0.7.20）**：两项功能本体 0.7.13 就已发货（右键拖动 ← 后退、→ 前进、←→ 刷新、↓ 新标签、↑ 关标签；拖链接到页面空白 = 后台标签打开），但**默认关且设置页没有开关——等于用户开不到**。现在「通用 › 手势」段补上两项开关（带操作说明副标题），拨动即生效（监视器随开关即时重建，无需重启）。轨迹→动作映射抽成 `MouseGestureTrail` 纯逻辑（Foundation-only 进单测 +8 项）。另经查实：「全部标签页查找」（FindBar 跨标签命中列表 + 点跳）0.7.14 已交付，本项无需再动。真机 AX 验证 4/4：设置页开关就位、按动后 `mouseGesture.enabled` / `superDrag.enabled` 正确落盘并可往返复原（收尾已复位为默关）。
- **站点级字体（最小字号 + 字体族，v0.7.20）**：任意站点可把过小的正文文字抬到设定的下限，并指定一个默认字体族——工具栏「⋯」菜单新增「Page Font」（站点弹层：跟随默认 / 关闭 / 12–18px；字体族附带 PingFang/宋体/楷体/Georgia 等档位），设置页「外观」新增两个**全局默认**（未覆盖的站点都跟随），Agent 侧新增 `setSiteFont` 工具（同一套三态语义：不给 = 不动、0/空串 = 本站关闭、followDefaults = 清除覆盖），桥 `/site-settings/font` 同步开放（改完对活动标签立即重注入，不用刷新）。三条实测收敛的语义：① **最小字号是逐元素抬升**（CSS 没有 min-font-size）——覆盖前先把元素**原内联值存进 data 属性**、还原时原样写回；最早一版直接 removeProperty，网页自己的 10px 内联字号被抬升后再还原会掉到默认 16px（原值销毁），复扫时还会把自己设的 !important 读成"已经够大"而自毁，重写为"按保存原值判断去留"后探针 22/22 全绿；② **字体族不加 !important**、只作 html/body 的默认族——网页自身指定的字体照样赢（浏览器"标准字体"同语义，也不破坏图标字体）；③ 全局默认与站点覆盖**三态分离**（站点"显式关闭"能挡住全局默认）。MutationObserver 去抖复扫覆盖懒加载/SPA 重渲染。验收：定点探针 22/22（抬升/作者优先/三态/还原/全局联动）；E2E 新增 MUSCLE21（同一链路进套件）；单测 +12（夹取/清洗/解析，harness 856 项全过）。
- **书签导入去重向导（v0.7.20）**：导入前把解析结果与现有书签库对照，**先给用户看再落库**——重复分为"已在库中"（含尾斜杠/大小写/默认端口/fragment 差异的结构等价归一）与"文件内重复"（同文件里更早出现过），向导列出重复清单与三条统计（文件总数/全新/两类重复），两个出口：「仅导入全新」（默认，簇中保留首现）与「全部导入」（连重复一起保留，保留两份）。全新文件导入维持"直接进库"的原有体验（有重复才弹窗）。同一套 `BookmarkImportDedupe` 逻辑开放为桥 `POST /bookmarks/import`（`html` 或 `path` 二选一；`dryRun` 只回计划 + 重复样例；`strategy=skipDuplicates|keepAll` 落库）——面板向导与自动化共用一条链路。归一化刻意保守：不同路径/查询一律算不同书签，http≠https（宁可少报重复，不误合并收藏）。定点探针 19/19（dryRun 统计/样例、skip 落 3、keepAll 落 5 且重复并存、缺来源与空文件走 error 约定、清理零残留）；单测 +12（归一化折叠/划分/空壳文件夹剔除/空文件夹保留）；E2E 新增 MUSCLE22。
- **AI 双语对照（v0.7.20）**：工具栏「⋯」菜单新增「双语对照」（`bilingualTranslate` 工具 / 桥 `POST|GET /bilingual` 同权）——页面块级文本（p/li/标题/引用/表格单元格等）按 8 块一批交给**当前档案的模型**互译，译文逐条插到对应块之后（原/译对照阅读；列表与表格内嵌到项内、其余挂在块后），流式落页、边翻边读。三条语义：① 目标语言 = 系统首选语言（中文系统 → 简体中文）；② 只翻**正文块**（≥12 字符、可见、上限 60 块/1.5 万字，标题也算一块），译文条数与原批不符**整批丢弃**（对齐错误比没翻译更伤）；③ 状态按**标签**记且**不持久化**——导航后仍开着的标签自动重施，关掉即clear（译文节点与块标记一并清）。过程中修一处编译期问题（`callAsyncJavaScript` 尾随闭包与 async 重载歧义）。验收：定点探针 14/14（改档案指向假端点→开启→收尾→DOM 计数/序号对齐/编号行落假端点日志→关闭清零→**档案端点/模型还原并核对**）；单测 +8（`BilingualParsing`：JSON/围栏/杂散文字/条数不符/行回退）；E2E 新增 MUSCLE23（套件假端点按标记回译文）。








## [v0.7.19] - 2026-10-17
### Added

- **阅读列表批量摘要（v0.7.19 旗舰）**：「读完这 N 篇给我一份汇总」变成一条后台流水线——新工具 `summarizeReadingList {limit?, force?, urls?}`（桥 `POST /reading-list/summarize` 同源）：对未摘要条目**逐篇 readURL 取正文**（已开标签复用含登录态；否则离屏加载）→ **一次旁路模型摘要**（`MemoryExtractor.collectText` 同管道，当前档案口径）→ 写回条目 `ReadingListItem.summary`（可选字段、旧文件零迁移；**盖 LWW 戳随云同步**）。长任务模式（同媒体导出）：工具/桥**立刻返回**"已入队 N 条"，逐条写完即存（**阅读列表面板行内实时出现**），收尾发系统通知 + 会话备注；面板加「全部摘要」一键入口（带 x/y 进度）与逐条右键「摘要 / 重新摘要」；`listReadingList` 带 [summary] 提示让模型知道哪篇摘过。稳健性：单篇失败（离线/超时/空稿）**不写任何标记**、下轮自然重试；`urls` 过滤保证按条触发**绝不误动**列表里其它条目（E2E 有专项断言）。定点探针 4/4 ALL PASS（入队/落回/实读回显/只动指定条目）；E2E MUSCLE19 已进套件。
- **备忘录工具（v0.7.19）**：系统级协作第三件——`addNote` / `listNotes` / `searchNotes` 驱动 Notes.app（缺省落「Desire」文件夹、首次自动创建；搜索扫最近修改至多 120 条、标题+正文客户端过滤——Notes 没有服务端全文检索 API，这点已如实写进工具描述）。权限两条都按纪律落位：Hardened Runtime 下发 Apple Events 需要 `com.apple.security.automation.apple-events` entitlement（已加，AMFI 实测放行）+ `NSAppleEventsUsageDescription` 说明；TCC「自动化」授权**懒请求**——首次真调用才弹「Desire 想控制备忘录」，osascript 调用带 30 秒超时、超时如实回报"点了允许再试"（与提醒事项"弹窗可能永不渲染"预案同款）。三段 AppleScript（建笔记/清单/搜索）经 `osacompile` **编译期校验**（含 Notes 词典解析、换行与特殊字符转义；编译不发送事件、不触发 TCC）。E2E MUSCLE20 走"参数校验先于授权"路径（缺标题 / 搜索词太短 → `Error:` 约定，绝不发起 AppleEvent）；定点探针 3/3 ALL PASS。
- **DPP 检查器试跑（v0.7.19）**：DevTools「DPP」页签每个声明动作的行尾新增**「运行」**——走**与回合内完全相同**的审批闸门执行单个动作（`runInspectorToolCall` 直通同一 gate：risk 分级/审批卡/白名单/DPP 站点放行全部照常，内部动作直跑、persist/outbound/danger 会弹卡，**不是绕过审批的侧门**）；试跑前把**本窗口**的 Agent 面板亮出来（审批卡有处可落；显式点名会话，多窗口不串），结果行只显示在检查器里、不进对话。验收（真机 AX 驱动）：fixture 声明 → 瓢虫开面板 → 切 DPP 页签 → 断言动作行在列 → 按「运行」→ 页面副作用落地（`window.__refreshed`）→ `completed` 回执落进检查器；桥路径（`/page/dpp-action`）双跑对照亦过。排障沉淀：**fixture 的 `body.innerText += …` 是破坏性赋值**（会把按钮换成文本节点，第二次点击必炸——gate_e2e 同款写法靠每轮重导航掩盖了它）；**AX 盲按切换钮会把开着的面板关掉**——新增 `tools/axexists.swift`（幂等存在性判断）与 `tools/axpress-near.swift`（同为「DPP」时按锚点同行取近），二者已随库。
- **启动行为扩展与崩溃恢复提示（v0.7.19）**：「启动时」从两档扩到四档——继续上次会话（默认）/ 新标签页 / **打开主页** / **打开指定页集**（新设置行：多个 URL 以空格或换行分隔、封顶 10 个，解析是 Foundation-only 的 `StartupPageSet`，非 http(s)/非法/重复自动滤除并进单测）；设置改动**桥可即改即生效**（`POST /sync/setting`，重启类断言直接读 `/state.startupBehavior`）。崩溃恢复把原先的静默采纳**说清楚**：异常退出后按情况给一条带细节的提示——"上次异常退出——已恢复 N 个标签"（采纳路径，带上标签数）/ "已按启动设置打开主页/指定页集/新标签页"（非采纳路径），全部走既有 toast 通道。`/state` 新增 `startupBehavior` 与 `launchedAfterCrash` 字段。验收（真机探针，含整套备份/复原）：桥改 → 重启断言主页档 ✓、页集档（两条 URL 都在）✓、恢复会话档（采纳最近会话）✓、崩溃标志（模拟异常退出 true → 干净退出归零）✓——全程用户的会话文件/索引/归档先备份后复原、零残留。
- **下载体验补件（v0.7.19 收官）：并发上限真实可控 + 行内预览**。「下载」设置新增**同时下载数**（不限/1/2/3/4/6，按窗口计）：超限的下载**借既有暂停机制停成 resumeData 排队**（列表行显示"等待下载空位…"），名额空出时经 `.downloadSlotFreed` 通知自动放行、走同一条 checkpoint 竞态安全路径。设计上踩过并弃用了一版"挂住 decideDestination"的实现——那条路赌 WebKit 的等待窗口，实测会把 parked 下载判失败；也修了"新下载把自己算进进行中计数"导致上限=1 时首条自锁的缺陷（`beginTransferIfAllowed(excluding:)`）。**限速**如实说明：WebKit 的 WKDownload 没有节流 API，设置项副标题里写明"这是能做到的真控制"，不做假 UI。**行内预览**：完成的行右键「预览」→ QuickLook 内嵌 sheet（图片/视频/音频/PDF/文本统一渲染，系统 QLPreviewView 零自研），带"在访达中显示"。真机验证：双下载串行（queued 出现 → 两条都 completed）✓；预览为代码审查+构建收口（popover 面板行的 AX 点击链受 popover 树外露所限，未做 AX 断言——点一次即可目视）。






## [v0.7.18] - 2026-10-17
### Fixed

- **固定标签的第一个胶囊被红绿灯遮住（用户实拍报告，v0.7.18）**：真根因是**宽度硬钳**——固定标签的胶囊被 `.frame(width: 50)` 钉死，而胶囊内容会随元素变宽（分组色条/容器点/音频钮/图钉都会加），超宽内容被 SwiftUI 在 50pt 槽位里**居中**→胶囊背景往左溢出 7~15pt，正好钻到红绿灯底下（"不 Pin 正常、一 Pin 第一个胶囊就被遮住"）；改成 `.frame(minWidth: 50)`（下限保等宽观感、内容多则自然变宽）。顺带把固定标签的图钉从"6pt 角标叠在图标右下角（半截越出）"改为**并排画在图标左侧**（9pt，完整在胶囊内）。
- **缩放记忆三路收口（v0.7.18）**：菜单 ⌘+/⌘−/⌘0 与智能体工具（zoomIn/zoomOut/resetZoom/setZoom）此前直接改 webview 缩放、**不记站点**——下次同站导航 didCommit 按已存值应用，用户看到的就是"刚调好的缩放自己弹回去"（工具栏是唯一会记的入口）。现在四个入口统一走 `Tab.applyPageZoom`（双写 + 记站点；重置即清除该站记录）。E2E 新增 MUSCLE15（setZoom 150% → 同站导航 → listTabs 复核 150% 仍在 → resetZoom → 再导航无缩放标记）。
- **关窗即归档（v0.7.18）**：窗口关闭**那一刻**就把它会话文件移进「已归档会话」（仍可从面板/工具找回）——此前要等下次退出时统一清理，实跑一天攒了 23 个已关窗口的会话文件，成为下次启动"最近会话"采纳的诱饵（幽灵窗口复活/投递目标指向已关窗口一串问题的土壤）。三条边界都有实测依据：① **还有别的活窗口才归档**——判据看"别的 manager 里有标签的 webview 挂在活窗口上"（SwiftUI 关窗后实例滞留 + 离屏快照等游离 manager 的实测坑：按存活数判断会把关最后一扇窗误判成还有窗口，把用户会话归档掉、下次启动恢复落空）；② **退出流程中不归档**——AppKit 在终止时会给窗口补发 willClose，此刻索引已写好，再归档就把索引里全部活动窗口的会话变成采纳不到的死键（实测复现并修复）；③ **关最后一扇窗再退出**仍按"继续上次会话"语义留给下次启动。另补一条窗口关闭的诊断日志（其它窗口/终止中/是否归档）。
- **DPP 逐动作审批补上验收轮 + 一处静默退化修复（v0.7.18 收口）**：`gate_e2e.py` 新增 **D 轮**——danger 动作 → 授权卡上「本站始终允许」（`alwaysAllow` + siteGrant）→ 断言授权**持久化为「站点 × 动作」规则**、**二次执行全程不再弹审批卡**且照常执行（27 项全过）。补测照出一处真 bug：桥 `POST /approvals/resolve` 收下了 `siteGrant` 参数却**没有往 store 转发**——经桥做「本站始终允许」会静默退化成普通放行（规则不落库、下次照样弹卡）；已修（`resolveApproval(outcome, siteGrant:)` 直通，D 轮走的正是审批卡同名代码路径）。
- **标签组 UI 收口（v0.7.18）**：右键菜单补齐**重命名**入口——顶部标签栏的胶囊（含折叠组胶囊）与侧栏行都新增「重命名分组…」，走与「新建组」同款的输入 sheet（`TabGroupPrompts` 统一收名）；侧栏同步补齐整组操作（折叠/展开、删组、移出组、加入组）与**折叠组行**（组名 + 数量、点开即展开），与顶部栏语义一致。顺带修掉三处 AX 实测照出的缺陷：① **折叠一个组、胶囊不出现**——TabBar 收 `tabGroups` 值参数、数据又经计算属性取 store，store 变化不触发重绘（"隔着另一个 store 读嵌套 ObservableObject 不重绘"的老坑；改为 `@ObservedObject groupStore` 直读）；② **后台运行时新建/重命名提示静默不出现**——`NSApp.keyWindow`/`mainWindow` 在后台都是 nil，alert sheet 直接 return（改为退到任一可见常规窗口）；③ **侧栏模式下完全无法建组**——顶栏在侧栏模式是隐藏的，而侧栏未入组菜单的 `!tabGroups.isEmpty` 门把无组场景的入口整个吞掉（菜单常驻 + 抽出 `createGroupFromTab` 顶栏/侧栏共用）。另补 `Copy Performance Snapshot` 的中文。验收（**AX 驱动真机**）：建组→折叠→重命名（断言 `/tab-groups` 变化）→删组全链路通过，顶栏与侧栏两条路径都验；新增 `tools/axmenu.swift`（AXShowMenu 开右键菜单→按条目 press→给 alert sheet 填值，补 axpress 够不着的菜单/表单场景）。





### Added

- **`readURL`：离屏取正文（v0.7.18 首批）**——不开标签读任意链接："读一下这篇给我要点"、"把这几个链接都看看"、扫一个页面找入口，以及热点选题/批量阅读的地基。页面**已经打开**就借它的 webview 直读（零等待、含登录态、不打扰页面）；没打开才离屏加载（一次性 webview + **当前档案的 data store** + 与主浏览一致的桌面 Safari UA，20s 超时退场）。返回标题 + 正文（innerText，尊重 CSS 可见性，压缩空行、封顶截断）+ 链接清单（可关）。口径如实标注：shadow DOM/跨源 iframe 正文不在内；与 httpRequest 同族过审批，不进只读自动放行。E2E MUSCLE13（已开标签路径 / 离屏路径 / 坏 URL 错误口径 / **不开新标签**）。
- **网页数值盯梢（页面监视 v2，替人干活·电商/运营三用）**：监视条目可标注**数值字段**（`numericSelector`）——每次检查把命中的**第一个数字**记进历史（封顶 60 点，千分位/货币符号自动处理），配 `alertAbove`/`alertBelow` 阈值后**只在跨线那一刻**告警一次（不重复刷；通知走既有分级管线，免打扰/预算照管）。页面监视首次进工具面：`listPageWatches` / `addPageWatch`（含数值与阈值参数）/ `removePageWatch` / `checkPageWatch`——"帮我盯着这个价格，低于 1200 告诉我"现在一句话搞定；桥 `/watches*` 同步补数值面与告警字段；设置页监视区块新增「数值盯梢」行（最新值/读数笔数/阈值 + **迷你走势**）。纯逻辑（取数/跨线判定/历史封顶/旧存档回兼容）进 tests/run.sh；E2E MUSCLE14（建监视→基线 1,299→fixture 改价→跨线告警"低于 1200"→列表→删除，桥面复核清干净）。
- **朗读工具 `readAloud` / `stopSpeaking`（v0.7.18）**：智能体现在能把页面念给人听——"把这篇念给我听"一句话搞定，走**端上 TTS**（AVSpeechSynthesizer，零费用、数据不出机）：`readAloud` 给了 `text` 直接念，没给就取当前页**可读正文**（隔离世界提取器，与阅读模式同源启发式，开放 Shadow DOM/同源 iframe 也认；封顶 20000 字符、截断如实回报），`stopSpeaking` 随时停（分级 readonly——消音永远安全；readAloud 本体留 sideEffect，与 notify 同类）。配套把 TTS 服务接上 synthesizer delegate——**自然读完/被打断时 `isSpeaking` 现在会归位**（此前读完后阅读模式工具条一直显示"在讲"）。桥补 `GET /speech` 与 `POST /speech/stop`（自动化观察与收尾）；能力页归类「媒体提取」。E2E 新增 MUSCLE16（文本路径→在讲→停→页面提取路径带标题→停），定点探针 7/7 ALL PASS。
- **会话预算与超支提醒（v0.7.18）**：给会话设 token 预算（0 = 关；桥 `POST /agent/budget`，或对话里说一句「把预算调到 xx」——新工具 `setTokenBudget`，只在用户明确要求时调）。用量按**对话累计**（`AgentUsage` 同口径：主回合 + 旁路调用）算：到当前档位额度的 **80%** 面板状态行出 chip（橙，悬停含明细）；到 **100%** 回合**停在步骤边界**并给一次性说明（"不再静默继续"）——停机即把档位推进到 `floor(used/budget)+1`，调大预算或继续说一声就能跑到下一档，而不是一碰上限永久卡死；档位随会话落盘，互不串台。状态行 chip 与桥 `GET /agent/budget`（budget/used/state/stopLevel/percent）同源；跃迁经 BridgeEventBus 发 `agentBudgetWarning` / `agentBudgetStopped` 事件。纯逻辑（档位评估/阶梯推进/百分比/停机文案）进 tests/run.sh；E2E 新增 MUSCLE17（假端点带 usage 推到 460/500 → warning；续跑 → 停住 + 档位阶梯前进），定点探针 7/7 ALL PASS。
- **热点选题助手（v0.7.18 收官）：内置「热点选题」剧本 + 每日选题采集一键安排**——新内置技能 `hot-topics`（随启动幂等种入，老装机也自动拿到）：promotionBrief 读已有选题去重 → **readURL 读热榜/趋势页**（技术社区 + 综合热榜各一条即够，DPP 站点优先 pageExtract）→ 挑 3-5 个与运营目标相关、能写出观点的热点 → 逐条 `promotionSave {status:"idea", platform=来源站点, title=题面, body="切入角度 + 来源: <url>", goal=相关目标}`；规则写死"只报实读、来源链接来自本次返回、不编造热度、一场 3-5 条封顶、不蹭涉政八卦"。配套「运营」页新增**每日选题采集**开关（09:30）与桥 `POST /promotion/review {"kind":"dailyTopics"}`（幂等安排/撤销，与每日采集/每周复盘同一单一定义）——定时任务触发时按同一剧本跑。桥的 `/promotion/state` 帖子 JSON 顺带补出 `body`（选题的切入角度与来源链接在正文里，集成与断言要读它）。定点探针 8/8 ALL PASS：readURL 实读热榜、两条 idea 入库、**goalID（领域）与来源链接带齐**、任务一键安排与撤销；E2E MUSCLE18 已进套件。






## [v0.7.17] - 2026-10-16
### Changed

- **心跳巡检与收件箱聚合归一（v28）**：心跳巡检的"末次以来信号"改为复用收件箱的同一份构建逻辑（`AgentInbox.build(since:)`）——此前两处各写了一套同样状态的收集（监视变化/任务失败/被打断回合/待回复会话），口径迟早漂移；归一并顺带给心跳补上"待回复互动"信号、明确跳过被扣通知（它们本来就会合流成摘要，不该再触发心跳提醒）。`since` 模式（监视/任务/互动按时刻过滤）进 tests/run.sh。另补「工作区」面板离屏快照（`/panel/snapshot?name=workspaces`）——「已归档会话」区块已目视验收（时间/标签数/代表 URL/恢复/删除，三语正确）。

### Fixed

- **活动窗口解析加可见性回退**：`activeTabManager` 在活动窗口已关闭/不可见时回退到任一可见窗口——此前桥端点与工具解析会拿到死窗口的（空）标签列表（实测：关掉活动窗口后 /state 显示空标签、外部清理扫不到真窗口里的标签）。另修正两处陈旧注记（savePage 早已接线：File 菜单 + ⌘S；AGENTS 同步）。
- **"后台应用里智能体点击静默失效"（v25 根因修复，真 bug）**：应用不在前台时，AppKit 会把落在非 key 窗口上的鼠标事件当"激活点击"消费掉——`SyntheticInput` 用 `NSApp.sendEvent` 投递的真实事件因此整批消失：实测同一条 [拖拽 + 文字点按 shadow 按钮 + 点下载链接] 用例，前台 4/4 全过、后台 4/4 全败；这既是 execution E2E 那簇"抖动项"（拖拽序列/影子按钮/下载确认）反复红的真根因，也意味着**定时任务/后台回合里智能体替人点的每一个按钮在用户正用别的应用时都白点**。修法：`BrowserWKWebView` 覆写 `acceptsFirstMouse → true`——浏览器惯例（非活动窗口的首次点击既激活也投递），点击照常送达且不抢焦点、不激活应用；修复后同一探针后台 4/4 全过，execution E2E 连续两轮 76 项 ALL PASS（此前该簇按约一半概率红）。
- **窗口生命周期的两处"后台静默失效"（v26 跨窗口测试照出）**：① **新窗口开不出来**：`newWindow` 工具走 CommandBus 的 key-window 守卫命令，应用在后台时（keyWindow 为空）命令被所有窗口丢掉——实测后台 3/3 失败（先 activate 也来不及）；改为**按会话点名的 NotificationCenter 广播**（只让该会话所在窗口调 openWindow），后台 3/3 成功。② **关窗后投递目标仍指向死窗口**：窗口关闭时没有人把 `deliveryTarget` 转走，后续回合的智能体工具全跑在一扇不可见的死窗口上（点击/导航/取页面全部静默失效，测试里表现为"整批交互都没反应"）；现在关窗即转交给仍在世的最近注册会话（一个都没有则清空，桥/工具如实报"无活会话"）。另收紧 `activeTabManager` 的可见性回退（活动 manager 连选中标签都没有时也回退，避免解析到已关窗口的空标签列表）。
- **后台窗口的两处"够不着"（v27 实证修复）**：① **关不掉后台窗口**：`closeWindow` 靠 `webView.window` 找宿主，而挂起的后台标签没有挂到窗口上的 webview（原生新标签页同理）——工具只能回"就关不掉"；改走**按会话点名的通知**（与 newWindow 同路径），ContentView 持有窗口引用、不受挂起影响（实测前台/后台都能关）。② **不带 URL 的新窗口焦点不落地**：`newWindow {}` 的新窗展示原生新标签页（无 webview），焦点步进永远拿不到宿主 → 工具回"created but couldn't be focused"；改用 **AppKit 窗口差集**找新窗并 makeKey。另修桥 `windowVisible` 的假阴性（只查选中标签 → 挂起标签没有 webview 就误报不可见；改为扫全部标签，任何人挂到可见窗口即算活）。




### Added

- **历史定向清理与标签组改名（v23，替人干活补件）**：新增 `deleteHistory` 工具——按域名（含子域）和/或时间窗（`before`/`after`，"yyyy-MM-dd" / "yyyy-MM-dd HH:mm"）删除历史，**必须带至少一个条件**（清空仍是 clearHistory 的活，防手滑清库）；删除走既有 Store 路径，同步墓碑照常生效。新增 `renameTabGroup` 工具（按组名改名）。桥补 `GET /tab-groups` 与 `POST /tab-groups/delete`（测试清理与外部驱动）。E2E 新增 MUSCLE9（只碰 fixture 标签与 127.0.0.1 记录：入组→改名→复查→按域清历史→复查已清）——顺带把测试期间的本地 fixture 记录从历史里清干净。execution 套件 71 项。
- **分屏与组折叠进工具面（v24）**：新增 `splitView`（把指定标签放到右栏与当前标签并排——对比两页的硬需求；缺省取相邻标签）与 `unsplitView`（解除分屏，右栏标签留作普通标签）；新增 `collapseTabGroup`（按组名折叠/展开，`collapsed` 可显式指定）。桥 `/tab-groups` 返回补 `collapsed` 字段。E2E 新增 MUSCLE10：进入分屏→折叠组→复查（桥 `/split` + `/tab-groups` 双复核）→解除分屏，76 项。
- **收件箱（v26，Agent 窗口新目的地「收件箱」）**：把「等你处理」与「智能体替你盯着的变化」收成一张清单——待处理项（被打断的回合 / 48h 内待回复的会话 / 待回复互动 / 被免打扰扣下的通知，可一键补推）与变化信号（页面监视命中带 AI 分析摘要 / 失败的定时任务），行内动作直达（回到会话 / 运营台账 / 任务页）。数据经 `AgentInboxCollector` 从各 store 收集、`AgentInbox.build`（纯函数，进 tests/run.sh 12 项）分节；同一份构建逻辑同时供 Agent 窗口页、桥 `GET /inbox` 与离屏快照（`/panel/snapshot?name=inbox`）使用；侧栏带「等你处理」数角标。E2E 新增 MUSCLE11（手造待回复会话→/inbox 命中→删文件消失；强制免打扰→notify 被扣→补推→消失，策略原样复原）。
- **归档会话可找回（v27）**：「工作区」面板新增「已归档会话」区块——窗口关闭时会话移进归档（保留最近 5 个），现在能看到**每一条的时间、标签数与代表 URL**，一键恢复到当前窗口或删除（归档文件保留、非破坏；容量上限自然淘汰）。智能体侧补 `listArchivedSessions`（只读）/ `restoreArchivedSession`（恢复到本窗口，替换标签、描述已明示）两个工具——"我关掉的那扇窗还能找回吗"现在 Agent 也能答；桥补 `GET /session-archives` 与 restore/delete 端点（文件名收口校验：只收归档目录里的纯文件名 + `archived-` 前缀 + 无路径分隔/穿越）。元数据解析是纯逻辑（`SessionArchive`，harness 786 项）。E2E 新增 MUSCLE12（手造归档→桥列表→在新窗口恢复→复核标记 URL→关窗）。





## [v0.7.16] - 2026-10-15
### Changed

- **操作惯例补条（实测沉淀）**：重站首访的风控局域页可能"完成但 body 近乎为空"或卡在中途解析（掘金实测：complete/3 节点 或 loading 卡住，刷新一次即完整渲染）——惯例层新增"先重载一次再判定页面坏了"；掘金此项在新旧两个构建上表现一致，确认非回归。

### Fixed

- **模型服务更新语义**（E2E 踩出）：`POST /ai/profiles` 更新分支改为与文档一致的"字段可选、空值保持原值"——此前 endpoint 必填（只传 model 的调用被 400）、且 model 会被缺省值**静默清空**。
- **`<a download>` 与附件下载失效**（execution-e2e 逼出的真 bug，波及所有站点的下载按钮）：导航策略没接 `shouldPerformDownload`（点了只会导航不下载）、`navigationAction:didBecome download:` 未实现（属性型下载拿不到 delegate 给 destination，WebKit 数毫秒内失败删档）、`Content-Disposition: attachment` 但 MIME 可展示的响应会被直接当页面打开——三处一并修复，统一走 WKDownload → DownloadStore 正常链路。
- **工具助手热补种（实机偶发自愈）**：极少数文档形态下隔离世界的 `__desire*` 注入会缺失，`getPageSnapshot` 等直接报 `Can't find variable`（实机观测一次，挂起恢复 / document.write 重置均不可复现，机制未钉死）——现在 `callAsync` 收口检测该 ReferenceError 后**就地重注入 dom-tools 并自动重试一次**，把罕见硬失败变成透明自愈（仍失败则按原错误返回并附标记，日志留痕）。
- **日历授权缺 entitlement（硬验证时 tccd 日志实证）**：Hardened Runtime 下 `kTCCServiceCalendar` 强制要求 `com.apple.security.personal-information.calendars`——缺失时 TCC **直接拒绝、连授权弹窗都不弹**（提醒事项无此要求，所以只坏日历）；已补进 entitlements（个人信息类属安全类别，开发签名可用；实测授权跨重建保留——TCC 按 Apple Development 证书身份认账）。
- **停止按钮对"挂死连接"无效**（用户实测报告：刷新变叉后点击无反应）：页面子资源卡在永不响应的连接上时（实测：某站 32 个 CDN 请求悬置十几分钟），WebKit 既不取消也不回调——`isLoading` 永远停在 true，叉点了"没反应"、图标也不翻回。现在工具栏叉与菜单「停止加载」（⌘.）统一走 `Tab.stopUserLoad()`：stopLoading + `window.stop()` 兜底 + **立即认领已停止态**（图标即翻回 ↻，挂死页可一键重载重试；旧加载若稍后真收尾，回调再置一次也无害）。已在"永不响应"实况（含用户当场卡住的标签）上双向验证；`/state` 顺带补了 `loading` 字段供桥观察。
- **关窗僵尸与 macOS 窗口级还原（跨窗口测试照出的存量问题）**：窗口关闭后 TabManager 不摘除 → 退出时它照样把已关窗口的会话写回 session-index → 下次启动多还一扇窗、还会挤掉真实会话的"最近"位（实测：幽灵窗口两轮复活）。修法：`willClose` 时从协调器摘除（摘除时记下"最后关闭会话"，关掉最后一扇窗再退出仍照常恢复）+ 关掉 macOS 的窗口级还原（应用自带会话恢复，这份重复的窗口集只会制造幽灵窗）。
- **DiskStore 乱序竞态（同一键上先删后写会被抹成删除）**：写者的 stage 由 detached 任务投递，到达顺序无保证——旧代的 remove 后到时会覆盖新代的 write。实测后果：退出路径的 session-index 被删、下次启动会话恢复全丢。修法：写者按代数拒收任何比当前 pending 更旧的操作；退出路径不再"先删索引再写索引"。回归用例（旧代删除不覆盖新代写入/新代删除生效/新代写入胜出）进 `tests/run.sh`。
- **`newWindow` 在后台应用下被静默丢弃**：命令走 CommandBus，其消费守卫要求 `hostingWindow === NSApp.keyWindow`，应用不在前台时 keyWindow 为空 → 命令被所有窗口丢掉（后台跑 E2E 稳定复现）。修法：工具先激活应用、稍候再发命令，开窗后再显式 `makeKeyAndOrderFront`，并等到新窗口的 TabManager 注册完成才返回。






### Added

- **执行肌肉增强（替人干活的基本功）**：① 鼠标操作补全——`click` 支持**右键**（上下文菜单，再按文案点菜单项）与**双击**，新增 `drag` 工具（按下→插值移动→抬起的真实事件链：滑块、排序列表、画布编辑器可用；原生 HTML5 drag-and-drop 无法合成，工具描述已如实注明并给替代路径）；② 新增 `editFile`——精确子串替换（唯一命中才动手，多命中报数拒绝，FileEdit 纯逻辑进单测），文件手术不再靠全文重写；③ 新增 `readPdf`（PDFKit 取文本层，合同/报告直接读）与 `ocrImage`（Apple Vision 端上 OCR，中英混排，截图的图表数字/收据金额都能认）。四件工具已在真机以完整回合 E2E 验证（假端点驱动：页面真实收到右键/双击/拖拽事件、文件实际落盘、OCR 认出中文与数字、PDF 取文）。
- **表单与操作惯例补全**：新增 `setChecked` 工具——checkbox/radio/switch **幂等**勾选（只在与目标不符时点击、并读回状态，杜绝盲点未知选择框），getPageSnapshot 同步为每个选择框带出 `checked` 态；系统提示词新增**代码统管的 <conventions> 操作惯例层**（右键菜单两步走、拖拽与 HTML5 DnD 边界、文件编辑先读后改、媒体阅读用 readPdf/ocrImage、表单控件分工、跳转后先等页面——对所有用户生效，不依赖个人提示词）；内置运营技能补执行套路；`tests/execution-e2e.py` 入库（本地专属：假端点 + **临时档案**驱动完整回合，13 项断言，跑完删临时档案、回切原档案）。
- **取数与存档二件**：新增 `httpRequest` 工具——直连 HTTP(S) API（汇率/天气/搜索/Webhook/JSON 下载），返回状态码 + 类型 + 正文（封顶截断），网络请求按访问等级走常规审批；新增 `exportPageAsPDF`——整页存 PDF（含文本层，非截图），发票/回执/报表一键存档，缺省落到下载目录并按页面标题命名，配 `readPdf` 可直接读回。运营每日采集提示词补「报表只有 PDF/截图时用 readPdf / ocrImage 实读数字」；`tests/execution-e2e.py` 扩到 16 项断言（本地靶服务验 httpRequest、导出→读回验证 PDF 文本层）。
- **通用工具深穿透（开放 Shadow DOM + 同源 iframe）**：整条链路一致打通——元素解析（ref/text/selector 三路）、click / fill / setChecked / select / hover / drag 的定位、getPageSnapshot、getFormFields、waitForText 全部**递归穿透**开放 Shadow DOM 与同源 iframe（组件库 / 企业后台站点不再"看不见控件"）；`setChecked` 按文案命中 `<label>` 时自动向内找 checkbox/radio；快照为无文案的复选框回退最近 label 文本。`tests/execution-e2e.py` 借 fixture 影子组件扩到 **21 项断言**（文案定位 / 勾选 / 填空 / 等文案 / 快照五路穿透全验）。
- **干活补件五连**：`waitForSelector`（深穿透等元素出现，动态渲染表单先等再动手）；`waitForDownload`（"下载并确认"原语——轮询到终态，回文件名/大小/落盘路径）；`notify`（向用户推系统通知，走通知分级：紧急直推、例行过免打扰与每日预算、溢出合并摘要）；`readPageStorage`（站点存储盘点：默认只列键名+长度，看单个值需显式传 key，httpOnly 不可见已注明）；`copyImageToClipboard`（图片文件进剪贴板）。execution-e2e 扩到 27 项断言（fixture 改 HTTP 同源伺服，含真实下载闭环）。
- **接收与归档两件**：`readClipboard` 支持**图片**剪贴板——用户复制了截图/图表说「剪贴板里的这张图」时，存成 PNG 并回路径（配 ocrImage 直接读，或交给发布流程）；新增 `exportPageAsWebArchive`——整页 `.webarchive`（DOM + 子资源，文本可选中、图片保留、可再导入 WebKit 系浏览器），保真归档发票/回执/证据页，比 PDF 更适合"存档后还要再看"。DPP 规范补口径注记：通用工具默认深穿透、声明式提取坚持 `>>>` 显式语义，两者刻意并存勿互相"对齐"。execution-e2e 扩到 **30 项断言**（剪贴板图片落盘、webarchive 落盘并可解析回页面标题）。
- **阅读列表离线缓存**：条目可缓存**离线副本**（整页 .webarchive）——页面开着就复用该标签抓取（含登录态），没开则后台加载；面板行内徽标 + 右键「缓存离线 / 打开离线副本 / 移除缓存」；新工具 `cachePageForOffline` 与 `listReadingList`（列表带缓存态与路径，离线打开即 `navigate file://<path>`）；桥 `POST /reading-list/cache`；删除条目 / 清空列表联动清理缓存文件；缓存字段随条目同步但文件是机器本地——别的设备上按"未缓存"处理。execution-e2e 扩到 **35 项断言**（离屏抓取链 + 归档可解析 + 删除联动，并修掉测试标签清理的索引漂移漏洞）。
- **navigate 首载自愈（实测沉淀转代码）**：重站风控局域页会"加载完成但近乎空文档"（掘金实测：complete + 3 节点、标题却正常）——navigate 现在做**首载健康判定**（HTML 且文字 <20 且元素 <60；纯逻辑 `PageLoadHealth` 进单测），疑似即**自动重载一次**并把结果如实写回包：成功注"已自动重载一次，页面已正常"，仍空则明说"疑似风控、可稍后重试或请用户过验证"；非 HTML 端点（JSON/图片/纯文本）不误判。execution-e2e 以两态 fixture（首次空壳、重载后完整）端到端验证，扩到 **37 项断言**。
- **OS 级协作（提醒事项 / 日历）**：Agent 新增 `addReminder` / `listReminders` / `addCalendarEvent` 三个工具——「帮我记个提醒」「下午三点开会加进日历」直接落到系统 App（提醒可带闹钟与列表、日历可带时长/地点/备注/日历名）；授权按既定纪律**懒请求 + 30 秒超时**（"弹窗永不渲染"的已知形态不会拖死回合，超时如实提示"点了允许再重试"）；日期只收**绝对时间**（三种写法，纯逻辑进单测——相对说法由模型先换算，端上不做自然语言解析以免口径漂移）；桥新增只读 `GET /system/integrations` 查授权状态（不弹窗）。execution-e2e 以"参数校验先于授权"的路径验证工具链，扩到 **39 项断言**。
- **OS 协作闭环**：新增 `listCalendarEvents`（「我明天有什么安排」——时间窗内事件按时间升序列出，含日历名与地点；`from`/`to` 收绝对时间，默认今天起 7 天）与 `completeReminder`（「带伞那条标完成」——按标题匹配未完成提醒，**多条命中不猜**、列候选让模型问用户；完成后即从 open 列表消失）；周复盘提示词补一句「可**提议**把下周关键节点排进系统提醒/日历（用户点头再落，别擅自）」。execution-e2e 新增真机读写闭环用例（已授权路径：建提醒 → 完成 → 读回不再出现 + 日历读取核对），共 **43 项断言**；顺手把一条过期断言改成状态无关判据（用户真机授权后 notDetermined 判据失效）。
- **PDF 整理硬活**：新增 `mergePDFs`（多个 PDF 依序合并——**结构级操作**，文本层原样保留、不栅格化；产物缺省 Downloads/merged.pdf，重名自动加 -1/-2 后缀）与 `splitPDF`（抽页：`pages` 支持 `3-5,8` 式页号串，1 基、区间闭合、越界报错并附总页数）——「把这三份合同并成一份」「把第 2 页单独发我」直接办。页号解析为纯逻辑进单测（全角标点容忍 / 倒序拒绝 / 升序去重）；execution-e2e 新增 PDF 工具链用例（两源合并后核对双源文本层、抽页产物精确命中目标页），共 **47 项断言**。
- **菜单栏快速入口**（v19）：不打开浏览器窗口就能给 Agent 下指令——菜单栏 ✦ 图标点开一个小浮窗（问一句、回车发送，答案落在当前会话里），「打开 Agent 面板」一键把目标窗口拉前台亮出面板。发送走既定投递口径（定时任务/桥同一目标，多窗口下按"持有会话的窗口"收敛），设置 › 通用 新增「菜单栏」区块可随时关闭（默认开）。宿主是 NSStatusItem + NSPopover：实测 SwiftUI `MenuBarExtra` 的 `isInserted:` 动态绑定（@AppStorage 与 @Published 均如此）会让本应用启动进入无限图更新循环（主线程 100%、主菜单反复重建、桥无响应；二分验证后弃用），NSStatusItem 不参与 SwiftUI 场景图且弹窗能代码收起（打开面板前先收弹窗，key window 归还浏览器窗口）。全链路已实测：AX 点开菜单项 → 键盘注入输入+回车 → 会话收到消息并完成回合 → AX 点「打开 Agent 面板」→ 面板亮出；设置开关 ON/OFF 往返（图标即时增删 + 落盘）通过。
- **文档与表格读取（v20，替人干活再补两块）**：Agent 的阅读面从 PDF/图片扩到办公文档——新增 `readDocument`（Word `.docx`/旧版 `.doc`、`.rtf`、`.odt`、`.html` 富文本转纯文本，走系统 `textutil`，不引第三方解析器）与 `readSpreadsheet`（`.xlsx` 直接解析 zip+XML 取**缓存值**、`.csv`/`.tsv` 分隔符嗅探，输出 Markdown 表；1 基 sheet 索引选工作表、行列上限截断标注）。口径显式写进工具返回：公式取上次保存结果、日期可能是 Excel 序列号；`.xls`/`.numbers` 不支持并提示另存。风险分级归 `readonly`（本地解析不写任何状态），惯例层补「读文档用哪把工具」分工；纯逻辑（CSV 解析/RFC4180 引号转义、单元格引用、sharedStrings 注音丢弃、行组装补位、Markdown 转义）进 `tests/run.sh`（+32 项）；E2E 新增 MUSCLE6（docx/xlsx/csv 真实读通 + 错类型走 `Error:` 约定并指对工具），execution 套件 51 项全过。开发中实测挖出 Swift 字素簇坑：`"\\r\\n"` 是**单个 Character**，逐字符匹配换行分支永远不命中——CRLF 表格会被当成"一行一个字段"，解析入口必须先归一化换行。
- **标签治理四件套（v21）**：Agent 现在能真正打理标签栏——新增 `pinTab`（固定/取消，固定标签显示在最前、免自动挂起）、`muteTab`（静音/取消，劫持式静音挡站点自己的取消脚本）、`moveTab`（移位：`to` = 移动后应落的下标，内部按 onMove 插入位语义平移，不会差一位）、`setZoom`（直接设页面缩放 25-500%，只读分级与 zoomIn/Out 同类）。`listTabs` 输出补状态标记 `[pinned,muted,incognito,zoom N%]`——Agent 自己就能核对自己刚做的改动。E2E 新增 MUSCLE7（钉住自己开的 fixture 标签：pin→mute→zoom→move→复查标记与位次，只碰自己的标签）；execution 套件 57 项 ALL PASS。
- **窗口与工作区工具化（v22）**：Agent 现在能管窗口和整窗快照——`newWindow`（开新窗口可带 URL，开好自动到前台并取得焦点）、`openIncognitoTab`（隐私标签，不进历史）、`closeWindow`（关掉本会话所在窗口，描述里明示会带走全部标签）、工作区四件套 `saveWorkspace` / `listWorkspaces` / `restoreWorkspace`（替换当前窗口标签，与工作区面板 Restore 同语义、返回文案明示）/ `deleteWorkspace`（沿用同名覆盖）。桥补 `GET /workspaces` 与 `POST /workspaces/delete` 供外部驱动与测试清理。
















## [v0.7.15] - 2026-10-14
### Added

- **Intel（x86_64）构建随版发布**：release 流程交叉编译 Intel 包，与 arm64 包同传 Release（SHASUMS256.txt 覆盖两种包）；Intel 构建走同一零警告闸门，verify 阶段核对二进制架构、装 Rosetta 的机器顺带启动冒烟；安装说明与产品页补 Intel 下载说明（交叉编译产物，未经真机验证）。
- **自推广能力**：Agent 按既定目标替 Desire 起草并发布推广内容——推广工作台（目标 / 草稿 / 已发 / 数据回收）三入口同源：Agent 窗口侧栏「推广」页、`/promote` 斜杠命令、桥 `/promotion/*`；配套 `promotionBrief` / `promotionSave` / `promotionMetrics` 三个工具与内置 `promotion` 技能：事实只取 CHANGELOG / 仓库 / 产品页（不虚构数据），发布前必须用户确认（照走审批链），发布后回访帖子页把浏览 / 点赞 / 评论回填工作台。
- **运营专项（自媒体 / 电商 / 推广）**：运营工作台从「自推广」扩为三领域共用——目标与经验带领域标签，新增**账号台账**（多平台账号 + 粉丝/曝光快照与增长）与**运营经验清单**（复盘沉淀、注入下次起草、精确去重）；`promotionGoal` / `promotionAccountSave` / `promotionAccountMetrics` / `promotionLesson` 四个新工具，配套 `media-operations` / `ecommerce-operations` 内置技能（发布仍须用户确认、电商改价一律先建议后执行）。
- **持续学习闭环**：帖子指标改为**快照序列**（每次回访追加一条，浏览增长可比，面板与摘要显示 +N）；定时任务支持**每周**复发，面板与桥一键「安排每周复盘」——采集账号与帖子数据 → 对比增长 → 用 `promotionLesson` 沉淀可复用结论 → 出下周计划。
- **运营流水线深化**：帖子三态流水线 选题 idea → 草稿 draft → 发布 published——`promotionSave` 支持按 `id` 更新（选题立项为草稿、改排期、补 URL），`plannedFor` 排期，选题只存标题+平台；运营页新增**选题库**段与「自动化」双开关（每日 21:00 采集数据、周一 10:00 复盘，定向定时任务）；新增 `promotionReport` 周报（目标进度/账号增长/本周表现/选题草稿/新增经验，工具 + 桥 + 面板「复制周报」同源）与 `promotionPostRemove` 工具。
- **运营指挥台**：面板行内动作直通智能体——选题「让智能体起草」、草稿「按流程发布」（先过目确认）、已发「刷新数据」，点按即切回对话派活；周报新增**平台表现**（按平均浏览分组的已发统计与最佳帖）与**发布时机**（周几发布表现最好，样本不足自动不给结论）两段，周复盘提示词补目标归档提醒。
- **互动台账**：评论/私信/提及/评价的最小收件箱——智能体巡检时用 `promotionInteractions` 批量登记（URL 或 平台+帖子+作者+正文 自动去重），「待回复」在前；面板每条可「让智能体回复」（拟稿→你过目→回复→`promotionInteractionReply` 闭环）或标忽略；摘要（promotionBrief）、周报（新增「互动」段：本周新增/已回复/待处理）与每日采集/每周复盘提示词全接线——回复永远先过你的眼。
- **发布把关与排期闭环**：新增 `promotionPreflight` 预检工具——标题长度 / 占位符 / 过度承诺词 / 正文版本号与应用版本一致性 / 裸帖无链接 / 与已发帖标题撞车，只报可核验问题、不猜平台细则，promotion 技能要求发布前必过预检；摘要与周报新增「已到排期」提醒（`plannedFor` 到点的草稿主动冒头，每日采集任务会提醒用户推进）；面板账号与帖子行新增快照**迷你趋势线**（粉丝/浏览曲线随采集自动生长）。









## [v0.7.14] - 2026-10-14
### Changed

- **集中搜索面板空查询默认态**（0.7.14 验收口径补全）：面板打开即列出打开标签（与 "Open Tabs" 分组同款行）——不用先想关键词就有可点结果；输入关键词后切换到四源过滤结果。

### Fixed

- **FindBar 修复**（0.7.14 跨标签查找批）：popover 行点击的闭包引用改为不可变捕获（此前 @State 闭包内引用外层可变状态，行为不可靠）；FindBar 的 onScanOtherTabs/otherTabMatches 等新参数全部带默认值——嵌入式精简形态不受影响。

### Added

- **集中搜索（Search Everywhere，⌘⇧F）**：统一搜索面板跨**打开标签/历史/书签/阅读列表**四源同搜——分组展示、即输即滤（120ms 去抖）、每源 20 条上限；回车直达（打开标签 → switchTab，其余 → 新标签打开）。Tabs 菜单新增入口（⌘⇧F，可在快捷键设置改）；桥端点 GET /search/everything?q= 同一查询（四源结构化断言）。查询纯逻辑（SearchEverywhere）进单测 harness（跨源命中/空查询/每源上限/大小写不敏感）。
- **跨标签查找**（0.7.14 查找增强）：Find bar 新增「在其他标签中查找」按钮——扫描其他标签页的匹配计数（TreeWalker 文本统计，无副作用），popover 列出（标签名+计数，按计数排序），点击跳到该标签并执行查找。多窗口的标签也在扫描范围（TabSessionCoordinator liveManagers）。
- **DPP forms profile 字段语义标注**（评审遗留）：data-dpp-field-type 属性透传为 FieldSpec.type（L1 属性标注路径）——站点可标注 email/tel/date 等语义类型，智能体填表时可区分处理。
- **适配包存活度核对端点**（POST /dpp/adapters/verify，设计评审 #8 的核对面）：对每个启用的适配包找当前打开的匹配标签页，逐视图跑真实 querySelector 计数——报告 alive/rotten/no matching tab open 与各视图元素数（-1 = 选择器抛错）。站点改版导致的"包腐烂"从此一键发现，不再静默失效。
- **集中搜索增强**：① **键盘导航**——↑↓ 在结果间移动选中（强调色高亮），回车打开选中行（无选中 = 第一行）；② **高亮匹配片段**——结果标题中命中段以强调色+粗体渲染（AttributedString，大小写不敏感）；③ **Agent 会话第五源**——对话标题/消息文本命中即列出（"Chat" 徽标），点击载入该会话并打开 Agent 面板；空查询默认态同步列出。原有鼠标点击/回车开首行行为不变。





## [v0.7.13] - 2026-10-14
### Added

- **鼠标手势 + 超级拖拽**（默认关，设置页 › 通用可开）：右键拖动画轨迹执行动作（左=后退/右=前进/上下滑动=关标签与新建/左右=刷新，原地点击仍是右键菜单）；拖链接到页面空白 = 新后台标签打开（super-drag.js 上报链接，mouseUp 判定拖动距离，点击行为不受影响）。
- **地址栏引擎关键字**（自定义引擎可设关键字）：`gh rust` → 该引擎搜 rust；关键字在设置页添加自定义引擎时填写（可选），支持 %s/{searchTerms} 模板占位。
- **窗口级工作区**（Backlog 提前，0.7.13）：工具栏更多菜单新增「Workspaces」——当前窗口全部标签一键存为命名快照（含选中标签/档案归属），任意时刻一键恢复到当前窗口（选中标签急切恢复、其余挂起，与既有会话恢复同路径）；同名覆盖=更新，删除即清；WorkspaceStore 持久化 DiskStore。
- **DPP 运维收尾**（设计评审 #6/#8/#9 落地）：① **规范与实现状态拆分**（#9）——实现进度/E2E 表移入 docs/DPP-IMPLEMENTATION-STATUS.md（维护者文档），DPP-PROTOCOL.md 保持 normative（章节重排 §8 已知限制/§9 自检，spec.html 同步），§10 段替换为仓库链接；② **per-host context 注入开关**（#6）——DPPConfigStore.contextDisabledHosts + /dpp/context-toggle 桥端点，关闭后 page_context 的站点语义上下文（persona/rules）不再进 system 层（模型只看 views/actions）；③ **适配包陈旧提示**（#8 展示面）——installedAt 随包落盘，设置页超 90 天未核对显示"站点改版可能失效"标注。




## [v0.7.12] - 2026-10-12
### Changed

- **DPP 适配生成先澄清需求**（用户反馈：有些网站很大，不是全部都要适配）：create-dpp-adapter 内置技能与 saveDPPAdapter 工具描述重写——Agent 收到适配请求时**先探查页面的可适配能力清单（A 阅读/B 评论/C 点赞…）让用户勾选**，范围（全站 vs 特定页面类型）也由用户定（大站点建议按页面类型拆多包，独立启停）；确认后才生成，views 只含用户要的功能。
- **YouTube 拦截转向社区规则订阅（自研播放器对抗撤退）**：自研 JS 状态机（倍速夹回对抗/媒体终结/video_id 保险丝）在与 YouTube 播放器状态机的对抗中来回摆动（三轮：加速失效→正片被快进→广告连播），判定为结构性陷阱——**对抗升级不可维护**。改为：预置订阅 uBlock Origin 团队的 quick-fixes 清单（251 条编译通过，社区持续维护 YouTube 对抗规则，网络层无感拦截）+ 保留 CSS 隐藏 + 移除自研 JS 状态机与反检测脚本的反噬部分（反检测脚本本身保留——它不参与播放器对抗）。设置页过滤列表新增「uBlock Quick-Fixes」开关（默认开，可关）。


### Added

- **DPP 设计评审 P2 生态三件**：① pageExtract **显式截断契约**——超 hardCap 时返回 JSON 内嵌 truncated:true / moreAvailable / totalBeforeCap（模型机读后可决定是否继续取，不再靠正文尾注猜）；② pageAction 成功回执带**事后快照**（主视图前 3 条随回执返回，Agent 一回合内自验证省一轮 pageExtract）；③ 适配包**存活度机制**——抽取/动作失败计数（成功清零），3 次连续失败亮"疑似失效"、8 次自动禁用（用户可重启用），桥 /dpp/adapters 列表透出 health/sourceURL/installedAt。
- **Agent 自助生成 DPP 适配包**（saveDPPAdapter 工具）：用户对不支持 DPP 的站点说"帮我做个适配"即可——Agent 用 executeJS 探查页面 DOM、验证选择器、调本工具生成 adapter-1 JSON 落盘（hosts/pathPrefixes/views/signals/actions 全字段；name/hosts 校验 + views 结构校验，选择器错误当场报错）。包立即可用（同站点名覆盖=更新），persist/outbound 动作照走审批链；DPPAdapterAuthoring 纯逻辑（校验/渲染/包名推导）进单测 harness（622 项全过）。真链路 E2E：Agent 在豆瓣页自主探查 DOM → 生成 douban-movie-test 包 → 落盘并在桥列表可见。
- **YouTube 广告网络层拦截**（用户反馈"要无感拦截而不是快进"）：内置 Ads 规则新增 6 条请求级阻断——get_video_ads、youtubei log_event*adformat、googlevideo videogoodput、youtubei player*adformat、stats/qoe*adformat、error_204*adformat（中插广告的拉取/上报请求在到达播放器前被 WebKit 切断）。全部经 /filters/probe 编译验证通过；播放器内 DOM 对抗（v4 媒体终结）降级为最后防线——网络层拦掉大部分后 DOM 层很少触发。
- **YouTube pre-roll（片头广告）无感去除**：移植 uBlock Origin 的 json-prune 机制——documentStart 注入 JSON.parse hook，把 player 响应（youtubei/v1/player）中的广告容器字段（adPlacements/playerAds/adSlots）在页面解析前剪掉。pre-roll 广告数据内嵌在 player 响应 JSON 里（非独立请求，网络层拦不掉），此机制与 uBlock 系插件去除 pre-roll 完全同源。实测 playerResponse 已无广告字段、播放器直接从正片开始。




### Fixed

- **DPP 设计评审落地**（docs/DPP-DESIGN-REVIEW-2026-10-11.md 的 P0/P1 批）：① 静态步骏述算风险下限——run 步骤语义（navigate/submit 类 click/Enter/mcp/upload）无论页面声明什么都强制升档（autoEdit 静默执行未标注 outbound 动作的绕过面封死）；② DPP 动作授权键加 frame host 维度——跨源 iframe 声明的动作授权按声明来源 frame 隔离，同名页面动作互不影响（与审批卡展示一致）；③ 适配包 URL 安装 https-only（http 拒收，与注释对齐）+ sourceURL/installedAt 随包落盘（供应链审计）；④ events 对象形态的 warning 诚实化（debounce/on 未实现，固定 3s——别让站点以为声明生效）；⑤ 三处死代码/文档修复（merged 恒真条件拆成 mergingFrames 独立函数、isBridgeSafeLocal 的 effects=="danger" 死分支、规范 chat profile 示例的重复 run 键）。单测 602→614（floor 矩阵 + bridgeSafe 四态）。
- **merged 合并不再丢适配包来源戳**：DesireProtocol.merged 返回值的 warnings 此前只取页面侧——适配包以 site 参数参与合并时，"adapter: <名>" 戳整条丢失（DevTools 徽标与 page_context 的 via community adapter 标注双双失效——本轮审查冒烟时实测发现）。修 = warnings 取并集。
- **YouTube 广告对抗 v3：修"广告跳过了但正片被 16× 播完"**——v2 守卫的失效模式：广告结束瞬间 YouTube 恢复正片的顺序是先 ratechange（1×）→ 后摘 .ad-showing class，守卫在 ratechange/rAF 里同步查 adShowing() 仍是 true，把刚切回的正片压回 16× 高速播完。v3 三重防线：压 16× 只在"我们已亲手设过 16×"（speededByUs）的会话内生效；还原走双重确认（class 摘除后连续 2 tick 无广告才把倍速还给用户，单帧 class 抖动不再吞正片）；正片保险丝（有 video_id 的真实内容速率 >4× 立即降回 1×——宁可放跑一个广告也不能毁掉正片）。桥实测：正片 1× 正常播放、广告逻辑不变。
- **YouTube 拦截"效果更差"修复**（外部加固批引入的两处退化）：① Skip 点击一次性去重——连播广告的第二支不再点（同选择器按钮被去重跳过，整段广告播满）；改按 1.5s 时间限速，连播每支都能点；② 媒体还原加了 hasRealVideo 门槛——媒体摘除态下 video_id 仍是播放器状态恒为 true，正片 src 永不写回（黑屏）。还原条件只看"src 空+有保存值"。保留加固批的合理改进：stableAd 迟滞判定、MutationObserver 子树范围扫描、rAF 永久循环改 300ms tick、媒体还原 hasRealVideo 防误还原正片的反向场景（还原后正片被覆盖回广告 src）由"src 空才写回"本身保证。
- **DiskStore.flushSync 的 QoS 倒挂修复**（Xcode 运行时警告：UI 线程以 User-interactive QoS 等待 Default QoS 后台任务）：flushSync 的信号量等待发生在主线程（终止路径），而它等待的 detached 任务未设优先级（Default）——高优等低优。detached 任务显式提为 userInitiated（终止路径的落盘本就是用户发起的最高优）。






## [v0.7.11] - 2026-10-12
### Changed

- **请求准备移出 MainActor**（GPT 多窗口批 Task 9 落地）：buildRequestMessages 的四步纯转换（块压缩/未配对 tool_calls 修复/超长工具结果摘要/巨型消息封顶——对大会话每轮各一次全量扫描）改为 MainActor 抓快照 + Task.detached 后台转换 + 回合所有权守卫（陈旧准备绝不覆盖当前状态），system 分层注入留在 MainActor 拼装。AgentMessage/ContextCompaction 提 nonisolated、Log.agent 提 nonisolated。流式与长会话行为不变（转换纯函数、单测 602 全过）。

### Fixed

- **导航排查：后退/前进按钮状态在 SPA 站点失效**——canGoBack/canGoForward 只在 didFinish 更新，而 pjax 站点（掘金等）的路由切换是 pushState（不触发 didFinish）：首页点进文章后后退按钮一直灰着，与长按菜单里的实时历史栈自相矛盾。改为 KVO 实时同步（ WKBackForwardList 变化瞬间更新按钮态）。桥实测：普通导航往返 ✓、纯 pushState 往返 ✓；掘金文章页栈只有一条是其自身反爬 replaceState（决策序列干净，Safari 同现象），非浏览器缺陷。
- **性能：启动路径的 Keychain 读全部移出主线程**——取证（com.apple.runtime-issues 一小时 99 条）显示 Performance Diagnostics 反复报 "This method should not be called on the main thread"（SecItemCopyMatching 阻塞调用），突发紧贴每次启动（启动后 1-3 秒内 6-11 条）。两处根因：AgentPreferenceStore.init 对每个档案同步读（n 档案 = n 次阻塞调用）、SyncStore.init 的 master key/token 三读。改为 Task.detached 后台读、结果回主线程发布（hasAPIKey/hasKeyByProfile/hasSyncKey/authState 全是 @Published，首帧几十 ms 的未配置窗口由 UI 自刷新补上；真实消费点 runSyncCycle 在启动 3s 后，晚于回填）。实测档案 Key 状态与主密钥指纹回填均正常（auth 显示登出 = 真实无令牌态，非回归）。
- **多窗口重构的两个回归修复**：① **初始页/整个 chrome 黑屏**——WindowBrowsingContext 重构把 tabManager 从 StateObject 改成 ObservedObject 绑"每次 init 新建的 context"：SwiftUI 会多次 init ContentView（sessionID 恢复等），每次新建一个空 TabManager，渲染读最新空的、而会话恢复写在 StateObject 保留的第一个上——渲染与数据分裂成黑屏。修 = tabManager 改为从保留的 windowContext 派生的计算属性 + context 转发 manager 的 objectWillChange（观察链不断）。② **悬浮球卡在展开态拖不动**——球被改成 per-window 实例，但设置页/桥/独立 Agent 窗口仍写 shared 单例：isExpanded/enabled 状态分裂，桥收起 shared 后面板实例仍卡展开（展开态禁用拖动手势）。修 = 球回归全局单例（overlay 每窗口挂载但状态只有一份）。临时实例截图+geometry 复现取证，修复后初始页全渲染、球回正常收起态。
- **YouTube 中插广告"加速了但仍很久才播完"**：根因是播放器在广告段把 playbackRate 夹回 1×——原 300ms fastTick 设 16× 后立刻被压回，广告大部分时间仍是原速（16× 只有设下去的瞬间生效）。修 = 双保险对抗：video 元素 ratechange 事件守卫（播放器夹回的瞬间立即拉回 16×）+ ad-showing 期间的 rAF 紧循环持续压住；SPA 重建 video 元素时自动重挂守卫。静音/跳过按钮点击/seek 兜底逻辑不变。




### Added

- **DevTools DPP 面板适配来源徽标**：Declaration 段显示"Adapter: <包名>"强调色徽标（来自协议 warnings 的来源戳），"这份协议不是页面自己写的"一眼可见；Parse warnings 段同步过滤掉该来源戳（它是元信息不是警告）。
- **博客园适配包**（docs/dpp-adapters/cnblogs.json）：博文页正文精读/排噪（导航/侧栏/广告）+ 阅读数与元数据视图——文章本体（标题/作者/发布时间）站点自带 JSON-LD（BlogPosting）直接消费，适配包只做增量；真实页面 merge 日志/inspect/抽取三重验证（views=2：原生 article + 适配器 post，正文 5892 字符/阅读数命中）。坑：博客园文章 URL 形如 /<用户>/p/<id>，pathPrefixes 前缀过滤不适用——已放开为全站（views 的 item 选择器在非文章页自然落空）。
- **启动分段插桩细化**（性能轮）：AppState.init 装配链逐 store 拍点（BrowsingState/AgentState/SyncStore/RemoteControlStore/profile 恢复/startAutoSync）+ ContentView.init 计时——launch phase 日志从三拍黑盒变成全链细分，启动回归可直接从统一日志定位到段。本节数据结论：AppState 装配 18ms（Keychain 后台化后 SyncStore 不再是大头）、ContentView.init 3ms，首窗剩余构成 = SwiftUI Scene 装配 ~258ms + 首帧与首个 WKWebView 创建 ~152ms（WebKit XPC 平台固有）。
- **Hacker News 适配包**（docs/dpp-adapters/hackernews.json）：列表/单帖/评论树三视图（stories 用 tr.athing.submission 精确类名——详情页的评论行同为 tr.athing，裸类名会把首条评论误当"故事"；indent 像素 /40 即楼层，总结评论讨论串时按层级读），真实页面列表 30 行与 7 楼评论全命中；投票需登录未声明。适配目录现有五包。
- **Wikipedia 适配包**（docs/dpp-adapters/wikipedia.json）：条目页正文精读/排噪（导航/编辑按钮/navbox）+ infobox 与引用分区，全语言同构；条目元数据站点自带 JSON-LD（Article）直接消费。坑：适配包视图命名撞上 L0 隐式视图的同名（article）会被"页面声明优先"压住——改名 wiki 后双视图共存，教训（适配包的 views 别用 article/items 这类 L0 常用名）写进适配目录守则。
- **桥直驱 agent 工具链的两个端点**（适配包自测主通道）：`GET /page/extract?view=<名>` 与 `POST /page/dpp-action {"name","args"}`——与 agent 的 pageExtract/pageAction **同一实现**（BrowserToolProvider.execute，非模拟），多 tab 场景先 /switch-tab 对齐 deliveryTarget 的 selectedTab 再调；pageAction 经桥只建议 local 效果动作（persist/outbound 的授权语义仍由 agent 审批链承担）。用六个适配包完成矩阵自测：HN stories（顺带修 link 字段的 type:url——此前抽到的是标题文本）、wikipedia wiki、v2ex topic、cnblogs post、掘金 fill-article-title（DSL 执行+页面回读全通）。
- **Stack Overflow 适配包**（docs/dpp-adapters/stackoverflow.json）：问答页三视图——问题（票数/正文/提问时间）、答案列表（采纳答案带 acceptedHint，读时先报采纳项）、楼层旁小字评论；真实页面 30 个答案抽取全命中。适配目录现有七包。
- **page_context 透出适配来源**：协议来自第三方适配包时，Agent 的页面上下文 [DPP] 行会带 "(via community adapter: <包名>)"——声明精度与站点原生不同档，行动前多一分核对意识（与 DevTools 徽标同一数据源）。
- **Hacker News 适配包补声明式翻页**：stories 视图声明 pagination（More 链接 a.morelink）——pageExtract all=true 实测自动跟页（10 页全量），列表场景"把前 N 页都收集齐"一句话可达。
- **豆瓣电影适配包**（docs/dpp-adapters/douban-movie.json）：条目页双视图——subject（标题/年份/评分/评分人数/#info 块）+ comments（热门短评：作者/推荐档/短文/有用数，按有用数排序）；真实页面《肖申克的救赎》抽取全命中（评分 9.7、首条短评 26509 有用）。更多短评需登录翻页（context 里已向 Agent 说明）。
- **V2EX 首页适配包**（docs/dpp-adapters/v2ex-home.json）：话题列表视图（标题/节点/回复数/成员/元信息行，50 条全命中）——浏览热帖/总结当日讨论；详情读评论配 v2ex.json（两包按路径分工）。









## [v0.7.10] - 2026-10-11
### Added

- **DPP SDK 独立成 npm 包（packages/dpp-sdk）**：单一逻辑源 src/core.js（宿主桥可注入 env），build 拼出 UMD（浏览器 script 直引，挂 window.desire）与 ESM（bundler/`createDesireSDK`）两个产物并自动同步 website 部署源与 app bundle 副本（此前两份手写副本漂移）；node 冒烟 10 项（expose/emit/validate/profile 契约/UMD 沙箱求值）；package.json+README+发布脚本就绪，npm 账号到位后 `bash packages/dpp-sdk/publish.sh` 即发。
- **DPP 第三方适配包（外挂协议）**：站点不主动接入时由社区按 host 声明——声明式 JSON（与 SDK expose 同一协议格式，纯 JSON 零代码），动作照走既有审批链不引入新执行面；优先级=页面原生声明>适配器（站点接入后适配包自然失效，实测断言）；`DPPAdapterStore`（Application Support/Desire/DPPAdapters/*.json，逐包启停持久化、坏包报错不影响他包、protocol/protocolBody 双键名容错）；设置页 DPP 区新增列表（导入/启停/删除/坏包原因）；桥 `GET /dpp/adapters`、`POST /dpp/adapters/import|toggle|remove`；示例适配包 juejin.json（docs/dpp-adapters/ 附编写守则）。fixture E2E：适配器协议生效（views/signals/ignore/来源戳）+原生优先 PASS。
- **顺手修**：桥 `/protocol/inspect` 加 `index?` 参数（多窗口下 deliveryTarget 的窗口未必是 active 窗口，E2E 实测错位）；inspect 的 views.fields 序列化非 plist 类型曾静默产出空响应；navigate 端点对挂起标签先 unsuspend（挂起路径置空 navigationDelegate，直接 load 后 didFinish/didCommit 全不来——桥的加载完成信号、DPP 解析、isLoading 清零全断）。
- **掘金 DPP 适配包（真实 DOM 核对）**：`docs/dpp-adapters/` 两包——`juejin.json`（文章页：标题/作者/时间/正文/标签 + 评论行三字段视图 + like-article/评论两个声明动作）、`juejin-compose.json`（创作页：发沸点/填文章标题，CodeMirror 正文经 executeJS 的诚实口径写进 context.rules）；全部选择器在登录态真实页面逐项验证（点赞按钮真实形态是左侧悬浮栏 `.panel-btn:has(.icon-zan)`——首轮误判成推荐流的 `.action-list`，已修正并人工 toggle 闭环；评论发送钮空输入原生禁用防误发）。
- **适配器合并语义修正**：页面原生声明（哪怕只是最低限度的 JSON-LD 隐式视图）不再让适配器整包让位——改为 merged 补齐（页面同名键胜、适配器独有键进来）：掘金页面自身的 article 视图与适配器的评论视图/点赞评论动作共存，实测断言。
- **pageAction fill 步骤支持 contenteditable**（掘金评论框/沸点编辑器、B 站简介等全部受益）：execCommand 输入链（focus→selectAll→insertText），Vue/React 都能感知；普通表单控件维持原生 value+input/change。
- **桥审批端点**：`GET /agent/approvals`（面板里等着的审批卡）+ `POST /agent/approvals/resolve`（allowOnce|alwaysAllow|deny）——agent 全链路 E2E 不再需要人手点卡片。
- **桥 /protocol/inspect 加 index? 参数**（多窗口下 deliveryTarget 窗口与 active 窗口错位）+ views.fields 序列化非 plist 类型静默空响应修复；navigate 端点对挂起标签先 unsuspend（挂起路径置空 navigationDelegate，直接 load 后 didFinish/didCommit 全不来）。
- **适配包从 URL 安装（社区分发闭环）**：设置页第三方适配区新增"URL"按钮（弹窗粘 http(s) 直链——仓库 docs/dpp-adapters/ 的 GitHub raw 链接即包源），拉取校验（JSON/2MB 上限）落盘同名覆盖；桥 `POST /dpp/adapters/install {url}` 同一链路，实测从 raw.githubusercontent.com 装回掘金两包并生效；掘金适配补 auth 登录态指引（loginUrl+note，未登录时 Agent 知道引导登录而非空跑动作）；DPP-PROTOCOL.md 新增 §7.4 第三方适配包章节（合并语义/安装/编写守则与目录 README 互链）。
- **V2EX 适配包**（docs/dpp-adapters/v2ex.json）：主题详情页（/t/）读主题+回复双视图（标题/作者/meta + 逐楼 author/content/time），服务端渲染结构极稳，真实页面抽取验证 29 楼全命中；适配目录 README 新增"现有适配包"清单（含 raw 链接即包源的安装说明）。





## [v0.7.9] - 2026-10-10
### Fixed

- **白板"前端资源缺失"修复**：React 前端资源随 fileSystemSynchronized group 打包时被平铺进 bundle 根，而加载器找的是 `WhiteboardApp/index.html` 子目录——永远找不到、每次都退占位页；改为根级优先、子目录兜底
- **批量下载"合并中"卡顿修复**：ffprobe 校验（数 GB 文件、磁盘被多路 ffmpeg 打满）此前同步跑在主线程，每个合并完成的项都卡主线程数百 ms 到秒级（滚动/面板同帧卡顿）——probe 与 6GB 中间 .ts 的删除挪到后台 utility 队列
- **YouTube 自动播放时好时坏**：根因是全局自动播放默认档"需要用户手势"拦住**新文档**的自动播放——页面内点缩略图带激活所以能播（SPA 换视频同文档），直开链接/外链新标签/会话恢复没有激活就静默被拦（设为"允许"档的正常路径不受影响）。新增**按站点自动播放许可**（Safari/Chrome 同款语义）：`SiteSettings.autoPlay` 三态（跟随全局/允许/阻止），在 Tab 构造咽喉点按初始 URL host 计算**有效策略**——Web 公开 API 的播放策略只能在 webview 创建期烙入（WKWebpagePreferences 无此属性、私有选择器不可探测），外链/中键/target=_blank/Agent 开页/恢复一处挂钩全生效；工具栏更多菜单新增"允许此站点自动播放"，授予时自动把当前标签按原 URL 重开（新 webview 带新策略）即点即生效。已知边界：空白新标签里同标签导航到已授权站点不吃覆写（重新开一个该站链接即可）。
- **0.7.4 安全重构误删五条 webview 消息分支（9babbed），全部恢复**：audioState（tab 声音播放图标与后台挂起豁免——用户报"tab 上的声音指示没了"的根因）、pagePerf（DevTools 性能面板 DOM/长任务指标 + 大页面挂起判定 + 桥 domNodes 字段）、otpDetect（验证码自动提示）、cookieGuardHandled（cookie 横幅处理提示条）、desireProtocolEvent（DPP 事件 hub 的 page world 通道）。消费端一直在、生产端断供三天，按消息链"前置早退"惯例恢复并加防再删注释。
- **tab 声音图标/静音按钮仍然缺失的第二层根因：TabAudioControl 静音劫持的默认分支骗了所有人**——v1 的 getter 写成"`__desireForceMuted === false` 才放行真值"，而普通标签从未调用过 apply（undefined ≠ false），于是所有站点的所有媒体元素 muted 恒读 true、volume 恒读 0：audio-state.js 的 `el.volume > 0` 永远不成立（9babbed 恢复 handler 后指示依旧不亮的原因）、站点（YouTube 播放器音量 UI 等）全被喂假值、且只骗读取不动真实属性实际并未静音。重写为 v2 语义：默认原生 get/set 全透传（检测脚本与站点读到真值），仅强制态说谎，且强制/解除都**动原生 muted 属性**（记原值、解除还原）——静音从"假装"变"真的"；另补 didFinish 按本 webview isMuted 重放强制，静音标签翻页/刷新不再回声。




### Added

- **Agent 面板 slash 命令菜单**：输入 `/` 即弹出命令候选清单（前缀过滤、↑↓ 选择、Enter 补全/执行、Esc 关闭）——14 个命令不再需要背全名；已敲完整命令时 Enter 直接执行
- **排队消息"立即执行"**：排队条每条新增播放按钮——插队取消当前回合并立即以该条开新回合（不再顺序等待）
- **Agent 独立窗口两栏布局**：左栏新增会话列表侧栏（标题搜索+按时间分组的原生 List，点行即切换、右键/Delete 键删除），默认折叠、开关在面板头部最左，显隐跨启动记住；展开时窗口过窄自动放宽到 560 保证聊天列可用；时间分组抽成历史页/侧栏共用的同一份 AgentHistoryGroup；浏览器内嵌的 Agent 侧栏面板保持单栏不变。
- **Agent 独立窗口侧栏升级为智能体控制台**：侧栏新增"智能体"导航区——任务（定时任务管理：开关/目标窗口/立即执行/删除）、技能（技能库：列表/危险模式风险徽标/导入 zip·目录·单 md/重新扫描/正文预览）、记忆、使用统计、轨迹、能力六个目的地，右栏随之切换；头部的历史/能力/轨迹/统计/记忆按钮在独立窗口隐藏（入口上移侧栏，白板/悬浮球/新对话保留），浏览器内嵌面板不受影响；任务/技能页与设置页同源一套 store，不另起数据。
- **Agent 控制台第二批**：侧栏新增"体检"目的地（AgentDoctor 八项自检的报告页：模型/端点/MCP/ffmpeg/钩子/技能/通知/心跳，汇总徽标+重新体检）；任务页支持**新建任务**（名称+提示词+周期两档：每 N 分钟/每天 HH:MM）；技能页支持**新建与编辑技能**（名称/描述/使用说明 → SkillAuthoring 渲染 SKILL.md，编辑写回原文件、目录技能锁名防附属文件失联）+ 技能卡右键"在对话中使用"（切回聊天列并把使用指令发给 Agent）；侧栏会话右键新增重命名。
- **slash 命令二批（14→22）**：/access（看/设访问等级，confirm|auto|full+中文别名）、/directive（看/设/清会话级指令，off 清除）、/tasks（列定时任务）、/tools（按风险档统计工具数，带关键词过滤）、/mcp（列服务器与连接状态）、/title（重命名当前会话）、/retry（重新生成上一条回答，与面板同入口）、/export（存盘对话 Markdown——渲染收口到 AgentConversationExport，面板右键导出与它共用同一份）；顺手把两批 slash 的全部输出与 help 文案补齐三语（58 键，含首批遗留的英文裸串）；纯逻辑单测 551→564。






## [v0.7.8] - 2026-10-10
### Added

- **slash 命令第二批（补全能力入口）**：`/skills`（列出已装技能）、`/memory`（记忆概要：画像/事实数/置顶/最近更新）、`/model <名称>`（列出/切换模型服务，名称模糊匹配）、`/persona <名字>`（列出/绑定人设，off 解绑）、`/plan`（当前计划清单与状态）、`/cancel`（取消运行中回合）、`/windows`（窗口与 Agent 状态）；/help 同步扩充——Agent 面板的能力入口全线可达（输入框一处、无需记设置位置）
- **记忆知识库导出进面板**：记忆面板标题栏新增导出按钮——一键把本机记忆（画像/分组事实/相关互链/摘要）渲染为 Markdown 落到"下载"文件夹并在访达中显示；与桥 `GET /memory/export?format=markdown` 同源（`AgentMemoryStore.markdownKB()` 收口一处）
- **回环地址媒体下载绕过系统代理**：媒体下载 session 按目标主机分流——127.0.0.1/localhost/::1 走显式无代理会话，本机媒体服务器与局域网场景不再被系统代理（xray 等）的路由劫持卡死
- **直连媒体下载断点续传（字节级）**：直连大文件改用 `bytes` 流式 API 边收边追加进 .part（1MB 缓冲块），硬杀/断网后从磁盘字节偏移原地续传（HTTP Range/206；服务器不支持 Range 时回退整段重下）；.part 命名从每次随机 UUID 改为确定性命名（批量条目 = 条目 id），重试不再孤儿化半截文件——修复"重试创建了新文件"的断点续传断裂



## [v0.7.7] - 2026-10-10
### Added

- **技能安全扫描（Skill Scanner）**：技能是指令文本、会驱动 runCommand——导入与使用两个时点对内容做危险形态扫描（管道执行远程脚本、rm -rf 根目录、凭据读取=高危；sudo/全开放权限/系统偏好写入/数据回传=中危），只提示不拦截（拦截交给审批链）；useSkill 载入时向模型附风险提示、saveSkill 自沉淀时回带警告、桥 `GET /skills` 每条附 `risk` 字段
- **Agent 体检（doctor）**：一键自检报告——活动模型档案与端点可达性（3 秒探测，任何 HTTP 响应都算通）、旁路/备用档案有效性、MCP 连接数、ffmpeg、钩子语法、技能风险计数、通知授权、心跳状态；设置页 AI 区置顶"Agent 体检"分区（运行后逐行显示结论），桥 `GET /agent/doctor` 同源
- **按需回忆（recallConversation 工具）**：压缩只裁请求副本、完整历史永在内存——但模型对"已被裁出上下文的轮次"此前没有任何取回手段；现在可按关键词召回当前会话的完整历史轮次（含压缩掉的），命中片段带定位说明。桥/工具索引自动跟进
- **每窗口模型路由（per-agent model routing）**：每个窗口的 Agent 可绑定独立的模型服务档案（面板标题菜单选择；桥 `/agent/roster` action=bind-model）——主回合流走绑定档案（生成参数继承全局），解绑回落；`GET /agent/windows` 带每窗模型名。多窗口从"多分身"进一步变成"各自用各家模型的多个 Agent"
- **Agent 体检（doctor）**：一键自检报告——活动模型档案与端点可达性（3 秒探测）、旁路/备用档案有效性、MCP 连接数、ffmpeg、钩子语法、技能风险计数、通知授权、心跳状态；设置页 AI 区置顶"Agent 体检"分区（运行后逐行显示结论），桥 `GET /agent/doctor` 同源
- **通知点击深链**：系统通知统一路由（此前委托被更新检查独占，其它通知点击无响应）——点击 Agent 通知（心跳/页面监视/导出完成/任务失败）激活应用并确保 Agent 面板打开（已开则只激活不误关），更新通知照旧打开 release 页；前台横幅策略统一为 banner + sound
- **记忆知识库 Markdown 导出（ReMe 式思想）**：本机记忆一键渲染为可读文档——画像、事实按类别分组（置顶星标/范围与来源标注）、相关事实按共享词元自动互链、会话摘要附标题与时间；`GET /memory/export?format=markdown`（JSON 备份照旧）
- **Agent 模式（Loop 工程思想）**：标准/研究/写作三种模式，按窗口绑定（面板标题菜单切换；桥 `GET /agent/modes`、`POST /agent/roster` action=set-mode）——研究模式滤出执行代码/系统命令/下载/定时任务/子代理等变更工具（含 spawnSubagent 防借道绕过），写作模式滤出系统命令与下载；被排除的工具不进模型工具索引，幻觉调用也会在执行前被模式闸挡下（提示切换模式）；模式说明以 `<mode>` 层注入系统提示。模式是"活动范围"，审批链独立于模式不受影响
- **子代理任务级隔离（isolated 容器，Muse Secure VM 思想的本机对应）**：`spawnSubagent` 新增 `isolated=true`——子代理标签页（含并行 fan-out 的每张标签）跑在一次性容器里，Cookie/会话与用户登录态完全隔离；全部任务完成后自动擦除该容器数据并移除；隔离的单任务也走专属标签路径（原语义=当前标签页上下文不变）。脏抓取、平行账号类任务不再污染用户会话
- **crew 隔离**：crewDispatch 新增 `isolated` 参数（工具与桥 `/agent/crew-dispatch` 均可传）——全 crew 标签共享一个一次性容器，落定（含取消路径）即擦除该容器数据并移除；与 spawnSubagent 的 isolated 同一套机制，多 Agent 脏活全线不污染用户登录态








## [v0.7.6] - 2026-10-09
### Fixed

- **旁路/评审轻量实例打穿全局档案库（P0，2026-10-09 实测踩中）**：`bypassPreferences()` 构造轻量实例后 `profiles = [单条]` 的赋值触发 didSet **整组落盘**——只要配置过旁路档案，每次回合收尾的标题生成都会用一条档案覆盖整个 `aiProfiles`；`criticPreferences`/旁路的 `activateProfile` 还会把全局 `aiActiveProfileID` 改写成旁路档案 id。现在三类轻量实例统一挂 `isDetachedView`：profiles 不落盘、active 指针不写全局（内存视图语义不变）。E2E 全程档案数核对通过

### Added

- **AI 动作复查（guard pass）**：自动编辑访问等级下，副作用工具在快捷放行前先经旁路模型对照用户规则（身份提示词 + 常驻规则 + 会话指令）做一次轻量判定——标记为可疑的动作转为审批卡（卡片顶部带复查理由），超时（8s）/失败/无法解析一律放行不卡回合；设置页 Agent Context 区新增开关（默认开）、Agent 菜单新增启停项、桥新增 `GET/POST /agent/guard` 与 `POST /agent/guard/check`（离线跑一次复查，E2E 用）；旁路用量照常记到本回合尾助手消息（kind=guard）
- **主动通知分级（防"通知轰炸"）**：新增 `ProactiveNotificationStore` 收口——urgent（定时任务失败、下载失败）任何时刻直推，routine（页面监视变化/AI 分析、媒体导出完成汇总）过"免打扰时段（支持跨午夜，默认 23:00–08:00 可关）+ 每日预算（默认 12，可关）"闸，扣下的合并成一条摘要、免打扰结束时自动补推；设置页通用区新增"通知"分区（免打扰开关/起止/每日上限）、Tools 菜单新增免打扰启停项；桥新增 `GET/POST /notifications/policy`、`POST /notifications/test|flush`
- **心跳巡检（Heartbeat）**：Desire 第一条"模型自决的主动性"——每 N 分钟（15/30/60/120/240 可选，默认关）一次轻量旁路调用，把用户巡检清单 + 机器自动信号（页面监视变化含 AI 分析结论、失败的定时任务）交给模型判断要不要打扰：回 `HEARTBEAT_OK`（首尾出现且余文 ≤300 字符）即静默，有事则以例行通知说出（过免打扰/每日预算闸）并向会话追加备注防重复提醒；防噪音三闸：回合进行中推迟、免打扰时段跳过、清单与信号全空跳过；设置页 AI 区新增心跳分区（开关/间隔/上次巡检状态/清单编辑器），桥新增 `GET/POST /agent/heartbeat` 与 `POST /agent/heartbeat/fire`
- **备用档案 failover**：主服务瞬态错误（限流/5xx/断连）的既有"重试一次"仍失败时，自动换用户配置的备用服务把流再试最后一次（仅限"什么都没流出来"，不会复制半截输出）；设置页 Agent Context 区新增"备用服务"选择行，桥新增 `GET/POST /ai/fallback-profile`
- **子代理瞬态重试**：crew/子代理的模型流此前没有任何重试（一次抖动整次任务报废）——现在与主循环同款语义：一个事件都没收到且属瞬态错误时延迟 1.5s 重试一次
- **生命周期钩子（hooks v1）**：`Application Support/Desire/hooks/` 下每个 .js 文件跑在独立 JavaScriptCore 上下文（无宿主对象注入，仅事件载荷 + console.log 落统一日志），支持 `beforeToolCall(event)` 可编程否决——返回 `{decision:"deny",reason:"…"}` 即拦下该工具，且这是**唯一在完全访问档仍生效的闸**（用户亲手写的显式规则 > 笼统等级授权；deny 规则原语义不动），理由透传进工具消息让模型知道为何被拒；`turnFinish(event)` 通知型钩子（回合收尾，返回值忽略）。设置页 AI 区新增"钩子"分区（全局开关/目录/重载/逐文件启停），桥新增 `GET/POST /agent/hooks` 与 `/agent/hooks/reload`
- **心跳"发现即处理"**：心跳巡检标记某事后可自动派一个真实 agent 回合核实并处理（走 deliverScheduled 忙时排队），提示词里明确"不做危险/不可逆操作"——从"只提醒"补到"能动手"的闭环；设置行 + 桥 `autoHandle` 字段
- **巨型消息请求侧封顶**（上下文卫生）：块压缩"永不丢最后一块"留下的防线缺口——一条巨型用户粘贴/超长回答原本会无防线原样进请求；现在 user/assistant 消息超 4 万字符在请求副本里保留头 2 万 + 尾 5 千、中段显式标注截断（工具消息仍走既有 8k 摘要管线）
- **技能自沉淀闭环（saveSkill 工具）**：模型把刚跑通的多步工作流存成 SKILL.md（name/description/instructions，同名覆盖、正文自带 frontmatter 会被剥掉重生成），落盘即 reload——未来对话经 `<skills>` 索引 + useSkill 复用；学习闭环从"被动纠错（点踩沉淀）"扩到"主动沉淀（成功工作流入库）"
- **心跳"未完成事务收件箱"信号**：心跳自动信号新增两类——当前会话有被打断的回合（面板已有"继续/放弃"入口）、最近 48h 内最后一条消息是用户且没有回复的会话（上限 4 条防吵）；`POST /agent/heartbeat/fire` 响应带 `signals` 清单（E2E/调试可观测）
- **多窗口 Agent 联动第一批（清掉账面"未实现"的最痛部分）**：定时任务可点名目标窗口（`ScheduledTask.targetSessionID` = 调度器注册 id；桥 `POST /agent/tasks/create` 新增 `window` 参数，设置页任务行显示目标窗口、窗口关闭自动回落最新会话）——修掉"新开一个窗口的面板就把所有定时投递抢走"的行为；双窗口防互踩：面板打开时不再装载已被其他活会话占用的对话（此前两个窗口都装全局最新一条、各自整文件写回互相覆盖）；`POST /agent/directive` 支持 `window`；`GET /agent/windows` 增加 conversationTitle；清理不可达的重复 `/agent/resume` 死分支（重跑末尾提问的面板入口不受影响）
- **多 Agent 人设名册（roster）**：命名人设（名字 + 语气）集中管理，每个窗口的 Agent 面板从标题菜单绑定其一——绑定的窗口在 `<persona>` 层用人设自称与语气说话，未绑定/人设被删回落全局默认；系统提示词身份层保持全局（人设只换"它是谁"，不换"它知道什么"）。设置页 AI 区新增"Agent 人设名册"分区（增删改），Agent 面板标题变成人设切换菜单，桥新增 `GET/POST /agent/roster`（add/remove/bind）——多窗口从"一个 Agent 的多个分身"升级为"多个 Agent"







## [v0.7.5] - 2026-10-09
### Fixed

- **悬浮球设置页容器统一**：自拟 ScrollView+padding 改为 SettingsContainer（720pt 限宽居中 + 统一边距/顶对齐）——此前间距风格与全设置页脱节；顺带修正设置窗通用问题：短内容子页垂直居中改顶对齐、切换子页滚动位置残留（detail 加 .id 强制重建）

### Added

- **白板视觉自检闭环（agent 画→看→改）**：whiteboard 工具新增 `action=screenshot`——当前板经 BoardRenderService 离屏渲染成 PNG 以 vision 输入回传给模型（复用截图多模态通道），渲染报错的块会显式失败并提示先修；工具描述与参数说明同步（flow/mindmap/chart 编辑后建议自检布局拥挤/节点重叠/文字截断，用 edit 修正后再交付）。配合 v8 的 flow/mindmap 块，agent 具备"画→看→改"的完整自检能力
- **白板分享卡导出**：`BoardRenderService.shareCardImage`——板渲染 + 标题头（板名大字 + "Desire 白板 · 日期"副行）合成可分享长图；面板「导出 PNG」改走此路径（不再依赖面板窗口开着）；桥 `GET /whiteboard?format=png` 返回 base64 分享卡（自动化/远程导出）；React 壳空标题不渲染行（分享卡头部已有板名，避免双标题）。实测：flow+mindmap 双块板导出目视通过
- **PageWatch 智能监视（页面监视 × Agent）**：页面变化监视器从"机械 diff + 裸通知"升级为可选的 **AI 自动分析**——watch 开 `aiAnalysis` 后，变化触发静默 agent 回合（deliverScheduled 自动排队不打断用户回合）：提取变化片段（公共前后缀剥除 + 上下文，`PageWatchDiff.extractChangedRegion` 纯函数进 tests/run.sh）→ 喂模型分析（"变化内容 + 是否值得关注"结论）→ 写回 `lastAnalysis` 并补发带分析的系统通知；回合失败/被删路径均有兜底。桥 /watches 全套带 aiAnalysis/lastAnalysis。E2E：本地 fixture 价格页变化 → 分析回合真实触发 → 模型端点不可达时错误正确写回（机制全通；分析质量依赖模型 API 可达）
- **PageWatch 管理 UI（设置 → 页面监视）**：此前纯桥驱动无任何界面——新 section 提供列表（名称/URL/间隔/AI 徽章/开关/立即检查/删除/最近分析文本可展开）与添加表单（名称/URL/可选 CSS 选择器/间隔档位/AI 分析开关）。顺带两处设置窗通用修复：① 短内容子页不再垂直居中（SettingsContainer 纵向 center → 顶对齐，设置页惯例内容从顶开始）；② 切换子页后滚动位置重置（各子页 ScrollView 结构相同同身份会保留滚动——detail 加 .id(selected) 强制重建）
- **DevTools 二轮 · Console 错误捕获增强 + AI 解释**：① 拦截器新增 **unhandledrejection**（未捕获的 Promise 拒绝——现代页面错误的主要去向，此前完全不可见），拒因是 Error 时从 reason.stack 提取抛点源信息；② window error 事件改用事件自带的 filename/lineno/colno（此前 stack 解析且资源加载错误混入）。**Console 面板错误/警告行右键新增「Explain with AI」**——错误文本 + 源（url:line:col）+ 所在页面组 prompt 送 agent 分析（常见原因/影响/修复建议，用户可见回合进会话）。E2E：fixture 三类错误（console.error/未捕获异常/rejected promise）全部入记录且带源






## [v0.7.4] - 2026-10-09
### Changed

- **悬浮球动效精修（v7 打磨）**：① 触盘格子弹入方向改为**从球的一侧进入**（盘在球上方自下而上浮入、在下方自上而下——此前固定向上，盘在球下方时方向反了）；② 按压/释放走弹簧回弹（0.26/0.62），不再瞬时突变；③ 展开时球微缩退后 6%（视觉焦点让给触盘，球变成"关闭按钮"）；④ 展开/收起分速——展开弹性绽放（0.42/0.75）、收起干脆利落（0.3/0.88）；⑤ 开盘掠光减淡减速（0.30/0.9s）细光不抢戏；⑥ 格子悬停 1pt 微浮起 + 弹性过渡（选中感有位移分量）
- **白板图表美化 + 思维导图（走查"流程图好原始"）**：Mermaid 从 neutral 主题切 **base + 米纸主题变量**（墨字/朱金边/灰褐线，与白板底色一体）+ **连线平滑曲线**（flowchart curve basis）+ 节点投影/居中/呼吸边距——三条硬坑：themeVariables.fontSize 必须是**数字**（mermaid 主题计算拿它做乘法，字符串 "14px" 让整条主题链 NaN 静默回退灰主题，实测配色全灭的真因）；mindmap 节点默认深蓝下划线与主题不搭，themeCSS 精确覆盖（.mindmap-node 全子元素 stroke）；Swift 多行字符串里的 \s\S\f 均需双写转义。**思维导图可用**（vendored Mermaid 11.4.1 原生 mindmap，缩进层级语法已写进工具描述）；note 块新增 ``` 围栏代码块渲染（pre 圆角码块 + 行内 code 徽章）。实测快照：流程图/导图/代码块三形态目视通过
- **白板前端 React 化（v8，"图 UI 太原始"的根治）**：渲染壳从手搓 HTML 字符串重写为 React + esbuild（webapp/ 源码进仓库，产物 Resources 根平铺，零 CDN 离线）。**新增块类型**：`flow`（节点图 JSON → dagre 自动布局 + 自绘静态 SVG：pastel 节点/曲线连线/箭头/边标签）与 `mindmap`（缩进文本 → 横向树 SVG：root 圆 + 分支彩色粗曲线，XMind 观感）；旧 `mermaid` 块保留兜底渲染。**方案教训（调研先行）**：图丑的根因是 Mermaid 渲染美学天花板，换 React 壳不解决——先试过 React Flow/markmap 库，它们的**容器运行时测量在离屏 webview 全不可靠**（ResizeObserver 不触发→节点永远 hidden；clientWidth 0→导图缩成一角；isHidden/窗口外偏移→3D transform 合成层 takeSnapshot 不渲染），最终落地 = dagre 布局 + 自绘静态 SVG（与 mermaid 同类的纯 SVG 可靠性）+ React 只做卡片壳，bundle 1.1MB→241KB；echarts 走宿主 script + 现代默认色板注入



### Fixed

- **触盘全览"退不回主盘"**：hubShowsAll 一旦展开就跨展开周期持久——收起再展开永远是全部视图，且全览态没有任何退回入口（只能长按球盲切）。双修：① isExpanded didSet 收起时自动复位 hubShowsAll（"全部"回归临时全览语义，每次展开从主盘开始）；② 全览态补「⌃ 回到主盘」chip。顺带 **设置页触盘功能区重做**：四个下拉换槽 Picker 升级为**全能力排序编辑器**——slots 语义升级为顺序表（14 项，前 4 = 主盘 2×2，全览网格顺序跟随个人排序），主盘缩略预览 + 逐行 ↑↓ 排序 + 主盘徽标 + 恢复默认；旧档（4 值）自动补齐全表兼容；桥 /agentball 回读 slots
- **触盘"只剩 4 个功能"**：无持久化档（全新安装/档被清）时 slots 初始值误用 defaultSlots（主盘 4 项）而非全能力顺序表 defaultOrder（14 项）——全览网格渲染的就是这张 4 项表，其余 10 项"消失"。初始值改 defaultOrder（commit 8b20318 引入顺序表模型时的回归）


### Added

- **悬浮球独立设置子页（v6 个性化）**：设置新增「悬浮球」子页（原 AI 页里的区块迁出扩容），四组——**球体**（显示开关/尺寸三档/不透明度 Slider/待机样式「触环 ↔ Agent 图标」/重置位置）· **触盘功能**（2×2 槽位八选四互换/自定义提示词/重置槽位）· **触盘样式**（触盘尺寸「紧凑/标准/宽松」整体缩放/展开动画总开关——关闭后绽放、按钮 stagger、开盘掠光全部跳过直接落位）· **交互**（双击直达语音开关）；全部即时生效（UserDefaults/AppStorage 直达）
- **挂起标签恢复垫图（切 tab 卡顿走查 · 感知优化）**：实测切回被挂起的标签 = 主线程阻塞 250-350ms（interactionState 回灌后 WebKit 重建页面树，宿主侧 restore 仅 84ms、其中解档 <1ms——大头在 WebKit，不可避免）；期间 webview 白屏跳变。现挂起时（后台 sweep 路径）异步抓一张视觉快照，恢复时垫在 webview 上层 450ms 淡出——"白屏跳变"变"快照过渡"（Safari 同款手法）。live↔live 切换实测全链 <7ms 无需优化；切换路径埋点保留（debug 级，tabswitch 类别）
- **悬浮球触盘 v7 特色快捷操作（能力目录 8→14）**：新增 **AI 去广告**（与 didFinish 自动清理/agent blockElements 同引擎：ad-candidates 扫描 + ≥2 理由高置信度拦截，toast 回报拦截数）、**下载页面视频**（嗅探的主视频 → MediaExportStore 后台下载）、**下载全部视频**（页面媒体全量入队批量引擎，host 子夹防混装，与 downloadAllPageVideos 同引擎）+ 高频快捷 **阅读模式 / 页内查找 / 收藏本页**；全能力网格 4 列动态行，⌄ 文案随项数；动作结果走球旁胶囊反馈（修复 toast 清除定时器竞态——前一条的定时把新 toast 提前清掉）；设置页「触盘槽位」十一选四自动跟随 allCases；桥 /agentball 新增 perform 驱动 + actionToast 回读（E2E 入口）。实测：去广告对 DPP 演示页拦截 1-3 处、单视频起下载、批量入队 2 项




## [v0.7.3] - 2026-10-08
### Added

- **单视频下载质量回执（"确定下载的就是高质量"闭环）**：ffmpeg 选档从"不限速时靠 ffmpeg 默认挑"改为**永远显式钉最高码率 variant**（master 文件顺序不保证高档在前）；ffprobe 校验升级为 JSON 解析（csv 列序是 ffprobe 内部属性序，按位解析必错位——实测 codec_name 先于 codec_type），回执带**时长/分辨率/视频+音频编码**（音轨缺失显式标 NO audio，历史丢音轨事故的信号）+ **源变体清单**（"source: N variants, max WxH"）；下载档明显低于源上限（面积差 >1/3）且未设码率上限时回执打 ⚠️；桥 /media/download 改走 MediaExportStore（与 agent 工具同路径）——此前裸调下载器，任务不进任何列表、回执只进日志。E2E：本地三档 master（低档在前）→ 不限速下到 1280x720 h264+aac、限速 350k 精确落 640x360，两条回执均带源清单
- **YouTube 反反广告拦截检测（用户实测"被 YouTube 识别到"）**：播放器响应剥离（`adPlacements`/`adSlots` 等广告节点在解析层摘除，响应里根本不存在）+ 强制执行弹窗杀手（"检测到广告拦截器"对话框持续移除）+ 连续诱饵清扫；实测 71 秒播放零检测


### Fixed

- **工具栏下载按钮与标签栏 + 号跨行对齐**：DownloadButton 曾用 28×28 frame（其余尾部按钮统一 24×24），半宽多 2pt 把下载圆心挤出 + 号正上方 2.25pt；统一回 24×24 + 图标 13pt，像素实测 + ↔ 下载偏差 0.25pt
- **关闭标签页后视频/页面仍继续解码**：WebView 内容在标签关闭后未被拆除（YouTube 关标签后声音继续放，用户报告）——关闭路径补 WebContent 停载与拆除



## [v0.7.2] - 2026-10-08
### Added

- **桥端点补全（测试卫生）**：`POST /history/remove`（按 id 精确删历史条目）+ `GET /history` 条目补 id 字段；/devtools/application/delete 的 cookie key 形状（name@domain）写入端点文档

### Fixed

- **桥 GET /bookmarks 读错作用域永远返回空**：端点按 0.3.5 惯例新建"活跃档案作用域"实例读取——现代多档案架构下活跃档案桶为空，桥返回书签永远 `entries: []`（add/remove 却走 live store，同族端点读写不同源）。改读 `AppState.live.bookmarkStore`（与 UI 同源），验证返回 6 条真实书签
- **窗口挂载竞态**：WindowChromeGuard 的一次性 `DispatchQueue.main.async` 探测在视图未进窗口层级时静默放弃——慢盘/窗口服务器繁忙（CI runner）时 `appState.attach` 永不发生，标签页管理器挂不上。改为 AttachProbe 生命周期驱动（viewDidMoveToWindow 可靠触发）
- **白板表格分隔线渲染成数据行**：Swift 导出（markdownTableHTML）与 JS 渲染（renderTable）双实现均缺分隔线行跳过——`| --- |` 行被当数据画进表格。双修 + 4 项 harness 单测（含带对齐冒号的 GitHub 形态）
- **PDF 内建查看器被错误页遮蔽**：PDF 拦截的 decisionHandler(.cancel) 让 WebKit 以 code 102"帧框加载已中断"（WebKitErrorFrameLoadInterruptedByPolicyChange）收尾导航；didFailProvisionalNavigation 的取消分支只认 NSURLErrorCancelled(-999)，102 漏网 → lastError 被设 → 错误页盖住已下载完成的 PDF 查看器（HTTPS PDF 正常、HTTP PDF 必现）。修复 = 102 与 -999 同判"非页面错误"；presentPDFViewer 补 fetch 埋点（Log.pdf 类目新增）



## [v0.7.1] - 2026-10-07
### Added

- **社区分享轻量（0.7.1，0.7.E）**：.board 文件 schema 版本化（`desire-board/1` 随导出写入；旧文件缺键按 /1 兼容读；过新版本导入时明确提示升级而非静默丢字段）；导入信任摘要常显（标题/块数/按类型明细 + ".board 是纯数据不含脚本宏"声明）；导入面板接受 .board UTType（此前只放行 .json，.board 扩展名文件会被灰选不了）；产品页新增**白板模板 Gallery**（/gallery/：五个内置模板的 .board 静态分发，tools/gen-board-gallery.swift 从 WhiteboardTemplates 单一真相生成，产品页白板特性行已挂入口）

### Fixed

- **悬浮球贴角被窗口圆角裁成"扁球"**：球的停留间距（侧向 6pt / 纵向 10pt）让它深陷窗口圆角半径区，圆角遮罩直接裁掉左下一块（用户走查实测"看着有点扁"）。停留/拖拽/吸附的间距数学统一让出到 16/26pt，球整体离开圆角区；附带修掉一处增量构建未编入源码改动的验证假阴性（touch 强制后像素实测确认）


## [v0.7.0] - 2026-10-07
### Security

- **0.7.4 安全第一轮（审计→修复，详见 docs/SECURITY-AUDIT-0.7.4.md）**：① 桥（127.0.0.1:8799）新增 Host/Origin 双闸——此前浏览器里打开的恶意页面可用 no-cors POST 直接驱动 `/agent/send`/`/execute`（不预检、副作用照发），DNS rebinding 还能读到响应；现在非本机 Host、非本机 Origin（含 `null`）一律 403 + fault 日志，curl/CI/MCP 等本机客户端不受影响（六例实测 200/403/403/403/200/200）；② 窗口标题（页面可控的 `<title>`）进系统提示 `<environment>` 段前消毒（换行压平/尖括号剥除/封长）——此前可伪造段边界注入伪指令；③ 下载文件名穿越收口——Content-Disposition 的 `../../.zshenv` 在 `.replace` 策略下能写出 Downloads，现统一过 `FilePathing.sanitizeFileName`（取末段/禁隐敓名/空名兜底，截图落盘共用顺带设防）
- **0.7.4 安全第二轮（挂起项清账，审计文档同步更新）**：① 插件 RPC 身份绑定——新增 ExtRPCBox（每个插件 world 一个 handler，注册时捕获插件 id 与 world），per-plugin world 的存储桶归属以注册侧绑定为准、不再信消息体里的 `ext`（插件无法冒名其他插件的存储桶）；extensionWorld（宿主 webext/eval 共享世界）保留 legacy 回退；② [DPP] 工具消息里的页面可控名字（views/actions/字段名）进消息前消毒（换行/尖括号/封长）；③ 系统提示 `<tools>` 段在首个 MCP 工具前插声明行——服务器提供的工具描述是第三方数据，防描述内夹带伪指令


### Fixed

- **悬浮球触盘格子不可见（展开只有空玻璃盘）**：v4 定制槽位把 `capability.hashValue` 当格子编号传进了弹入动画的 stagger 延迟——hashValue 每次启动随机且量级 ±2^63，乘 0.055 后是天文数字秒，正数槽位的动画永不开始、格子永停在 opacity 0（四格全可见概率仅 1/16，此前测试是撞上负值的运气）。改回位置序号 0…3。附带：桥新增 `POST /agentball`（开合/显隐驱动——darwin 27 上 CGEvent 已死、球是手势判定非 AXButton，这是悬浮球唯一的自动化入口）；修复 DevTools DPP 检查器缺失 `import WebKit` 的编译错误
- **DevTools 后台标签页记录断流（0.7.5）**：console/network 的接收端此前挂在 SwiftUI 视图生命周期上（makeNSView 挂 / dismantle 摘），标签页一转后台记录即断，"全部标签页"只剩被前台化过的名单。新 `DevToolsRecorder`（app 级单例）在 Tab 创建时挂上、挂起重建随新 webview 重装，后台标签页持续记录。**附带修掉一颗跨源切片时代的地雷**：`dppFrame` handler add 前没有 remove——切回含 DPP 声明的标签必抛 NSInvalidArgumentException 直接崩（NSViewLayout 内 `_crashOnException`）；补 remove-before-add + user script 关联对象台账防重复注入
- **跨源 DPP 的 about:blank 竞态**：iframe 导航落定前的瞬时文档上报声明时，宿主按 frameInfo 求值常已落在**导航后**的文档上——目标框架的声明被注册两遍（about:blank 与真 URL 各一条，实测 `demo/embed/?widget=` 双源场景）；宿主侧跳过 about:blank 上报（真导航后脚本以真实 URL 重报），注册幂等。**悬浮球 v5 手感打磨**：触盘翻转判定补计 ⌄ chip 行高（贴上下边时位置更准）、全 8 能力小格标签缩字容忍（"自定义提示词"不再硬截）



### Added

- **记忆检索升级：端上句向量主排（0.7.1 阶段二）**——内置 bge-small-zh-v1.5（int8 量化 22MB，Core ML 系统框架推理，`Models/BGEZh.mlpackage` 构建期编译）+ 自带 WordPiece 分词，`MemoryRetrieval.rankWithVectors` 按"向量主排、BM25 降级"融合：模型缺失/嵌入失败自动回退纯 BM25，记忆功能不因模型问题挂掉。30 条事实 × 15 查询验收集上 top-1 13/15（纯 BM25 8/15），零词法重叠改写查询从 0/6 到 4/6；离线与应用内（桥 `/memory/retrieval-eval`）结果一致，评估套件 41/41。事实向量按内容哈希缓存于内存（200 条 ≈ 800KB 上限），推理后台执行（单条 ~4-21ms）。转换/评测脚本入库 tools/vector-spike/，数据与分析见 docs/VECTOR-MEMORY-SPIKE.md
- **DPP 0.7.2 收尾三件**：① 演示场新增三场景——`demo/feed/`（infinite 滚动 + shadow DOM 卡片，前导 `>>>` 字段声明）、`demo/embed/` + `demo/widget/`（宿主聚合内嵌小组件声明，`?widget=` 指向第二 origin 即真跨源，同源回退默认可玩）、well-known 页面地图补全 feed/embed/widget 条目与 loginUrl 指引；② 跨源标注——动作声明自跨源子框架时审批卡亮出来源框架 host（"声明来自嵌入框架 X（跨源）"），DevTools DPP 检查器新增 Declaration frames 段（逐框架列出来源 URL、跨源标红）并给 views/actions 条目加 frame 标签；③ 文档站扩充——`website/dpp/spec.html`（规范全文渲染页，由 docs/DPP-PROTOCOL.md 经 tools/gen-dpp-spec-page.py 生成）、`website/dpp/sdk.html`（expose/emit/validate API 参考 + 宿主行为 + 上线检查单），DPP 首页导航与兼容性说明同步（跨源 iframe 已交付、十二场景入口）
- **悬浮球 v5（方向 A「绽放」拍板落地，design/agent-ball/prototype-v2.html 评审定稿）**：展开动画 = 盘从球的位置弹性放大（锚点朝球侧）+ 格子外弹过冲（scale .4 + 上浮，stagger 50ms）+ 开盘一次性掠光；**功能四项**——① 全 8 能力触盘（长按球 0.4s 或盘上 ⌄ 切换 2×2 ⇄ 4×2，八选四限制取消，设置页只管前四槽排序）② 触盘页面上下文菜单头（favicon + 页面标题 + 「问本页」直达回合）③ 回复就绪预览气泡（徽章在窗时悬停球预览回答前两行，免开面板）④ 拖拽投递动作选择（松手弹"总结/翻译/打开并问"迷你菜单，投递语义从固定动作升级为带意图）；**微交互精修**——按下压感 scale .9、忙碌环改缺口弧旋转、录音改球内五柱波形。附带修复：`poll()` 里 `if agentBusy, !busy` 是死代码（上一行刚赋值，条件永假）——回复就绪徽章从未亮过，改 busy 下降沿判定并同帧抓取回复预览。桥 `POST /agentball` 增 `showsAll`/`pendingDrop`/`cancelDrop` 驱动位（球唯一自动化入口的补全）
- **DevTools Network 页签 HAR 1.2 导出**：面板导出按钮（所见即所得——当前作用域+过滤条件下的请求，含请求/响应头、body、资源计时分段、失败原因、WS/SSE 帧按 Chrome `_webSocketMessages` 约定）+ 桥端点 `GET /devtools/har?scope=all|current|tab=<uuid>`；构建器 `HARExport` 面板与桥共用同一套。附带修桥 query 解析：值里带 `=` 的键值对（scope=tab=<uuid>）此前被 maxSplits 2 整对丢弃





## [v0.6.10] - 2026-10-07
### Added

- **App Intents（0.6.10 生态）**：四个系统意图进 Shortcuts.app/Siri——① Open Link in Desire（URL 参数，活动标签加载）；② Ask Desire Agent（提示词入、**最终回答出**——发送后按"新 assistant 消息 + 不再处理中"轮询收敛，5 分钟上限，与评估脚本同一判据）；③ Capture Page to Whiteboard（当前页 WKWebView 快照 → JPEG data URI → 白板 image 块，落到活动会话的板）；④ Schedule Desire Task（名称+提示词+everyMinutes/dailyAt 双参，运行期裁决，与 scheduleTask 工具同一条 add 链路）。AppShortcutsProvider 注册四个 Siri 短语；四个类名均已进构建产物 Metadata.appintents（系统动作库可见）。Shortcuts.app 编排"早报"自动化（打开站点→问 Agent→进白板）的走查待用户。

- **DPP 跨源子框架声明聚合（0.7 切片一，spike 立项后首个交付）**：WebView 注入全框架采集器（forMainFrameOnly:false，.page 世界）——每个框架（含跨源）上报自身 URL，宿主对未见过的框架经 `callAsyncJavaScript(in: frameInfo)` 跑同一归一化解析，子框架视图/动作/事件**补齐进 effectiveProtocol**（同名键主框架优先，帧来源条目盖 `sourceFrame` 戳供切片二 per-frame 提取/动作路由）。导航即清空、采集幂等（已见框架丢弃）。E2E：双源 fixture（8877 主页内嵌 8878 跨源框架）——子框架 `frameProducts` 视图聚合可见（日志 views=1）。框架级提取与动作路由留切片二。

- **DPP 跨源子框架提取与动作路由（0.7 切片二）**：声明来自跨源子框架的视图与动作，`pageExtract` 的抽取/翻页/空态等待与 `pageAction` 的前置检查/步骤 JS 全部**送进所属框架执行**（`callAsyncJavaScript(in: frameInfo)`——`__desireQueryAll` 在 agentToolWorld 对全部框架常驻，天然可用）；框架已导航走 → 明确失败让模型 `pageProtocol` 刷新。切片一的 `sourceFrame` 戳即路由依据。E12 全链验收：双源 fixture 抽取跨源框架视图，**哨兵只在子框架 DOM 里**、抽取结果含哨兵 = per-frame 执行的唯一证明（顺带修正 E12 fixture 字段作用域——fields 相对 item 元素解析，spec §4.3）。


## [v0.6.9] - 2026-10-07
### Changed

- **截图标注盘点说明（0.6.9 规划校准）**：路线图列的「截图标注编辑器」实际早已随 v0.6.x 前的截图功能交付（捕获浮层内七种工具：箭头/矩形/椭圆/画笔/马赛克/文字/序号 + 调色板 + 撤销重做，标注烘焙进保存的 PNG）——本版只补 OCR，标注不再重复建设。


### Fixed

### Added

### Added

- **截图 OCR（0.6.9）**：截图浮层工具栏新增「识别文字」——选区走 Vision 端上识别（zh-Hans + en-US 精确档，**显式 API 调用**，与已关闭的 Live Text 自动浮层无关；数据不出机），结果浮层可选中复制或一键进白板 note（落到当前 Agent 会话的板）。识别对象是**纯截图**（不含已画标注——用户自己打的字本来就是文本）。已用渲染已知中英文本的位图验收（两段全中）。

- **DPP 一键上板（0.6.9）**：`whiteboard` 工具新增 `from: "extract"`——把**上一条 pageExtract 结果**直接转成板（视图名说明 note + Markdown 表格，列 = 条目键并集排序、单元格截 80 字符防炸帧、40 行封顶），模型不必把抽取数据再抄一遍；title 缺省用视图名。spec §5.1 语义不变（仍是宿主写板，页面无权写板）。转换器纯函数进单测 harness；评估 E11 全链（demo 商店页 pageExtract → from:"extract" → note+table 出板）。

- **白板模板库（0.6.9）**：面板「+」菜单新增「从模板创建」——内置五套预置块组合（竞品对比/周报/流程复盘/会议纪要/SWOT），一键追加成板。模板即普通块数组；**分享复用既有 .board 导入/导出**（导出整板即可分享，不另设格式）。

- **悬浮球 v4：可定制触盘 + 拖拽投递**：① 触盘 2×2 槽位**八选四**（Agent 对话/语音/总结本页/白板/截图/翻译本页/任务计划/自定义提示词），设置 → 悬浮球四个选择器换槽（同能力换槽 = 两槽互换，永不丢能力），槽位与「自定义提示词」文本持久化（坏档回退 V3 定稿布局）；② **拖拽投递**——拖链接（URL）或网页选区（文本）到球上，球放大 + 强调环提示，松手打开 Agent 面板并以带上下文的提示起回合（链接 → "打开并阅读总结"；选区 → 原文随提示投喂，2000 字符封顶）。新钩子 `onSendPrompt`/`onScreenshot` 由 ContentView 注入；槽位解码器纯函数进单测 harness（410 项）。触盘/拖拽交互走查待用户实测。

- **白板演示模式（0.6.9 P1）**：面板工具条新增「演示」——逐块步进放映（复用同一双引擎渲染管线出单块 spec），底部 ←/→ 步进条 + Esc 退出；放映态不响应编辑，块仍保留原位。



## [v0.6.8] - 2026-10-06
### Added

- **白板同步域（第九类，opt-in 默认关，0.6.8）**：每会话一文档的 KV 域——client_id = HMAC(会话 UUID)、payload = 整板密文（服务端白名单 + 通用表）。三条新语义：① **image 块 data URI 不随同步传输**——collect 剥成占位符（截图数百 KB，服务端 payload ≤256KB），apply 按块 UUID 从本地板回填原图；② 板级更新时间随文档走（`replaceForSync` 不盖本地戳，LWW 裁决依据不漂移）；③ **拉取侧跨设备删除首次落地**——远端墓碑 payload 为 NULL，靠正向 HMAC 匹配本地会话 id 落地（decryptItems 跳过墓碑是八类平铺域的既有缺口，白板域是第一个做对的，其余域缺口记 ROADMAP）。显式清空落墓碑、容量淘汰不落（与历史域同口径）；单测 +12（进 harness），服务端 E2E `tools/wb-sync-e2e.sh` 4/4（白名单/push/墓碑/pull）。

- **Remote 完成通知**：Mac 在链路循环里检测回合 busy→idle 沿，往 controller lane 发 `turnDone` 帧（会话标题 + 回答摘要）；iOS 收到后发**本地**通知——iOS 对前台 app 默认不展示本地通知，"页面在前台就不打扰"即系统行为；本地通知仅进程存活时可达（app 被杀收不到是平台事实，不承诺推送）。通知权限在配对成功时懒请求。

- **Remote 长会话分页**：快照只发最近 100 条且每秒整体替换——更早的消息走独立帧：iOS「加载更早」→ `fetchEarlier`（携带当前最旧消息 id）→ Mac 从落盘会话取前 20 条（×800 字符，安全落在信箱 32KB 内）回 `earlierMessages`；iOS 存**侧缓冲**（按 id 去重、不参与快照替换、随会话切换清空）。Mac 消息映射抽成快照/分页共用 helper。

- **同步日志（设置 → Sync 诊断区块，0.6.8 P1）**：逐域累计 推送/拉取/冲突 条数，LWW 输掉给条目级记号（最近时间 + clientId 尾段）；待删墓碑数长期不为 0 = 该域同步持续失败的可见信号。随 UserDefaults 持久化。

### Changed

- **历史墓碑上限（0.6.8 P1）**：pendingDeletions 超 5000 淘汰最旧——同步裁决本会及时清空，上限只防"反复清空历史→同步失败"异常链路的无限累积；被淘汰的删除由服务端 90 天 TTL 收敛。

### Fixed

- **平铺同步域的跨设备删除补齐（0.6.8 P1，白板域交付时发现的真实缺口）**：远端墓碑 payload 为 NULL，`decryptItems` 直接跳过、本地也无匹配机制——设备 A 删的书签/快拨/阅读列表/历史条目在设备 B **从未被删过**。现在四个域的 apply 在合并后按正向 HMAC 匹配本端元素 id 落地墓碑：墓碑时间 ≥ 本地戳 → 删（同刻收敛）；本地戳更新 → 保留（下轮 push 复活）。书签树命中节点连**整棵子树**移除（父删时子不再"孤儿归位"复活成根）。

## [v0.6.7] - 2026-10-06
### Changed

- **统一日志新增重试路径诊断钩子**：上下文超限的"压缩减半重试"与终态 fail 两条路各留一行日志——E4 评估曾出现"错误匹配却未重试"的偶发（4 连挂后自愈、无法复现），此后统一日志可直接回答"重试路径走没走"。

### Fixed

- **白板连续调用不再乱序（0.6.7 评估扩面揪出的真 bug）**：whiteboard 归类为 `.readonly`（免审批直达），但 get/render/edit/delete 操作**同一块板**、有严格顺序语义——此前它会被并进只读工具**并行批**（withTaskGroup 并发执行），模型一条消息里「render 完接着 edit」会乱序竞态。现在顺序敏感的只读工具（orderSensitiveReadonly）不进批、保持串行，其余只读工具的并行加速不受影响。

### Added

- **评估集 E6（network-rules）转本地专属**：CI 上三次确定性超时（本地稳定全绿），归为环境性差异——默认 CI 跳过并标注，`EVAL_E6=1` 本地显式运行；诊断钩子（fixture 决策日志）保留。
- **DPP 逐动作放行（0.6.7 首项）**：pageAction 审批卡新增「Always on this site」——把「审批锚点 host × 动作名」持久化到 DPPActionApprovals（DiskStore），gate 侧同 host 同动作后续调用零审批（deny 策略仍前置；含 mcp 步骤的动作不参与本表——宿主侧能力不静默执行）。设置 → 隐私的 Cookie 三档与桥 `/dpp/action-approvals`（allow/list/revoke）管理面同步落地。与访问等级正交：outbound/danger 升级挡的是静默放行，用户的点名授权是显式选择。
- **DevTools「DPP」检查器页签（0.6.7）**：当前页协议声明的只读检查器——Profile/Page type/Content main/Sections/Ignore、Views 逐字段（DisclosureGroup 展开、类型标注）、Actions（effects: outbound 橙标 / danger 红标 / run 步骤预览）、Events（watch 选择器）、解析 Warnings；**已派发事件流**（PageEventHub 新增环形历史，cap 30）实时滚动。无声明页显示引导说明。
- **白板单文件 HTML 分享（0.6.7）**：白板面板新增「导出单文件 HTML」——零外部依赖的静态 viewer（note/table 排版渲染、mermaid/chart 呈现源码、image 内联 data URI），无 Desire 机器双击即可在任意浏览器打开；`WhiteboardHTMLExport` 纯函数生成（进单测 harness）。
- **三步首启引导（OnboardingFlowView）取代旧单屏**：① 选模型——端上模型卡（按 SystemLanguageModel availability 显隐）与 API Key 卡（直达 AI 设置）；② 隐私防护——广告/追踪拦截开关，绑定真实 ContentBlockerStore；③ 同步与个性化——同步入口 + 称呼/自定义指令；全部可跳过，完成写 `memory.onboardingCompleted`（面板不再显示）。导航统一收进自适应 footer（上一步/跳过/下一步·完成）；`finish()` 空输入不覆写既有个性化档案
- **旁路成本归账分账 + 成本感知路由 v1（0.6.7 P0 两项）**：① 旁路模型调用（标题/记忆整理/自评/reflect 工具）的用量在 token 总量之外**逐笔记账**（种类 + 实际模型，挂本回合尾助手消息随会话落盘），`AgentUsage.of`/`UsageStats.derive` 按各笔**自己的模型**定价——成本路由后旁路跑的模型 ≠ 主模型也算得对；统计页模型列表新增「旁路调用」行，`/agent/stats` 带 `bypassTokens`。② 设置 → AI 新增「Bypass Calls」档案选择器（桥 `GET|POST /ai/bypass-profile`）：标题/记忆整理走指定（便宜）模型，默认跟随对话；评审档案语义不变（评审者 ≠ 被评审者）。旁路偏好视图直接**注入内存档案**、不读盘——DiskStore writer 在评估/大会话负载下积压可达分钟级，靠盘上读刚建的档案会撞空（评估 E7 实测后修）。评估集新增 E7（bypass-routing）：fixture 逐请求记录 model，断言标题请求走旁路档案、主回合不受影响、统计按实际模型分账。
- **评估集 E8（whiteboard-contract）**：假 LLM 一条消息连发 10 个调用（7 个 whiteboard + screenshot + evidence append + get），按序断言全部 action 的成功文案与 Error: 契约分支（越界 edit / 缺 index / 移动越界）、读板闭环（编辑后 get 读回 `X-->Y`）、screenshot→evidence 引用链（image 块零 base64 回传、get 读出 `[image]` data URI 占位）。附：E4 失败时打印最终文本的探针，供偶发复现时定位。
- **工具结果摘要缓存 + getToolResult 重取句柄（0.6.7 P1 收官）**：超长工具结果（readFile 60KB 上限、大页面 executeJS 等）过去在 kept 轮次里**每轮原样重发**、独吃上下文——现在请求组装时替换为「600 字符头部 + 截断标记（含总长与 getToolResult 句柄）」，落盘与会话内存保持**全文**（面板/轨迹/历史不受影响）。新工具 `getToolResult(callId, offset, length)`（readonly 免审批）按句柄读回全文或任意切片，模型「先看摘要、需要再取」；上下文压力大的多工具回合墙钟与 token 双降。纯函数（`ContextCompaction.summarizingOversizedToolResults`）进单测 harness；评估 E9 全链断言（readFile 20KB → stub 里 END 哨兵不可见 → 按句柄尾部切片取回 → 哨兵可见）。









## [v0.6.6] - 2026-10-05
### Fixed

- **发现既有自动化 bug：`/responsive` 杀死桥 listener（未修，记录在案）**：POST /responsive（enabled=true）触发响应式装配后，桥 listener 对一切后续请求（含 /state）无响应直至 app 重启——stash 掉本批全部改动后在 HEAD 上同样复现（既有限制，非新引入）。**根因待查**（主 actor 存活——DSP-PING 探针有响应；listener accept/处理循环死）。影响面：仅自动化桥（UI 里的响应式模式正常），pixelRatio 的 E2E 断言因此受阻。
- **POST /responsive 挂死桥 listener（根因修复）**：响应载荷里的 **CGSize** 无法被 NSJSONSerialization 序列化——ObjC 异常穿 async 帧把主 actor 打成僵尸态（已知事故模式第 3 例），桥对一切后续请求无响应。修复：size 序列化为 width/height 字典；配置变更移入异步 Task（响应先回、UI 变更随后）。E2E：/responsive 不再挂、dpr 覆写 2→3→还原 2 全程桥存活。


### Added

- **会话级网络拦截（0.6.6 spike 收敛）**：InterceptStore 新增 `sessionRules`（不持久化，app 退出即消失）——Agent `networkRules` 工具（add/list/clear）与桥 `POST /intercept/session/add|clear` 可为自动化任务临时屏蔽坏分析器/重定向 CDN，不污染用户过滤列表。**spike 结论（独立宿主双验证）**：① 主框架 **block 生效**但导航静默终止（无 didFail/didCommit，页面停旧渲染——marker 法断言）；② 主框架 **redirect 不生效**（WebKit 限制，工具描述已标注）；③ 工具清单/`GET /intercept` 带 session 标记。
- **pixelRatio 模拟生效（0.6.6 响应式收尾）**：`PixelRatioOverride` 覆写 `window.devicePixelRatio`（defineProperty 可配置、保存原描述符可还原）——此前 ResponsiveConfig.pixelRatio 只是工具栏文案（"@2x"），页面 JS 从未读到模拟值。接线：响应式启用时 apply、退出时还原、bar 上 DPR 步进菜单（1/2/3x）+ onChange 实时调整、`/responsive` 桥加 pixelRatio 参数。
- **DevTools Network 会话拦截入口**：请求右键菜单新增「Block This URL (Session)」——走 0.6.6 的会话规则（不进用户过滤列表、app 退出即消失），命中写 Console 日志（⛔ 前缀）供对账。
- **评估集扩面（E6 network-rules）**：agent-eval 新增会话拦截用例——networkRules(add) 被调用、工具结果确认会话规则、无 threwError、/intercept 的 sessionRules 在场，清理自动执行；评估 24/24。





## [v0.6.5] - 2026-10-05
### Added

- **Reader TTS 朗读（0.6.5 首项）**：阅读模式工具条新增朗读按钮——AVSpeechSynthesizer 端上合成（零费用、数据不出机），CJK 占比自动选 zh-CN/en-US voice，暂停/继续/停止三态；离开阅读模式自动停止（onDisappear），通知 "readerSpeechStop" 可全局停。批量编辑教训重申：本轮 ReaderView 的按钮注入用 python 脚本误删 Back 按钮内部结构——构建前 git diff 抓到，Edit 工具重做。
- **划词工具条补全（0.6.5）**：SelectionAIBar 新增「搜索」「复制」——搜索与右键"搜索…"同管线（URL 形文本直达、其余走默认引擎，后台打开偏好生效），复制进剪贴板；浮条现有七动作（搜索/复制/解释/翻译/问 Agent/高亮×4）。构造拆出 `selectionAIBar(_:)` 方法（闭包加到 6 个后 body 内表达式 type-check 超时，onLearnReason 同款先例）。
- **视频速度控制（0.6.5）**：video-speed.js 页面桥（atDocumentEnd, page world）——`__desireVideoSpeed.set(rate)` 应用到当前与未来所有媒体元素（MutationObserver 保持新元素，preservePitch 恒真），rate≠1 时右下角徽章 8s 淡出；页面右键新增「Video Speed」子菜单（0.5–3x 六档）；桥 `POST /video-speed`（Agent/自动化同权，钳制 0.25–3）。E2E：设 1.5 → 元素读回 1.5、新建元素继承、10 钳到 3、恢复 1x。
- **Cookie 弹窗自动处理（0.6.5）**：cookie-banner-guard.js（atDocumentEnd, page world）按 CMP 词表（OneTrust/CookieBot/Complianz/Usercentrics + cookie/banner/gdpr 关键词）识别同意弹窗，按设置偏好自动点击「拒绝全部/接受全部」（设置 → 隐私三档：关/全拒/全受，默认关；对新页面加载生效）；MutationObserver 8s 窗口兜底 CMP 懒加载，每页一次机会防循环；命中走 toast 通道（「Cookie 弹窗已拒绝（Reject all）」）。E2E：OneTrust fixture 的 Reject all 按钮被自动点击。**诚实口径**：自绘非标按钮可能漏——漏了当没这功能。





## [v0.6.4] - 2026-10-05
### Added

- **性能优化四件套（0.6.4 首批）**：① **渲染进程崩溃自愈**——`webViewWebContentProcessDidTerminate` 自动重载（10s 节流防崩溃循环），内容区橙色提示条「页面已自动恢复」，didCommit 清除；此前崩溃 = 白屏无提示。② **挂起/唤醒事件日志**——挂起巡检与恢复写 unified log（tabs 分类），内存压力/时长阈值的生效过程可对账。③ **启动分段打点常驻化**——app init → didFinishLaunching → 首窗内容三相位 unified log（探针实测 0/475/517ms，桥就绪 0.82s）。④ **`scripts/perf-launch.sh` 启动探针**——进程启动→桥就绪计时 + 阈值退出码（默认 5s，供本地/CI 门禁）。
- **大页面守护（0.6.4 第二批）**：page-perf.js 每 5s 上报 DOM 节点数 + long task 计数（PerformanceObserver buffered）——WebKit 无公开 per-tab 内存 API，节点数为约定代理指标（诚实口径）。挂起巡检新增分支：后台标签 >25_000 节点即挂起（豁免集与闲置分支一致），切回自动恢复；标签右键新增「Copy Performance Snapshot」（DOM/long task/挂起态纯文本）；`GET /state` 每标签补 `suspended`/`domNodes`。E2E：26k 节点后台标签在巡检后被挂起、切回自动恢复（domNodes=26004 断言）。
- **DevTools「Performance」页签（0.6.4 第三批）**：轻量只读——DOM 节点数（超 25k 阈值橙色警示）/ long task 计数与累计耗时 / 挂起状态，数据来自 page-perf.js 上报；不做 flame graph（Web Inspector 自带的重活不重复，见路线图）。
- **0.6.4 收尾**：大页面守护接入设置（General「Large Page Guard」开关，默认开，豁免口径写在副标题）；发版冒烟阶段新增启动→桥就绪计时报告（>10s 记警告不拦发版——首次启动含会话恢复，数值供版本间对账）。




### Fixed

- **0.6.3 发版闸门拦截一条 Release 警告**：TabAudioControl 的 `try? await` 打在同步 evaluateJavaScript 上（Release 配置下 WKWebView 无 async 重载推导）——改 withCheckedContinuation 包装。


## [v0.6.3] - 2026-10-05
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
