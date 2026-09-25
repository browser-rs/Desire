// 纯逻辑单测入口：`tests/run.sh` 用 swiftc 把受测文件与本文件一起编译成可执行
// 直接断言，不依赖 Xcode 与应用 target（项目暂无测试 target，见 AGENTS「工程」一节）。
// 新增用例：往下加 `check("名称", 条件)` 即可；失败会列出并令脚本以非零码退出。

import Foundation

var failures: [String] = []
var count = 0

func check(_ name: String, _ condition: Bool) {
    count += 1
    if !condition {
        failures.append(name)
        print("✗ \(name)")
    }
}

func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    count += 1
    if got != want {
        failures.append(name)
        print("✗ \(name)\n    got  = \(got)\n    want = \(want)")
    }
}

// ---------- 构造器 ----------

/// `createdAt` 在模型里是 `let` 且 init 不收，测试用 Codable 通道注入时间。
func msg(_ role: AgentMessageRole, _ text: String, model: String? = nil,
         p: Int? = nil, c: Int? = nil, at: Date = Date(),
         toolCallId: String? = nil, toolName: String? = nil) -> AgentMessage {
    var dict: [String: Any] = [
        "id": UUID().uuidString,
        "role": role.rawValue,
        "content": text,
        "createdAt": at.timeIntervalSinceReferenceDate,
    ]
    if let model { dict["model"] = model }
    if let p { dict["promptTokens"] = p }
    if let c { dict["completionTokens"] = c }
    if let toolCallId { dict["toolCallId"] = toolCallId }
    if let toolName { dict["toolName"] = toolName }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(AgentMessage.self, from: data)
}

func conv(_ title: String, _ messages: [AgentMessage]) -> Conversation {
    Conversation(id: UUID(), title: title, createdAt: messages.first?.createdAt ?? Date(),
                 updatedAt: messages.last?.createdAt ?? Date(), messages: messages, inputHistory: [])
}

// ---------- SecretRedactor ----------

let longSK = "sk-abcdefghijklmnopqrstuvwx"
let longBearer = "Bearer abcdefghijklmnopqrstuvwxyz"

// 回归：多个形态命中、串被替换变短 —— 旧实现带着循环外缓存的 NSRange 会越界崩溃
// （2026-09-23 NSRangeException，见 CHANGELOG）。
let multi = "OPENAI_API_KEY=\(longSK) then Authorization: \(longBearer)"
check("脱敏：多形态命中不越界", !SecretRedactor.redact(multi).contains(longSK))
check("脱敏：多形态全部屏蔽", !SecretRedactor.redact(multi).contains(longBearer))
check("脱敏：出现掩码", SecretRedactor.redact(multi).contains("[redacted]"))

// CJK 与命中混排（索引按 UTF-16 计，多字节字符是最容易踩越界的形态）
let cjk = "密钥\(longSK)和令牌\(longBearer)末尾"
check("脱敏：CJK 混排", !SecretRedactor.redact(cjk).contains(longSK) && !SecretRedactor.redact(cjk).contains(longBearer))

// 应用自己配置的 Key（形态规则认不出的自建网关 Key）
check("脱敏：已知 Key 精确匹配", !SecretRedactor.redact("token = supersecretkey99", knownKeys: ["supersecretkey99"]).contains("supersecretkey99"))

// PEM 私钥块
let pem = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg\n-----END PRIVATE KEY-----"
check("脱敏：PEM 块", SecretRedactor.containsSecret(pem))

// 无命中：原样返回（调用方据此跳过写入）
let clean = "普通正文没有密钥，sk- 太短不算。"
eq("脱敏：无命中原样返回", SecretRedactor.redact(clean), clean)
check("脱敏：containsSecret(false)", !SecretRedactor.containsSecret(clean))

// ---------- AgentUsage ----------

eq("金额：$1.00", AgentUsage.formatUSD(1), "$1.00")
eq("金额：$0.038", AgentUsage.formatUSD(0.038), "$0.038")
eq("金额：$0.0080", AgentUsage.formatUSD(0.008007), "$0.0080")
eq("金额：< $0.0001", AgentUsage.formatUSD(0.00005), "< $0.0001")
eq("金额：$0", AgentUsage.formatUSD(0), "$0")

