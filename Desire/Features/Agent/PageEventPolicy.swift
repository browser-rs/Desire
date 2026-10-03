import Foundation

/// DPP 事件层的可测纯逻辑（PageEventHub 的策略部分——hub 本体挂在
/// AgentScheduler/UserDefaults 上，进不了纯逻辑单测 harness，见 tests/run.sh）。
/// 新增事件策略先落这里 + tests/main.swift 用例，hub 只做接线。
enum PageEventPolicy {
    /// 同 host + 同事件名的防抖间隔。
    static let debounceInterval: TimeInterval = 3.0
    /// 单 host 滑动限频窗口。
    static let rateWindow: TimeInterval = 60
    /// 窗口内单 host 事件上限。
    static let maxPerHostPerWindow = 10

    static let modeOff = "off"
    static let modeDraft = "draft"
    static let modeAuto = "auto"

    static func isValidMode(_ mode: String) -> Bool {
        [modeOff, modeDraft, modeAuto].contains(mode)
    }

    /// 滑动限频窗口：过滤掉窗口外的时间戳；窗口内已达上限返回 nil（拒收），
    /// 否则返回应记录的数组（调用方 append 新事件后保存）。
    static func filterRateWindow(
        _ times: [Date], now: Date,
        window: TimeInterval = PageEventPolicy.rateWindow,
        limit: Int = PageEventPolicy.maxPerHostPerWindow
    ) -> [Date]? {
        let active = times.filter { now.timeIntervalSince($0) <= window }
        guard active.count < limit else { return nil }
        return active
    }

    /// 事件驱动回合的提示词。注意 auto 档**不**承诺免审批——outbound/danger
    /// 的强制审批在闸门（effectiveRisk），不随档位放水。
    static func eventPrompt(
        host: String, eventName: String, detail: [String: String],
        timestamp: Date, mode: String
    ) -> String {
        var lines = [
            "[DPP Event] Page event triggered on \(host):",
            "- Event: \(eventName)",
            "- Time: \(timestamp.formatted())"
        ]
        for (key, value) in detail.sorted(by: { $0.key < $1.key }) {
            lines.append("- \(key): \(value)")
        }
        switch mode {
        case modeAuto:
            lines.append("Act on this event using the page's declared actions. Note: outbound/danger actions still require user approval.")
        case modeDraft:
            lines.append("Analyze this event and prepare a response using the page's declared actions. Show me what you would do before executing outbound actions.")
        default:
            break
        }
        return lines.joined(separator: "\n")
    }
}
