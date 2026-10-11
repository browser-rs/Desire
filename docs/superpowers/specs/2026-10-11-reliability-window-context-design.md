# Desire 可靠性与多窗口上下文改造设计

## 状态

设计阶段，待确认。日期：2026-10-11。

## 背景

Desire 当前已经具备完整的 AI 浏览器能力，包括多窗口、Agent、MCP、Remote、同步和 Rust 后端。下一阶段的主要风险不是功能缺失，而是跨异步边界的所有权与一致性：

- 文件写入由 detached 编码任务和 writer actor 两段组成，退出 flush 不能确认所有编码已经入队。
- Agent 回合使用共享取消状态，取消旧回合后立即开始新回合存在旧任务继续写状态的风险。
- Profile 文档定义为 per-window，但 active profile、书签/历史作用域仍由 AppState 全局切换。
- MCP 服务和 Remote 关键操作缺少完整的连接隔离或数据库原子性。
- Rust 后端没有进入主 CI，发布脚本仍可能把工作区全部变更加入提交。

本设计以当前 HEAD 的代码和现有审计为基线，不重复已经完成的修复。

## 目标

1. 退出、取消、切换会话时不丢写、不串回合、不写错会话。
2. 多窗口的 Profile、标签、Agent、悬浮球和 MCP 操作拥有明确且一致的窗口归属。
3. Remote 配对、信箱消费和同步密钥登记具备并发安全的数据库语义。
4. 自动化桥和 MCP 的认证校验严格，Rust 后端进入发布质量闸门。
5. 长会话和大量工具结果不会把完整上下文整理工作长期压在 MainActor。
6. 每个高风险行为都有确定性回归测试或协议级集成测试。

## 非目标

- 本轮不立即把 DiskStore 全部迁移到 Core Data；先保留文件存储，只有达到数据量阈值后再做索引或数据库迁移。
- 本轮不抽象一个尚无第二实现的 WebEngine 协议；先改善现有 WebKit 边界。
- 不重新启用 App Sandbox。Agent 的系统命令能力依赖当前非沙盒决策。
- 不改变公开 Agent 工具语义、桥端点名称或 Remote lane 协议，除非为修复明确的错误。
- 不引入第三方 UI 或网络依赖。

## 分阶段方案

### 第一批：正确性与安全

#### DiskStore 写入屏障

`DiskStore.save` 为每次编码任务生成可等待的写入序号。writer actor 提供带序号的 barrier：barrier 返回前，指定序号之前的编码任务必须已经完成并进入 writer，且 writer 的 pending write/remove 已经落盘。相同 key 的 save/remove 使用单调序列裁决迟到任务，不能让旧 save 复活已删除文件。

验收：连续 save、save 后 remove、remove 后 save、立即 flush、flush 超时和优雅退出均有测试；最终文件内容与操作序列一致。

#### Agent 回合所有权

每次 `processLoop` 创建唯一 `TurnID`。所有可能跨 await 的回写点使用 `isCurrentTurn(_:)` 检查；取消、切换会话和新回合开始时使旧 TurnID 失效。只有当前回合可以修改 `isProcessing`、`currentAction`、收尾状态、消息流和回合完成回调。

共享 `isCancelled` 可以保留为当前回合的 UI 状态，但不再承担任务身份判断。

验收：取消后立即发送、取消审批、取消 askUser、切换会话、远程切会话、队列插队均不产生跨回合消息或状态写入。

#### Remote 与同步数据库原子性

- 配对 claim 使用事务锁或带 `claimed_at IS NULL` 的条件更新，并检查 `rows_affected`。
- inbox take 在事务内锁定待读行后删除，避免并发 pull 重复消费。
- sync key check 和 escrow 首次登记改为条件写入或事务锁，保证 fingerprint、salt 和 wrapped key 作为同一版本建立。
- Remote inbox 增加按用户/设备/lane 的数量和字节配额，以及可索引的 TTL 清理路径。

验收：双并发 claim、双并发 pull、双设备首次登记和超配额请求都有 Rust 集成测试。

#### 自动化认证