// 汇总：已定价 + 未定价混合 → 总额不给（hasUnpriced），绝不冒充总额
let priced = msg(.assistant, "a", model: "gpt-4o", p: 12_000, c: 800)
let unpriced = msg(.assistant, "b", model: "unknown-model", p: 5_000, c: 100)
let prices: [String: ModelPrice] = ["gpt-4o": ModelPrice(inputPerMTok: 2.5, outputPerMTok: 10)]
let mixedUsage = AgentUsage.of([priced, unpriced]) { $0.flatMap { prices[$0] } }
eq("用量：prompt 合计", mixedUsage.promptTokens, 17_000)
eq("用量：completion 合计", mixedUsage.completionTokens, 900)
check("用量：混价 → 总额不给", mixedUsage.usd == nil && mixedUsage.hasUnpriced)
let allPriced = AgentUsage.of([priced]) { $0.flatMap { prices[$0] } }
eq("用量：已定价金额（12000×2.5 + 800×10 / 1M）", allPriced.usd ?? -1, 0.038)

// ---------- UsageStats ----------

// 活跃日：今天往前 5 天（当前连续 5），与 31~24 天前（最长连续 8）
let cal = Calendar.current
func dayAt(_ dayOffset: Int, _ hour: Int) -> Date {
    cal.date(byAdding: DateComponents(day: -dayOffset, hour: hour), to: cal.startOfDay(for: Date()))!
}

var synth: [AgentMessage] = []
for d in Array(stride(from: 31, through: 24, by: -1)) + Array(stride(from: 4, through: 0, by: -1)) {
    let model = d % 2 == 0 ? "gpt-4o" : "gpt-4o-mini"
    synth.append(msg(.user, "问 \(d)", at: dayAt(d, 21)))
    synth.append(msg(.assistant, "答 \(d)", model: model, p: 6_000, c: 400, at: dayAt(d, 22)))
}

let stats = UsageStats.derive(from: [conv("合成", synth)]) { preference in
    prices[preference ?? ""]
}
eq("统计：累计 token", stats.totalTokens, synth.reduce(0) { $0 + ($1.promptTokens ?? 0) + ($1.completionTokens ?? 0) })
eq("统计：轮数（user 消息）", stats.turns, synth.filter { $0.role == .user }.count)
eq("统计：当前连续 5 天", stats.currentStreak, 5)
eq("统计：最长连续 8 天", stats.longestStreak, 8)
check("统计：峰值日为单日 6400（本生成器每天一对）", stats.peakDayTokens == 6_400)
eq("统计：分模型桶数", stats.models.count, 2)
check("统计：逐日连续（近 30 天无断档）", stats.recentDays(30).count == 30)
check("统计：recentDays 首日是 29 天前", cal.isDate(stats.recentDays(30).first!.id, inSameDayAs: dayAt(29, 0)))

// ---------- ContextCompaction ----------

func sizedTurn(_ text: String, withTool: Bool = false) -> [AgentMessage] {
    var block = [msg(.user, text)]
    if withTool {
        var a = AgentMessage(role: .assistant, content: "")
        a.toolCalls = [AgentToolCall(id: "call_1", type: "function",
                                     function: .init(name: "readFile", arguments: "{\"path\":\"x\"}"))]
        block.append(a)
        block.append(msg(.tool, String(repeating: "x", count: 1_000),
                         toolCallId: "call_1", toolName: "readFile"))
    }
    return block
}

let big = String(repeating: "x", count: 2_000)
var turns: [AgentMessage] = []
for i in 0..<5 { turns.append(contentsOf: sizedTurn("\(i) 轮：" + big)) }
turns.append(msg(.user, "最后一条"))
turns.append(msg(.assistant, "最终回答"))

let compacted = ContextCompaction.compact(turns, budget: 4_000)
check("压缩：确实裁掉了最老的轮次", compacted.count < turns.count)
check("压缩：保留最终块", compacted.last?.content == "最终回答")
check("压缩：至少剩最后一轮", compacted.count >= 2)
eq("压缩：预算内原样返回", ContextCompaction.compact([msg(.user, "短")]).count, 1)
eq("压缩：只有一轮且超预算 → 不能丢（宁可超发）", ContextCompaction.compact([msg(.user, big)], budget: 10).count, 1)

// 压缩 + 摘要顶替：被裁轮次的要点要出现在摘要里（模型据此知道前文聊过什么）
let (kept2, digest) = ContextCompaction.compactWithDigest(turns, budget: 4_000)
check("摘要：确实发生了压缩", kept2.count < turns.count)
check("摘要：包含最早一轮的编号（0 轮）", (digest ?? "").contains("0 轮"))
check("摘要：格式为编号列表", (digest ?? "").contains("1. 用户："))
check("摘要：报了被裁轮数", (digest ?? "").contains("已被上下文裁剪"))
let keptTexts = kept2.compactMap { $0.content }.joined()
check("摘要：不等于把被裁内容留在 kept 里", digest != nil)
eq("摘要：预算内 digest 为 nil", ContextCompaction.compactWithDigest([msg(.user, "短")]).digest ?? "", "")
check("摘要：digest 不含被裁轮次之外的正文", !((digest ?? "").contains("最终回答")))

