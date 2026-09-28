# Desire 大项功能分类核查报告（第三轮 · 2026-09-29）

> 与前两轮（横切面：架构/性能/并发）不同，本轮**按功能大项逐项过**，
> 找功能正确性 bug 与潜在隐患。五路并行审查 + 关键 P0 人工实证。
> 汇总：**新发现 75 项**（P0×6 / P1×21 / P2×48），分布在 14 个功能大项。
> 修复按第八~十一批推进（见文末）。

---

# 一、功能大项分类清单

| # | 大项 | 核心文件 | 本轮发现 |
|---|------|---------|---------|
| 1 | 浏览核心（导航/证书/对话框/下载代理） | Browsing/WebView.swift, BrowserWKWebView | P1×2, P2×4 |
| 2 | 标签与会话（挂起恢复/会话恢复/标签组/分屏） | Tabs/TabManager, TabOverview | P0×1, P1×3, P2×5 |
| 3 | 多档案与容器（Profile 隔离） | Profile/, Containers/ | **P0×1** |
| 4 | 地址栏与工具栏 | AddressBar/, Toolbar/, URLBarField | P0×1, P1×2, P2×3 |
| 5 | 数据存储（书签/历史/阅读列表/快拨/密码/表单） | Bookmarks/, History/, Password/ | **P0×1**, P1×1, P2×6 |
| 6 | 内容拦截（内置/社区/元素/视频广告/请求拦截） | ContentBlocking/, VideoAdBlocking/ | P1×2, P2×5 |
| 7 | 隐私（无痕/Cookie/HTTPS 升级/密码检测） | PrivacyMode/, HTTPSUpgrade/ | P2×2 |
| 8 | 下载系统（普通/媒体/批量引擎） | Downloads/ | P1×3, P2×3 |
| 9 | AI Agent（会话/工具/记忆/调度/Crew） | Agent/ | P0×1, P1×3, P2×10 |
| 10 | 同步（引擎/加密/登录） | Sync/ | P1×1, P2×3 |
| 11 | 远程控制 | Remote/ | P1×2, P2×4 |
| 12 | 自动化桥/MCP | App/AutomationServer, MCPService | P2×1 |
| 13 | 插件系统（归一后新件） | UserScripts/ 新件 | P2×2 |
| 14 | 截图/录屏 | Screenshot/, WindowRecorder | P1×1 |
| 15 | PageWatch | PageWatch/ | P1×1 |

---

# 二、发现明细

## F-P0（六项，全部实证）

### P0-A 多档案（Profile）的 Cookie 隔离整条链路未接线——多档案功能实际不存在
- `TabManager.addTab` 的 `profileDataStore` 参数**没有任何调用点传入**（全仓仅函数定义一处命中）；
  `ProfileStore.dataStore(for:)` 的隔离 store 永远到不了 webview。切人物后登录态全部写进
  default store——跨人物串档；书签/历史作用域切换反而制造"已隔离"错觉。
- 修法：`addTab` 内补 `profileDataStore: profileDataStore ?? self.profileDataStore`（TabManager 自身
  属性有值时兜底），会话恢复 `apply` 同理。

### P0-B 会话恢复懒物化只做了一半，且与恢复互相竞争
- `Tab.init` 拿到非空 url **立即 load**；`apply` 之后才把非选中标签标记 suspended——启动瞬间 N 个
  标签照旧并发发起导航（审计勾了 [x] 但目标未达成）。选中标签也存在 init load 与 interactionState
  恢复的竞争（init 先发出 fresh load，正好撞上注释里警告的"CANCEL the restoration"）。
- 修法：`apply` 对非选中标签不传 url（或 Tab 加 `loadsPage: false` 参数）；选中标签 init 后先取消
  在途加载再设 interactionState。

### P0-C 密码存得进、读不回：写入缺 `kSecAttrService`
- `PasswordStore.addToKeychain` 的 query **没有** `kSecAttrService`；`loadAll()` 却强制按
  `kSecAttrService = "me.siwi.Desire"` 过滤 → 重启后全部密码消失、自动填充失效。SecItemAdd
  结果也未检查。修法：写入补 service 属性 + 对旧无 service 条目做一次性迁移枚举重写。

### P0-D 批量下载 page 模式失败无限重试：attempts 永不增长
- `bumpAttempts` 只在 list 模式解析阶段调用；page 模式下载失败不递增 attempts → 重试判据恒真 →
  15s 冷却死循环，批次永不落定、跨重启恢复后继续循环。修法：`downloadSettled` 的 failed 分支补
  bumpAttempts。

