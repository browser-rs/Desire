import Foundation

/// 密码健康（v0.8.4，纯逻辑）：扫已保存密码——弱密码/重复/过期；全部本地判定，
/// 不上传任何数据。结果供面板展示与 Agent 报告。
///
/// Foundation-only，进 harness。
nonisolated enum PasswordHealth {
    enum Issue: String, Comparable {
        case weak
        case duplicate
        case old

        static func < (lhs: Issue, rhs: Issue) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .weak: String(localized: "Weak password")
            case .duplicate: String(localized: "Duplicate password")
            case .old: String(localized: "Not changed in 180+ days")
            }
        }
    }

    struct Finding: Equatable {
        var entryID: UUID
        var domain: String
        var username: String
        var issues: [Issue]
        var detail: String
    }

    struct Report: Equatable {
        var findings: [Finding]
        var totalEntries: Int
        var checkedAt: Date

        var healthyCount: Int { totalEntries - findings.count }
        var weakCount: Int { findings.filter { $0.issues.contains(.weak) }.count }
        var duplicateCount: Int { findings.filter { $0.issues.contains(.duplicate) }.count }
        var oldCount: Int { findings.filter { $0.issues.contains(.old) }.count }
        var isClean: Bool { findings.isEmpty }
    }

    static let minPasswordLength = 8
    static let oldThresholdDays = 180
    /// 常见弱密码模式（小写比对）。
    static let commonPatterns: [String] = [
        "password", "123456", "qwerty", "letmein", "welcome",
        "admin", "login", "abc123", "monkey", "dragon",
    ]

    static func assess(entries: [PasswordEntry], now: Date = Date()) -> Report {
        // 重复检测：密码值相同（跨域名）。
        var byPassword: [String: [PasswordEntry]] = [:]
        for entry in entries {
            byPassword[entry.password, default: []].append(entry)
        }
        let duplicatePasswords = Set(byPassword.filter { $0.value.count > 1 }.keys)

        var findings: [Finding] = []
        for entry in entries {
            var issues: [Issue] = []
            var details: [String] = []

            if isWeak(entry.password) {
                issues.append(.weak)
                details.append(weakReason(entry.password))
            }
            if duplicatePasswords.contains(entry.password) && entries.count > 1 {
                issues.append(.duplicate)
                let others = byPassword[entry.password]!
                    .filter { $0.id != entry.id }
                    .prefix(3)
                    .map { $0.domain }
                    .joined(separator: ", ")
                details.append(String(format: String(localized: "Same password also on %@"), others))
            }
            let age = now.timeIntervalSince(entry.createdAt) / 86_400
            if age >= Double(oldThresholdDays) {
                issues.append(.old)
                details.append(String(format: String(localized: "%lld days since created"), Int(age)))
            }

            if !issues.isEmpty {
                findings.append(Finding(
                    entryID: entry.id, domain: entry.domain, username: entry.username,
                    issues: issues.sorted(), detail: details.joined(separator: " · ")))
            }
        }
        findings.sort { ($0.domain, $0.username) < ($1.domain, $1.username) }
        return Report(findings: findings, totalEntries: entries.count, checkedAt: now)
    }

    static func isWeak(_ password: String) -> Bool {
        if password.count < minPasswordLength { return true }
        let lower = password.lowercased()
        for pattern in commonPatterns where lower.contains(pattern) { return true }
        // 纯数字或纯字母（无混合）也算弱。
        let hasDigit = password.contains { $0.isNumber }
        let hasLetter = password.contains { $0.isLetter }
        if !hasDigit || !hasLetter { return true }
        return false
    }

    static func weakReason(_ password: String) -> String {
        if password.count < minPasswordLength {
            return String(format: String(localized: "Only %lld characters"), password.count)
        }
        let lower = password.lowercased()
        for pattern in commonPatterns where lower.contains(pattern) {
            return String(format: String(localized: "Contains common pattern '%@'"), pattern)
        }
        let hasDigit = password.contains { $0.isNumber }
        let hasLetter = password.contains { $0.isLetter }
        if !hasDigit { return String(localized: "No digits") }
        if !hasLetter { return String(localized: "No letters") }
        return ""
    }
}