// 工具配对完整性：被保留的轮次里 assistant(toolCalls) 与 tool 结果必须成对出现
let withTool = sizedTurn(big, withTool: true) + [msg(.user, "final"), msg(.assistant, "done")]
let kept = ContextCompaction.compact(withTool, budget: 500)
let hasCalls = kept.contains { !($0.toolCalls ?? []).isEmpty }
let toolMsgs = kept.filter { $0.role == .tool }
check("压缩：工具配对不被拆散", !hasCalls || toolMsgs.count == 1)

// ---------- AgentTrace ----------

let traceMessages: [AgentMessage] = [
    msg(.user, "目标"),
    {
        var a = AgentMessage(role: .assistant, content: "")
        a.toolCalls = [AgentToolCall(id: "c1", type: "function",
                                     function: .init(name: "readFile", arguments: "{\"path\":\"x\"}"))]
        return a
    }(),
    msg(.tool, "Error: File not found", toolCallId: "c1", toolName: "readFile"),
    msg(.assistant, "最终回答"),
]
let traceTurns = AgentTrace.turns(of: conv("t", traceMessages))
eq("轨迹：回合数", traceTurns.count, 1)
let t0 = traceTurns[0]
let steps = t0["steps"] as? [[String: Any]] ?? []
eq("轨迹：步骤数", steps.count, 1)
eq("轨迹：answer 取到落盘的回答", t0["answer"] as? String ?? "", "最终回答")
let step0 = steps.first ?? [:]
eq("轨迹：动作名", step0["action"] as? String ?? "", "readFile")
eq("轨迹：失败标记（Error: 约定）", step0["threwError"] as? Bool ?? true, true)

// 轨迹：并行批的**按 id 配对**（位置配对在并发完成时张冠李戴）
let pairCalls: [AgentMessage] = [
    msg(.user, "并行读取"),
    {
        var a = AgentMessage(role: .assistant, content: "")
        a.toolCalls = [
            AgentToolCall(id: "call_A", type: "function",
                          function: .init(name: "readFile", arguments: "{\"path\":\"a\"}")),
            AgentToolCall(id: "call_B", type: "function",
                          function: .init(name: "readFile", arguments: "{\"path\":\"b\"}")),
        ]
        return a
    }(),
    msg(.tool, "结果A", toolCallId: "call_A", toolName: "readFile"),
    msg(.tool, "结果B", toolCallId: "call_B", toolName: "readFile"),
]
let pairTurns = AgentTrace.turns(of: conv("pair", pairCalls))
let pairSteps = (pairTurns[0]["steps"] as? [[String: Any]]) ?? []
eq("轨迹：并行批按 id 配对（步骤 0 = 结果A）", (pairSteps.first?["result"] as? String) ?? "", "结果A")
eq("轨迹：并行批按 id 配对（步骤 1 = 结果B）", (pairSteps.last?["result"] as? String) ?? "", "结果B")

// 悬空 tool_calls：应用在工具执行中途被杀的崩溃形态 —— 悬空调用必须剥掉，
// 否则之后每一轮请求都被服务端拒绝（会话报废）。
let dangling: [AgentMessage] = [
    msg(.user, "悬空测试"),
    {
        var a = AgentMessage(role: .assistant, content: "")
        a.toolCalls = [AgentToolCall(id: "call_dangling", type: "function",
                                     function: .init(name: "readFile", arguments: "{\"path\":\"x\"}"))]
        return a
    }(),
]
let sanitized = ContextCompaction.droppingDanglingToolCalls(dangling)
check("悬空：剥掉 toolCalls", (sanitized.last?.toolCalls ?? []).isEmpty)
eq("悬空：正文保留则不丢消息", sanitized.count, 1)

