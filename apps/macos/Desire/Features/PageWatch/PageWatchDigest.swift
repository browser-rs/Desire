import Foundation

/// 监视摘要（v0.8.0）：把各 PageWatch 的最近变化/告警/错误汇总成一段
/// 确定性文本（不调用模型），供监视中心与桥/通知使用。
nonisolated enum PageWatchDigest {
    struct Summary: Equatable {
        var text: String
        var changed: Int
        var errors: Int
        var alerts: Int
    }

    static func make(watches: [PageWatch], now: Date = Date(),
                     lookback: TimeInterval = 86_400) -> Summary {
        let cutoff = now.addingTimeInterval(-lookback)
        let changed = watches.filter { ($0.lastChangedAt ?? .distantPast) >= cutoff }
        let alerts = watches.filter { ($0.lastAlertAt ?? .distantPast) >= cutoff }
        let errors = watches.filter { ($0.lastError ?? "").isEmpty == false }

        var lines: [String] = []
        let sorted = watches.sorted {
            max($0.lastChangedAt ?? .distantPast, $0.lastAlertAt ?? .distantPast)
                > max($1.lastChangedAt ?? .distantPast, $1.lastAlertAt ?? .distantPast)
        }
        for watch in sorted {
            let alertRecent = (watch.lastAlertAt ?? .distantPast) >= cutoff
            let changeRecent = (watch.lastChangedAt ?? .distantPast) >= cutoff
            guard alertRecent || changeRecent || (watch.lastError ?? "").isEmpty == false else {
                continue
            }
            var line = "• \(watch.name)"
            if let error = watch.lastError, !error.isEmpty {
                line += " — error: \(error)"
            } else if alertRecent, let alert = watch.lastAlert, !alert.isEmpty {
                line += " — alert: \(alert)"
            } else if changeRecent {
                line += " — changed \(watch.changeCount)×"
                if let value = watch.latestValue {
                    line += ", value \(format(value))"
                }
                let analysis = (watch.lastAnalysis ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !analysis.isEmpty {
                    line += " — \(String(analysis.prefix(140)))"
                }
            }
            lines.append(line)
        }

        let header = "Page Watch — \(watches.count) watched, \(changed.count) changed"
            + (alerts.isEmpty ? "" : ", \(alerts.count) alert(s)")
            + (errors.isEmpty ? "" : ", \(errors.count) error(s)")
            + " in the last 24h."
        let body = lines.isEmpty ? "No changes in the last 24h." : lines.joined(separator: "\n")
        return Summary(text: header + "\n" + body,
                       changed: changed.count,
                       errors: errors.count,
                       alerts: alerts.count)
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.2f", value)
    }
}
