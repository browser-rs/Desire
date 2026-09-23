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

// ---------- 汇总 ----------// ---------- 汇总 ----------

print("\n纯逻辑单测：\(count) 项，失败 \(failures.count) 项")
if !failures.isEmpty {
    print("失败清单：")
    for f in failures { print("  - \(f)") }
    exit(1)
}
print("全部通过 ✓")