let emptyAssistant = msg(.assistant, "", p: 0)
let stripped = ContextCompaction.droppingDanglingToolCalls([
    msg(.user, "q"),
    { var a = AgentMessage(role: .assistant, content: ""); a.toolCalls = [AgentToolCall(id: "d", type: "function", function: .init(name: "x", arguments: ""))]; return a }(),
])
eq("悬空：正文为空 → 整条丢弃", stripped.count, 1)
check("悬空：正常会话不受影响", ContextCompaction.droppingDanglingToolCalls([
    msg(.user, "q"),
    msg(.assistant, "a", model: "m", p: 10, c: 1),
]).count == 2)

// ---------- 云同步：书签展平/合并（BookmarkSync） ----------

func bm(_ title: String, url: String? = nil, id: UUID = UUID(), at: Date? = Date(),
        children: [Bookmark] = []) -> Bookmark {
    var node = Bookmark(id: id, title: title, url: url, children: children)
    node.updatedAt = at
    return node
}

func wire(_ id: UUID, _ at: Date, deleted: Bool = false,
          payload: BookmarkSyncPayload? = nil) -> SyncWireItem<BookmarkSyncPayload> {
    SyncWireItem(clientId: id.uuidString, clientUpdatedAt: at, deleted: deleted,
                 payload: payload, updatedAt: nil)
}

do {
    let folderID = UUID()
    let leafID = UUID()
    // flatten：结构 → parentID + sort
    let tree = [bm("Folder", id: folderID, children: [bm("GH", url: "https://g", id: leafID)])]
    let flat = BookmarkSync.flatten(tree)
    eq("flatten 数量", flat.count, 2)
    check("flatten 根无父", flat[0].payload.parentID == nil)
    eq("flatten 子的父", flat[1].payload.parentID, folderID)
    eq("flatten 子的 sort", flat[1].payload.sort, 0)

    // merge：新节点插入（父存在）
    let now = Date()
    let mergedInsert = BookmarkSync.merge(
        base: [bm("Folder", id: folderID)],
        remote: [wire(leafID, now, payload: .init(id: leafID, parentID: folderID, title: "New", url: "https://n", sort: 0))]
    )
    eq("merge 插入到父下", mergedInsert[0].children.count, 1)
    eq("merge 插入标题", mergedInsert[0].children[0].title, "New")
    check("merge 插入带时间戳", mergedInsert[0].children[0].updatedAt != nil)

    // LWW：本地更新 → 忽略远端旧改动
    let local = [bm("Local", url: "https://l", id: leafID, at: now)]
    let older = wire(leafID, now.addingTimeInterval(-10),
                     payload: .init(id: leafID, parentID: nil, title: "Remote-old", url: nil, sort: 0))
    eq("LWW 本地新 → 忽略", BookmarkSync.merge(base: local, remote: [older])[0].title, "Local")

    // LWW：远端更新 → 盖写标题/URL/时间戳
    let newerAt = now.addingTimeInterval(10)
    let newer = wire(leafID, newerAt,
                     payload: .init(id: leafID, parentID: nil, title: "Remote-new", url: "https://r", sort: 0))
    let wonOver = BookmarkSync.merge(base: local, remote: [newer])
    eq("LWW 远端新 → 盖写", wonOver[0].title, "Remote-new")
    eq("LWW 采纳远端时间戳", wonOver[0].updatedAt ?? .distantPast, newerAt)

    // tombstone：新删除 → 移除；同刻删除 → 移除（收敛）；旧删除 → 保留
    let newerDeleted = BookmarkSync.merge(
        base: local, remote: [wire(leafID, newerAt, deleted: true)])
    check("tombstone 新删除 → 节点消失", BookmarkSync.flatten(newerDeleted).isEmpty)
    let equalDeleted = BookmarkSync.merge(
        base: local, remote: [wire(leafID, now, deleted: true)])
    check("tombstone 同刻删除 → 也移除（收敛）", BookmarkSync.flatten(equalDeleted).isEmpty)
    let olderDeleted = BookmarkSync.merge(
        base: local, remote: [wire(leafID, now.addingTimeInterval(-10), deleted: true)])
    eq("tombstone 旧删除 → 保留", BookmarkSync.flatten(olderDeleted).count, 1)

    // reparent：从 F1 移到 F2
    let f1 = UUID(), f2 = UUID()
    let twoFolders = [
        bm("F1", id: f1, children: [bm("L", url: "u", id: leafID, at: now)]),
        bm("F2", id: f2),
    ]
    let move = BookmarkSync.merge(
        base: twoFolders,
        remote: [wire(leafID, newerAt,
                      payload: .init(id: leafID, parentID: f2, title: "L", url: "u", sort: 0))])
    check("reparent 原父空了", move[0].children.isEmpty)
    eq("reparent 新父收到", move[1].children.first?.id ?? UUID(), leafID)

    // 环守卫：payload.parentID 指向自身 → 只更新字段，结构不变
    let cycle = BookmarkSync.merge(
        base: [bm("F", id: f1, children: [bm("C", id: leafID, at: now)])],
        remote: [wire(leafID, newerAt,
                      payload: .init(id: leafID, parentID: leafID, title: "C2", url: nil, sort: 0))])
    eq("环守卫 结构不变", cycle[0].children.count, 1)
    eq("环守卫 字段仍更新", cycle[0].children[0].title, "C2")

    // 父缺失兜底：远端节点挂在未知父下 → 落根
    let unknownParent = UUID()
    let orphan = BookmarkSync.merge(
        base: [],
        remote: [wire(leafID, now,
                      payload: .init(id: leafID, parentID: unknownParent, title: "Orphan", url: nil, sort: 0))])
    eq("父缺失 → 落根", orphan.count, 1)
    check("父缺失 → 根节点可辨", orphan[0].id == leafID)

    // 孤儿归位：父在本批次晚于子出现（时钟乱序），批次结束前必须挂回
    let lateParent = UUID(), earlyChild = UUID()
    let reordered = BookmarkSync.merge(
        base: [],
        remote: [
            wire(earlyChild, now,
                 payload: .init(id: earlyChild, parentID: lateParent, title: "C", url: nil, sort: 0)),
            wire(lateParent, now.addingTimeInterval(1),
                 payload: .init(id: lateParent, parentID: nil, title: "P", url: nil, sort: 0)),
        ])
    eq("孤儿归位 根上只有父", reordered.count, 1)
    eq("孤儿归位 父的 id", reordered[0].id, lateParent)
    eq("孤儿归位 子挂回父下", reordered[0].children.first?.id ?? UUID(), earlyChild)
}