### P0-E MediaExporter.sequenceIV 生成 24 字节 IV → 无显式 IV 的 AES-128 HLS 静默损坏
- `Data(count:8)` + append 8 字节已是 16 字节，`insert 8 零 at:0` 又插成 24 字节——CCCrypt 只读
  前 16（全零 IV），媒体序号被丢弃。坏 IV 只损坏每段前 16 字节，PKCS7 校验仍过 → 导出"成功"
  但花屏。修法：删掉 insert 那行。**（实证：代码确实多插 8 个零。）**

### P0-F AI Agent：工具循环中途取消 → 未配对 tool_calls 落盘 → 会话被严格端点永久拒绝
- 批量工具调用第 1 个结果落盘后用户按 Esc → 存为 `[assistant(3 calls), tool(1 result)]` → 此后
  每条消息都被 OpenAI 兼容端点以 "tool_calls must be followed by tool messages" 400 拒绝，
  轮轮如此，会话报废且无自愈入口（`droppingDanglingToolCalls` 只修"末条悬空 assistant"变体）。
- 修法：请求组装前对全数组清洗——为每个无结果的 tool_call_id 补 `[interrupted]` 工具消息。

## F-P1（二十一项）

**浏览核心/标签：**
- P1-1 主框架 30s 加载看门狗不可达（beforeunload 守卫的 early-return 把 armLoadTimeout 闷死，
  仅剩 formResubmitted 能到达）→ 挂起 TCP 永久白页。
- P1-2 切标签 dismantle 先摘 navigationDelegate 再 stopLoading → 后台标签加载被取消且
  isLoading 永久卡 true；期间 12 个 script handler 被摘，页面注入脚本报 TypeError。
- P1-3 `otpDetect` 消息处理器从未注册——验证码提示条整条链路死的（脚本在 post、处理分支在、
  消费者在，唯独注册清单漏了它）。
- P1-4 `elementPickIntent` 被 DevTools 置成 .devTools 后永不还原 → 工具栏"元素屏蔽"拾取被劫持
  喂给 DevTools；`.ai` 分支不可达（死代码）。
- P1-5 挂起标签被设为分屏伙伴 → 右栏永久白屏（SplitPartnerPane 无 suspended 分支，
  sweep 又对它免疫）。
- P1-6 PageWatch：检查进行中（最长 12.3s 窗口）删 watch → idx 失配写穿到别的 watch，越界即崩。

**地址栏/工具栏：**
- P1-7 100ms 防抖窗口内按回车提交**上一次击键**的候选（快打字 + 回车 <100ms 必现）——提交前
  无"列表是否对应当前文本"校验。
- P1-8 Esc 不退出 first responder：地址栏进入半聚焦僵尸态（无下拉无高亮），直到点别处再回来。
- P1-9 默认页面缩放设置从未生效：didCommit 用 `zoom(for:)` 的字面量 1.0 兜底覆盖
  （不看 defaultPageZoom）。
- P1-10 内置引擎关键词路由大小写写错（`firstWord == engine.rawValue`，rawValue 是
  "Baidu" 而 firstWord 已小写）→ "baidu 新闻" 永不命中关键词搜索。

**数据存储：**
- P1-11 CSV 导入按固定列位解析（Chrome 列序），Firefox 导出会写坏真实 Keychain 数据——
  应按表头映射。

**内容拦截：**
- P1-12 CRLF 覆盖规则文件击穿**全部**视频站 CSS（转义缺 `\r`，CR 进 JS 字符串字面量即
  SyntaxError，8 站拼接一坏全坏，零日志）。
- P1-13 **第五批声称的"CSS 按 generation 缓存"实际未实现**（当时提交只做了 xpath 合并——
  账面虚报）。现状：每标签每次 didCommit 主线程全量重建 44KB × 3 轮扫描 +
  `remoteURL` 每次同步读盘（每导航 9 次文件 IO）。
- P1-14 VideoAdRulesStore：信任远程脚本开关不 bump generation → 已开标签刷新后远程 JS 永不
  生效；VideoAdBlocker 关闭开关后已开标签永远继续拦截（无反向清理路径）。

**下载系统：**
- P1-15 WindowRecorder：零帧/写头失败（磁盘满）时 `markAsFinished` 抛 ObjC 异常 → stop 即崩
  （`startWriting()` 返回值被忽略）。
