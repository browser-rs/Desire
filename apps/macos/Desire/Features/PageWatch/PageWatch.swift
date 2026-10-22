import Foundation

/// A deterministic page monitor: periodically loads a URL in an offscreen
/// webview, extracts text (whole body or a CSS selector), and reports
/// changes. Unlike scheduled agent tasks this never touches a model —
/// cheap enough to run every few minutes forever.
nonisolated struct PageWatch: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    /// Optional CSS selector; nil/empty watches the whole body text.
    var selector: String?
    /// Minimum 5 minutes — tighter intervals are pointless for page watches.
    var intervalMinutes: Int
    var isEnabled: Bool
    var createdAt: Date
    var lastCheckedAt: Date?
    var lastChangedAt: Date?
    /// Normalized text from the previous check (diff baseline), capped.
    var previousText: String?
    var changeCount: Int
    var lastError: String?
    /// v0.7.5 智能监视：变化时让 agent 自动分析（opt-in——每次分析是一个
    /// agent 回合，有 token 成本）。
    var aiAnalysis: Bool?
    /// 最近一次 AI 分析文本（回合结束后写回；面板/桥/通知消费）。
    var lastAnalysis: String?

    // MARK: - 数值盯梢（v0.7.18）

    struct ValuePoint: Codable, Equatable {
        var at: Date
        var value: Double
    }

    /// 从哪个选择器命中的文本里取数（nil = 不盯数值）。与 diff 用的
    /// `selector` 相互独立：可以整页 diff + 单独盯一个价格。
    var numericSelector: String?
    /// 数值历史（每次检查追加一条，封顶 60 条）。
    var valueHistory: [ValuePoint]?
    /// 上/下阈值：**跨线**时告警一次（不重复刷）；都为空 = 只记历史。
    var alertAbove: Double?
    var alertBelow: Double?
    /// 最近一次告警文本 + 时刻（面板/桥/通知/断言消费）。
    var lastAlert: String?
    var lastAlertAt: Date?

    var watchesNumbers: Bool { numericSelector?.isEmpty == false }
    var latestValue: Double? { valueHistory?.last?.value }

    var wantsAIAnalysis: Bool { aiAnalysis == true }
}

/// 数值盯梢的纯逻辑（Foundation-only，进 tests/run.sh）：取数、跨线判定、
/// 历史封顶。口径：取文本里**第一个数字**（千分位逗号去掉；货币符号/单位
/// 前后缀忽略）；只认"穿越"阈值（previous 为 nil = 首测基线，不告警）。
nonisolated enum NumericWatch {
    enum Alert: Equatable {
        case above(Double)
        case below(Double)
    }

    static let historyCap = 60

    static func parseValue(from text: String) -> Double? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            var token = ""
            var j = i
            while j < chars.count, chars[j].isNumber || chars[j] == "," || chars[j] == "." {
                token.append(chars[j])
                j += 1
            }
            while token.hasSuffix(",") || token.hasSuffix(".") { token.removeLast() }
            let cleaned = token.replacingOccurrences(of: ",", with: "")
            return Double(cleaned)
        }
        return nil
    }

    static func crossingAlert(previous: Double?, new: Double,
                              above: Double?, below: Double?) -> Alert? {
        guard let previous else { return nil }
        if let above, previous <= above, new > above { return .above(above) }
        if let below, previous >= below, new < below { return .below(below) }
        return nil
    }

    static func appendCap(_ history: [PageWatch.ValuePoint],
                          _ point: PageWatch.ValuePoint,
                          cap: Int = historyCap) -> [PageWatch.ValuePoint] {
        var out = history
        out.append(point)
        if out.count > cap { out.removeFirst(out.count - cap) }
        return out
    }

    static func alertText(_ alert: Alert, value: Double) -> String {
        let formatted = String(format: "%.2f", value)
        switch alert {
        case .above(let threshold):
            return String(localized: "Rose above \(String(format: "%.2f", threshold)) — now \(formatted)")
        case .below(let threshold):
            return String(localized: "Dropped below \(String(format: "%.2f", threshold)) — now \(formatted)")
        }
    }
}