统一解析 `Authorization`，只接受完整的 `Bearer <token>` 值；禁止 token 前缀匹配、额外字符和歧义 Header。AutomationServer 与 MCP 使用同一套 Foundation-only 解析逻辑或等价实现，并保留无 token 本机模式的现有语义。

验收：正确 token、缺失 token、错误 token、前缀 token、大小写 scheme、重复 Header 都有测试。

### 第二批：WindowBrowsingContext

新增窗口级上下文对象，至少包含：

- `windowID` / `sessionKey`
- `profileID`
- `WKWebsiteDataStore`
- 该窗口的 `TabManager`
- 书签、历史、快拨等作用域访问入口

`ContentView` 创建并持有 context；TabManager 的新建、复制、恢复、跨窗口迁移统一从 context 获取 Profile 数据存储。AppState 不再用单个全局 `activeProfileID` 表达所有窗口的 Profile。全局 ProfileStore 只负责 Profile 定义和 DataStore 缓存，不负责当前窗口选择。

Agent 的 `WindowToolSurface`、AgentBall、UserPromptCenter、MCP session 和桥 window 参数都绑定明确的 `windowID`。禁止通过 `NSApp.keyWindow` 或“最后注册的闭包”推断操作目标。

会话恢复返回结构化结果，例如 `SessionRestore.Result(sessionID:sessionKey:)`，不再分别返回旧 UUID 和实际采用的 key。

验收：两个窗口分别使用两个 Profile 时，Cookie、书签、历史、快拨、Agent、悬浮球、MCP 和会话文件互不串台；关闭后台窗口最后标签不会关闭前台窗口。

### 第三批：性能与稳定性

`AgentSessionStore` 在 MainActor 上捕获不可变消息快照，将上下文压缩、工具结果摘要和大消息裁剪移到专用 actor 或可取消 detached task。结果必须带消息 revision，旧计算结果不得覆盖新会话状态。

保留当前 DiskStore 文件模型，增加会话元数据索引的触发阈值；仅在文件数量或总大小超过阈值时启用懒加载。对 Remote snapshot、DevTools 记录、挂起标签和图片消息继续采用有界缓存和节流。

验收：长会话、40KB 流式回答、多个大工具结果和 30 个标签场景下，主线程探针无持续卡顿，旧快照不会覆盖新消息。

### 第四批：工程治理

CI 新增 Rust job：

- `cargo fmt --check`
- `cargo test --workspace`
- `cargo build --workspace`
- API smoke test

发布脚本不再使用 `git add -A`；发布前要求工作区状态明确，只 stage 版本相关文件，并执行秘密文件扫描。发布文档、架构清单和版本号继续由脚本校验，但不自动吞掉用户未预期的变更。

补充协议级测试矩阵：MCP 多客户端、多窗口 bridge、Remote 并发消费、同步 key 首次注册、Agent 取消生命周期、DiskStore flush barrier。

## 依赖顺序

1. 第一批可以独立实施，不依赖多窗口重构。
2. 第二批依赖第一批的持久化和回合生命周期测试，避免重构时难以区分新旧竞态。
3. 第三批依赖第二批明确的窗口和消息所有权。
4. 第四批可与前三批并行准备，但发布闸门应在第一批完成后启用。

## 风险与取舍

- WindowBrowsingContext 会触及 ContentView、TabManager、SessionRestore、Agent 和 AutomationServer，是最大改动面；通过先增加 context 再逐步迁移调用点，避免一次性删除旧 accessor。
- DiskStore barrier 不能在主线程等待无限时长；退出路径使用有界等待，并记录未完成 key 和序号，便于诊断。
- Agent 的后台压缩必须支持取消，否则用户快速切换会话时会积累过期计算任务。
- Remote inbox 取走语义仍保持 at-most-once；本轮解决并发重复，不改变“消费后不重投”的产品取舍。

## 总体验收标准

- `tests/run.sh` 全绿。
- macOS clean build 零代码警告。
- Rust workspace fmt/test/build 全绿，API smoke 全绿。
- Agent eval 与 Remote smoke 全绿。
- 新增的并发和生命周期测试全部稳定通过至少两次连续运行。
- 退出、取消、双窗口、双客户端和错误恢复路径都有日志和可定位的失败信息。