- P1-16 skip 一个"下载中"的项 → 批次引擎失速（并发槽空转，downloading 分支 skip 后不
  pump/check，page 模式 engineLoop 又是一次性）。

**AI Agent：**
- P1-17 cancel() 后立即新发送：旧循环"复活"（循环检查点只看共享 isCancelled 标志，被新发送
  重置）→ 双循环交错写 messages、旧 defer 把新回合 isProcessing 踩成 false。
- P1-18 回合收尾的自评/机械核验用活体 messages 定位落点 → 与下一回合并发时评语写进新回合
  正在流式的消息（R2-5 快照化只做了 memory/title）。
- P1-19 两个 askUser 并行批次互相覆盖（askUser 归 readonly 可进并行批；UserPromptCenter.ask
  直接覆盖旧 pending）→ 先问的挂满 10 分钟超时。
- P1-20 同步：应用内登录（密码/QR/桥）后**同步基础设施永不启动**（Timer/网络监视/唤醒观察
  只在启动时已登录才装）→ 本机不再主动拉取直到重启。
- P1-21 远程：登录转换不重连 WS（`syncAuthDidChange` 是零调用死代码）→ express 下行单腿；
  `remoteConversationID` 与面板实际会话漂移 → 手机消息落错会话。

**其他：**
- P1-22 录屏零帧/写头失败（磁盘满）→ `markAsFinished` ObjC 异常崩（startWriting 返回值被忽略）。
- P1-23 MediaExporter `sequenceIV` 见 P0-E（同源）。

## F-P2（四十八项，摘要分组）

**浏览/标签（9）**：默认缩放被 didCommit 打回（设置失效）｜会话 selectedIndex 与剔除无痕后
错位｜纯无痕窗口 15s tick 删自己会话文件｜标签组：关标签不清成员 + 重启成员 ID 重生成全悬空｜
selectionAI 不随导航清除｜翻译状态不复位｜分屏+概览双宿主｜关左侧标签选中右移｜passwordSave
跨域跳转记错域名。

**地址栏/存储（6）**：QuickDial 全删重启被默认八枚覆盖｜无 scheme 带 ?# 的 URL 判成搜索词｜
SearchSuggestionService 空结果永久缓存｜表单填充转义不处理 `\` 与换行（多行地址打爆注入）｜
书签删文件夹不记子树墓碑（跨设备删后改竞态下根部复活）｜BookmarkStore 里带 bug 的
importFromHTML 死副本。

**拦截/媒体（10）**：xpath 合并顺手把转义改坏（反斜杠 no-op + 单坏规则打爆全部）｜
InterceptStore 删除与编译竞态（已删规则复活常驻）｜两批同名文件夹共享 .part 交叉写坏｜
取消/挂起/跳过遗留 .part 孤儿无清理｜直连媒体整段读进内存（数 GB 峰值）｜磁盘挂起提问的
"换位置"用 runModal（远程会话触发=冻结全 app）｜sanitize 二分仍在主线程转换 + probe 缓存
残件 + lastAttemptRuleCount 跨列表竞态｜隐私"Cookie 策略"两项是死开关｜VideoAdBlocker 关闭
后已开标签继续拦截｜ffprobe 同步跑 MainActor 无超时。

**Agent（10）**：子代理工具结果不脱敏（凭据可直达 LLM）｜executeJS 失败回退重复执行带副作用
代码（最多 3 次）｜saveAsPDF 写盘失败仍报成功｜定时/crew 聚合提示混入输入历史｜
turnFinishHandlers 泄漏 + 取消的定时任务记成 success｜crew 两条退出路径不 settle（最后一名
失败领队永远收不到聚合）｜页面文本进 system 提示词（提示注入面）｜askAboutPage 乱序 append｜
sendFollowUp 丢附件｜杂项（navigate 无 scheme 假成功、blockElements 默认全站、记忆 pinned
强删、scope 匹配过松、切会话占用残留、daily 补跑不成立、printPage 模态、renderDiagram 注入面、
孤儿工具结果显示错配）。

**同步/远程/插件（9）**：信箱去重集满 500 全清（重放=重复发消息）｜PluginPanel 安装按钮重新
引入 runModal｜同名重装 `backgroundCode ?? existing` 旧后台残留｜onInstalled 300ms 启发式
不保证监听器已注册｜hmacClientID 失败回退随机密钥（删除同步永久失效，应 fail-fast）｜游标
同秒大组倒退重拉（浪费带宽）｜remote pull 限流 150/min 只容 2 设备｜MCP resolvePath 不转义
`&#`+（参数改写）｜快照指纹两处小缺口。