// ---------- 云同步：时间编解码 + 线路 DTO ----------

do {
    let date = Date(timeIntervalSince1970: 1_790_256_000.123456)
    let encoded = SyncDate.encode(date)
    check("encode 固定 6 位小数", encoded.hasSuffix(".123456"))
    if let back = SyncDate.parse(encoded) {
        check("parse 回环 ≤1µs", abs(back.timeIntervalSince(date)) < 0.000_001)
    } else {
        check("parse 回环", false)
    }
    check("parse 无小数位", SyncDate.parse("2026-09-24T12:00:00") != nil)
    check("parse 拒绝非时间", SyncDate.parse("yesterday") == nil)

    let json = #"{"id":123,"client_id":"X","client_updated_at":"2026-09-24T12:00:00.123456","deleted":false,"payload":{"id":"11111111-2222-3333-4444-555555555555","parent_id":null,"title":"t","url":null,"sort":2},"updated_at":"2026-09-24T12:00:00.5"}"#
    let item = try? SyncJSON.makeDecoder().decode(
        SyncWireItem<BookmarkSyncPayload>.self, from: Data(json.utf8))
    check("wire 解码", item != nil)
    eq("wire payload sort", item?.payload?.sort, 2)
    eq("wire 服务端行 id", item?.id, 123)
    check("wire 时间解析（6 位小数）", item?.clientUpdatedAt != nil)
    check("wire 游标原文保留", item?.updatedAt == "2026-09-24T12:00:00.5")
    if let item {
        let data = try? SyncJSON.makeEncoder().encode(item)
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("wire 编码含 snake_case 键", text.contains("\"client_id\"") && text.contains("\"client_updated_at\""))
    }
    // updatedAt = nil（push 请求形态）编码时必须整个键省略
    let pushShape = wire(UUID(), Date(), payload: .init(id: UUID(), parentID: nil, title: "t", url: nil, sort: 0))
    if let data = try? SyncJSON.makeEncoder().encode(pushShape),
       let text = String(data: data, encoding: .utf8) {
        check("wire 编码 nil updated_at 省略", !text.contains("\"updated_at\""))
    } else {
        check("wire 编码 nil updated_at 省略", false)
    }
}

// ---------- 云同步：平铺列表域（FlatSyncMerge + 快拨/阅读列表） ----------

