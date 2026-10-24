import Foundation

/// 文件整理作业（v0.8.4，纯逻辑）：给定目录扫描结果 + 整理规则，
/// 计算移动计划；Agent 预览确认后执行（move 操作在工具层）。
///
/// Foundation-only，进 harness。
nonisolated enum FileOrganizerPlan {
    enum Rule: Codable, Equatable {
        /// 按文件扩展名分到子目录（如 pdf → PDF/）。
        case byExtension
        /// 按修改日期分到年-月子目录（如 2026-10/）。
        case byDate
        /// 文件名匹配正则的移到指定子目录。
        case regex(pattern: String, destination: String)

        var label: String {
            switch self {
            case .byExtension: String(localized: "By file type")
            case .byDate: String(localized: "By date (year-month)")
            case .regex(let pattern, let dest): String(format: String(localized: "Pattern '%@' → %@"), pattern, dest)
            }
        }
    }

    struct Move: Equatable {
        var fileName: String
        var fromDirectory: String
        var toDirectory: String
    }

    struct Plan: Equatable {
        var moves: [Move]
        var skipped: [String]
        var rule: Rule

        var isEmpty: Bool { moves.isEmpty }
    }

    /// 从文件名 + 修改日期 + 扩展名集合计算移动计划。
    /// - Parameters:
    ///   - files: 目录扫描结果（文件名 + 修改日期），不含目录本身。
    ///   - rules: 依次尝试；第一个命中的规则决定目标。
    ///   - root: 根目录路径。
    static func plan(files: [(name: String, modifiedAt: Date)],
                     rules: [Rule], root: String,
                     calendar: Calendar = .current) -> Plan {
        var moves: [Move] = []
        var skipped: [String] = []
        for file in files {
            var destination: String?
            for rule in rules {
                switch rule {
                case .byExtension:
                    let ext = (file.name as NSString).pathExtension.lowercased()
                    guard !ext.isEmpty else { continue }
                    destination = ext.uppercased()
                case .byDate:
                    let comps = calendar.dateComponents([.year, .month], from: file.modifiedAt)
                    guard let y = comps.year, let m = comps.month else { continue }
                    destination = String(format: "%04d-%02d", y, m)
                case .regex(let pattern, let dest):
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    let range = NSRange(file.name.startIndex..., in: file.name)
                    if regex.firstMatch(in: file.name, range: range) != nil {
                        destination = dest
                    }
                }
                if destination != nil { break }
            }
            if let dest = destination, dest != "." {
                moves.append(Move(
                    fileName: file.name,
                    fromDirectory: root,
                    toDirectory: root + "/" + dest))
            } else {
                skipped.append(file.name)
            }
        }
        return Plan(
            moves: moves,
            skipped: skipped,
            rule: rules.first ?? .byExtension)
    }

    /// 移动计划的文本摘要（Agent 回执/预览用）。
    static func summary(_ plan: Plan, maxLines: Int = 10) -> String {
        guard !plan.moves.isEmpty else {
            return String(localized: "No files to organize")
        }
        var lines = plan.moves.prefix(maxLines).map {
            String(format: String(localized: "%@ → %@"), $0.fileName, ($0.toDirectory as NSString).lastPathComponent)
        }
        if plan.moves.count > maxLines {
            lines.append(String(format: String(localized: "…and %lld more"), plan.moves.count - maxLines))
        }
        if !plan.skipped.isEmpty {
            lines.append(String(format: String(localized: "%lld skipped (no matching rule)"), plan.skipped.count))
        }
        return lines.joined(separator: "\n")
    }
}