---

# 三、确认健康（勿过度修复）

会话级证书例外语义、beforeunload 单次响应守卫、HTTPS 升级防循环、History 墓碑下推与
标题校正、ReadingList/QuickDial/快捷键同步合并、SearchSuggestionService 乱序丢弃、
ContentBlockerStore 只移除自己两条、BookmarkImportService 四路解析、Rust auth 防爆破/
refresh 轮换/QR 原子消费、user_delete FK 级联、SyncMerge 孤儿成环守卫、插件 RPC default
分支显式报错、系统命令超时钳制、只读并行批按序回填、审批幂等三方竞态、Evidence LRU、
Markdown 取消传播。

---

# 四、优化批次计划（第八~十一批）

### 第八批：P0 六项 + 功能坏死 P1（预计 1 天）
- [x] P0-A Profile 隔离接线（addTab 兜底传 store；apply 同理）
- [x] P0-B 懒物化补全（apply 不传 url / 选中标签先取消在途再恢复）
- [x] P0-C 密码 service 属性修复（旧无 service 条目**不做盲扫迁移**——无法区分本 app 与系统其他条目，误吞用户真实密码风险大于重存成本；受影响用户重存一次即可）
- [x] P0-D 批量 page 模式 attempts 递增
- [x] P0-E sequenceIV 删多余 insert
- [x] P0-F Agent 请求前未配对 tool_calls 清洗
- [x] P1-3 otpDetect 注册（一行）
- [x] P1-10 关键词路由大小写
- [x] P1-12 CRLF 转义补 \r
- [x] P1-14 信任开关 bump generation + 关闭开关反向清理
- [x] P1-16 skip downloading 项后 pump+check

### 第九批：P1 收尾（预计 1-2 天）
- [ ] P1-1 看门狗恢复（beforeunload 分支补 arm）
- [ ] P1-2 dismantle 顺序（先 stop 后摘 delegate）+ isLoading 复位
- [ ] P1-4 elementPickIntent 还原机制
- [ ] P1-5 分屏伙伴挂起恢复
- [ ] P1-6 PageWatch idx 按 id 定位写回
- [ ] P1-7 回车提交前校验候选归属
- [ ] P1-8 Esc resignFirstResponder
- [ ] P1-9/11 默认缩放兜底 / CSV 表头映射
- [ ] P1-15 录屏 startWriting 失败守卫
- [ ] P1-17 循环检查点补 Task.isCancelled
- [ ] P1-18 自评/核验按 id 写回
- [ ] P1-19 askUser 覆盖先 resume 旧
- [ ] P1-20/21 登录后起同步设施 / 远程登录重连 + 会话基准

### 第十批：媒体与拦截深化（1 天）
- [ ] P1-13 CSS 代数缓存**真正实现** + remoteURL 读盘缓存（补第五批的账）
- [ ] 直连媒体流式落盘（.part + downloadTask）
- [ ] .part 孤儿清理（cancel/finalize 扫批内已知项）
- [ ] 同名 .part 唯一化（掺 UUID）
- [ ] InterceptStore 删除竞态 + FilterList sanitize 挪后台/probe 清理/计数随返回值
- [ ] 磁盘挂起"换位置"改 beginSheetModal
- [ ] 关闭 VideoAdBlocker 的反向清理；xpath 转义回归修复

### 第十一批：P2 清理（随功能顺带）
- [ ] 浏览/标签 9 项（缩放兜底、selectedIndex 偏移、标签组成员、selectionAI 复位等）
- [ ] 地址栏/存储 6 项（QuickDial 空数组、URL 判定、填充转义统一 jsStringLiteral、
      书签子树墓碑、删死副本、CSV 表头映射并入 P1-11）
- [ ] Agent 10 项（子代理脱敏、executeJS 单次化、saveAsPDF、recordHistory、
      turnFinishHandlers、crew settle、页面文本围栏等）
- [ ] 同步/远程/插件 9 项（去重滑动窗、runModal 改 sheet、重装覆盖语义、onInstalled
      以 didFinish 触发、hmac fail-fast、游标取 filtered.last、限流分桶、MCP 转义、指纹缺口）
- [ ] P2-17 ffprobe 超时 + Process terminate 判空