do {
    let now = Date()
    // 通用核心：LWW 盖写 / 旧忽略 / 同刻删除收敛 / 新增追加
    struct Row { var id: String; var name: String; var updatedAt: Date? }
    let base = [Row(id: "a", name: "local", updatedAt: now)]
    let older = SyncWireItem<QuickDialSyncPayload>.init(
        clientId: "a", clientUpdatedAt: now.addingTimeInterval(-5), deleted: false,
        payload: QuickDialSyncPayload(id: UUID(), title: "t", url: "u", icon: "i", sort: 0),
        updatedAt: nil)
    let mergedOlder = FlatSyncMerge.merge(
        base: base, remote: [older],
        idOf: { $0.id }, updatedAtOf: { $0.updatedAt },
        make: { _, payload, at in Row(id: "x", name: payload.title, updatedAt: at) },
        update: { row, payload, at in row.name = payload.title; row.updatedAt = at })
    eq("平铺 LWW 旧忽略", mergedOlder[0].name, "local")

    let newer = SyncWireItem<QuickDialSyncPayload>.init(
        clientId: "a", clientUpdatedAt: now.addingTimeInterval(5), deleted: false,
        payload: QuickDialSyncPayload(id: UUID(), title: "remote", url: "u", icon: "i", sort: 0),
        updatedAt: nil)
    let mergedNewer = FlatSyncMerge.merge(
        base: base, remote: [newer],
        idOf: { $0.id }, updatedAtOf: { $0.updatedAt },
        make: { _, payload, at in Row(id: "x", name: payload.title, updatedAt: at) },
        update: { row, payload, at in row.name = payload.title; row.updatedAt = at })
    eq("平铺 LWW 新盖写", mergedNewer[0].name, "remote")

    let equalDelete = SyncWireItem<QuickDialSyncPayload>.init(
        clientId: "a", clientUpdatedAt: now, deleted: true, payload: nil, updatedAt: nil)
    check("平铺 同刻删除收敛", FlatSyncMerge.merge(
        base: base, remote: [equalDelete],
        idOf: { $0.id }, updatedAtOf: { $0.updatedAt },
        make: { _, _, _ in nil }, update: { _, _, _ in }).isEmpty)

    // 快拨：合并 + sort 重排 + 新增落位
    let dialA = UUID(), dialB = UUID()
    let dials = [QuickDial(id: dialA, title: "A", url: "a", sort: 0, updatedAt: now)]
    let remoteAt = now.addingTimeInterval(5)
    let remoteDials = [
        SyncWireItem<QuickDialSyncPayload>.init(
            clientId: dialB.uuidString, clientUpdatedAt: remoteAt, deleted: false,
            payload: QuickDialSyncPayload(id: dialB, title: "B", url: "b", icon: "i", sort: 0), updatedAt: nil),
        SyncWireItem<QuickDialSyncPayload>.init(
            clientId: dialA.uuidString, clientUpdatedAt: remoteAt, deleted: false,
            payload: QuickDialSyncPayload(id: dialA, title: "A", url: "a", icon: "i", sort: 1), updatedAt: nil),
    ]
    let dialMerged = QuickDialSync.merge(base: dials, remote: remoteDials)
    eq("快拨 数量", dialMerged.count, 2)
    eq("快拨 sort 重排（B 在 A 前）", dialMerged[0].id, dialB)
    eq("快拨 A 顺延", dialMerged[1].sort, 1)

    // 阅读列表：合并 + isRead 盖写
    let itemID = UUID()
    let savedAt = now.addingTimeInterval(-60)
    let items = [ReadingListItem(id: itemID, title: "T", url: "u", savedDate: savedAt,
                                 isRead: false, updatedAt: now)]
    let remoteItem = SyncWireItem<ReadingListSyncPayload>.init(
        clientId: itemID.uuidString, clientUpdatedAt: now.addingTimeInterval(5), deleted: false,
        payload: ReadingListSyncPayload(id: itemID, title: "T2", url: "u", savedDate: savedAt, isRead: true),
        updatedAt: nil)
    let itemMerged = ReadingListSync.merge(base: items, remote: [remoteItem])
    eq("阅读列表 标题盖写", itemMerged[0].title, "T2")
    eq("阅读列表 已读盖写", itemMerged[0].isRead, true)
    check("阅读列表 时间戳采纳", itemMerged[0].updatedAt == now.addingTimeInterval(5))

    // 阅读列表：远端新条目（本地空）
    let freshID = UUID()
    let fresh = SyncWireItem<ReadingListSyncPayload>.init(
        clientId: freshID.uuidString, clientUpdatedAt: now, deleted: false,
        payload: ReadingListSyncPayload(id: freshID, title: "Fresh", url: "f", savedDate: now, isRead: false),
        updatedAt: nil)
    let freshMerged = ReadingListSync.merge(base: [], remote: [fresh])
    eq("阅读列表 新增", freshMerged.count, 1)
    check("阅读列表 新增带时间戳", freshMerged[0].updatedAt != nil)
}

// ---------- 云同步：设置 KV 载荷编解码 ----------

do {
    let values: [SettingsSyncValue] = [.string("https://example.com"), .bool(true), .number(1.25)]
    let data = try SyncJSON.makeEncoder().encode(values)
    let back = try SyncJSON.makeDecoder().decode([SettingsSyncValue].self, from: data)
    eq("设置值 roundtrip", back, values)
    // 类型标签保持：bool 不被吃成 number
    let raw = #"{"b":true}"#
    let one = try SyncJSON.makeDecoder().decode(SettingsSyncValue.self, from: Data(raw.utf8))
    eq("设置值 bool 标签", one, .bool(true))
    let bad = try? SyncJSON.makeDecoder().decode(SettingsSyncValue.self, from: Data(#"{"x":1}"#.utf8))
    check("设置值 未知类型报错", bad == nil)
}

// ---------- 云同步：E2E 加密（SyncCrypto） ----------

do {
    let master = SyncCrypto.generateMasterKey()
    check("主密钥 base64 可解析且 32 字节", SyncCrypto.isValidMasterKeyBase64(master))
    check("拒绝非 base64", !SyncCrypto.isValidMasterKeyBase64("not-base64!!"))
    check("拒绝错误长度", !SyncCrypto.isValidMasterKeyBase64(Data(repeating: 1, count: 16).base64EncodedString()))

    let fingerprint: String
    do {
        fingerprint = try SyncCrypto.fingerprint(masterKeyBase64: master)
    } catch {
        print("fingerprint 抛错: \(error)")
        throw error
    }
    eq("指纹 16 位 hex", fingerprint.count, 16)
    eq("指纹确定", try SyncCrypto.fingerprint(masterKeyBase64: master), fingerprint)
    check("不同密钥指纹不同",
          try SyncCrypto.fingerprint(masterKeyBase64: SyncCrypto.generateMasterKey()) != fingerprint)

    // 载荷加解密 roundtrip(书签:含真实 id)
    let nodeID = UUID()
    let payload = BookmarkSyncPayload(id: nodeID, parentID: nil, title: "秘密书签", url: "https://s", sort: 3)
    let envelope: SyncEncryptedPayload
    do {
        envelope = try SyncCrypto.encrypt(payload, domain: .bookmarks, masterKeyBase64: master)
    } catch {
        print("encrypt 抛错: \(error)")
        throw error
    }
    eq("信封版本", envelope.v, 1)
    check("密文不含明文", !envelope.ct.contains("秘密书签"))
    let roundtrip = try SyncCrypto.decrypt(envelope, domain: .bookmarks, masterKeyBase64: master, as: BookmarkSyncPayload.self)
    eq("解密回环", roundtrip, payload)
    // 换域密钥解密 → 认证失败
    check("跨域解密被拒", (try? SyncCrypto.decrypt(envelope, domain: .quickDials, masterKeyBase64: master, as: BookmarkSyncPayload.self)) == nil)
    // 换主密钥解密 → 认证失败
    let other = SyncCrypto.generateMasterKey()
    check("错密钥解密被拒", (try? SyncCrypto.decrypt(envelope, domain: .bookmarks, masterKeyBase64: other, as: BookmarkSyncPayload.self)) == nil)

    // client_id HMAC:确定性、跨设备一致、跨域不同、不可反推但可重算匹配
    let realID = "0F0E3D2C-1111-2222-3333-445566778899"
    let hmac1 = SyncCrypto.hmacClientID(realID, domain: .bookmarks, masterKeyBase64: master)
    let hmac2 = SyncCrypto.hmacClientID(realID, domain: .bookmarks, masterKeyBase64: master)
    eq("client_id HMAC 确定", hmac1, hmac2)
    check("client_id HMAC ≤64 字符(服务端列上限)", hmac1.count <= 64)
    check("client_id 跨域不同",
          SyncCrypto.hmacClientID(realID, domain: .settings, masterKeyBase64: master) != hmac1)
    check("不同真实 id 不同 HMAC",
          SyncCrypto.hmacClientID(UUID().uuidString, domain: .bookmarks, masterKeyBase64: master) != hmac1)
}

// ---------- 云同步：Agent 记忆域（AgentMemorySync） ----------

do {
    let now = Date()
    var profile = UserProfile()
    profile.name = "测试者"
    var fact = MemoryFact(content: "偏好简洁回复", category: "preference")
    fact.updatedAt = now
    let summary = ConversationSummary(conversationId: UUID(), summary: "一段摘要")

    // 事实插入 + 画像 LWW
    let base = AgentMemorySnapshot(profile: profile, profileUpdatedAt: now,
                                   facts: [], summaries: [])
    let applied = AgentMemorySync.apply(base: base, changes: [
        AgentMemoryChange(realID: fact.id.uuidString, clientUpdatedAt: now,
                          deleted: false, item: .fact(fact)),
        AgentMemoryChange(realID: "profile", clientUpdatedAt: now.addingTimeInterval(5),
                          deleted: false,
                          item: .profile(UserProfile(name: "新名字", language: "zh"))),
    ])
    eq("记忆 事实插入", applied.facts.count, 1)
    eq("记忆 画像盖写", applied.profile.name, "新名字")
    eq("记忆 画像戳推进", applied.profileUpdatedAt, now.addingTimeInterval(5))

    // 事实 LWW：旧改动忽略
    let stale = AgentMemorySync.apply(base: applied, changes: [
        AgentMemoryChange(realID: fact.id.uuidString,
                          clientUpdatedAt: now.addingTimeInterval(-5),
                          deleted: true, item: nil),
    ])
    eq("记忆 旧删除被忽略", stale.facts.count, 1)

    // 新删除生效（tombstone）
    let deleted = AgentMemorySync.apply(base: applied, changes: [
        AgentMemoryChange(realID: fact.id.uuidString,
                          clientUpdatedAt: now.addingTimeInterval(10),
                          deleted: true, item: nil),
    ])
    eq("记忆 新删除生效", deleted.facts.count, 0)

    // 摘要插入 + LWW 覆盖
    let sumID = UUID()
    let withSummary = AgentMemorySync.apply(base: deleted, changes: [
        AgentMemoryChange(realID: sumID.uuidString, clientUpdatedAt: now,
                          deleted: false,
                          item: .summary(ConversationSummary(conversationId: summary.conversationId,
                                                             summary: "旧摘要"))),
    ])
    let overwritten = AgentMemorySync.apply(base: withSummary, changes: [
        AgentMemoryChange(realID: sumID.uuidString, clientUpdatedAt: now.addingTimeInterval(9),
                          deleted: false,
                          item: .summary(ConversationSummary(conversationId: summary.conversationId,
                                                             summary: "新摘要"))),
    ])
    eq("记忆 摘要盖写", overwritten.summaries[0].summary, "新摘要")
}

// ---------- 云同步：E2E 密钥托管（PBKDF2/wrap） ----------

do {
    let password = "correct-horse-battery"
    let salt = SyncCrypto.generateSalt()
    let dek = SyncCrypto.generateMasterKey()

    // KEK 确定 + wrap/unwrap 回环
    let wrapped = try SyncCrypto.wrapDEK(dekBase64: dek, password: password, saltBase64: salt)
    check("托管信封可解析", wrapped.contains("\"pbkdf2-sha256\""))
    let restored = try SyncCrypto.unwrapDEK(wrapped, password: password, saltBase64: salt)
    eq("托管 DEK 回环", restored, dek)
    // 错误密码 → 解包认证失败
    check("错密码解包被拒",
          (try? SyncCrypto.unwrapDEK(wrapped, password: "wrong", saltBase64: salt)) == nil)
    // 错误盐 → 解包认证失败
    check("错盐解包被拒",
          (try? SyncCrypto.unwrapDEK(wrapped, password: password, saltBase64: SyncCrypto.generateSalt())) == nil)
    // KEK 确定(同密码同盐同派生)
    let kek1 = try SyncCrypto.deriveKEK(password: password, saltBase64: salt)
    let kek2 = try SyncCrypto.deriveKEK(password: password, saltBase64: salt)
    eq("KEK 确定", kek1.withUnsafeBytes { Data($0) }, kek2.withUnsafeBytes { Data($0) })
    // 盐唯一
    check("盐唯一", SyncCrypto.generateSalt() != SyncCrypto.generateSalt())
}

// ---------- 汇总 ----------

// ---------- 汇总 ----------// ---------- 汇总 ----------// ---------- 汇总 ----------

print("\n纯逻辑单测：\(count) 项，失败 \(failures.count) 项")
if !failures.isEmpty {
    print("失败清单：")
    for f in failures { print("  - \(f)") }
    exit(1)
}
print("全部通过 ✓")
