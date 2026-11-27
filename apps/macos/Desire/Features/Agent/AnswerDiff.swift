import Foundation

/// 自评修订的前后对照（v0.8.81 批 3）。行级 LCS diff，纯 Foundation——
/// harness 可单测；面板只负责把 `.removed/.added` 染色。
///
/// 规模保护：答案通常几十行，但模型偶尔吐上千行。超过 `maxCells` 的
/// LCS 表会把内存和时间拖垮，此时退化为"整段替换"的前后截断视图——
/// 宁可少标几行相同内容，也不让 UI 卡死。
nonisolated enum AnswerDiff {
    enum Kind: Equatable, Sendable {
        case same
        case removed
        case added
        /// 因规模保护被省略的中间段。
        case omitted
    }

    struct Row: Equatable, Sendable {
        let kind: Kind
        let text: String
    }

    struct Result: Equatable, Sendable {
        let rows: [Row]
        let added: Int
        let removed: Int
        var hasChanges: Bool { added > 0 || removed > 0 }
    }

    static let maxCells = 160_000
    static let maxDisplayLines = 600

    static func diff(before: String, after: String) -> Result {
        let old = lines(before)
        let new = lines(after)
        guard !old.isEmpty || !new.isEmpty else {
            return Result(rows: [], added: 0, removed: 0)
        }
        if old.count * new.count > maxCells {
            return coarse(before: old, after: new)
        }

        // 经典 LCS 表（(m+1)×(n+1)）。下标 (i, j) = 前 i 行 vs 前 j 行的 LCS 长度。
        let m = old.count
        let n = new.count
        var table = [Int](repeating: 0, count: (m + 1) * (n + 1))
        for i in stride(from: m - 1, through: 0, by: -1) {
            for j in stride(from: n - 1, through: 0, by: -1) {
                table[i * (n + 1) + j] = old[i] == new[j]
                    ? table[(i + 1) * (n + 1) + j + 1] + 1
                    : max(table[(i + 1) * (n + 1) + j], table[i * (n + 1) + j + 1])
            }
        }

        var rows: [Row] = []
        var added = 0
        var removed = 0
        var i = 0
        var j = 0
        while i < m, j < n {
            if old[i] == new[j] {
                rows.append(Row(kind: .same, text: old[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * (n + 1) + j] >= table[i * (n + 1) + j + 1] {
                rows.append(Row(kind: .removed, text: old[i]))
                removed += 1
                i += 1
            } else {
                rows.append(Row(kind: .added, text: new[j]))
                added += 1
                j += 1
            }
        }
        while i < m {
            rows.append(Row(kind: .removed, text: old[i]))
            removed += 1
            i += 1
        }
        while j < n {
            rows.append(Row(kind: .added, text: new[j]))
            added += 1
            j += 1
        }
        return Result(rows: capped(rows), added: added, removed: removed)
    }

    /// 前后各保留一段、中间标省略——超大答案的可读折中。
    private static func coarse(before: [String], after: [String]) -> Result {
        // 中间省略行本身占一行；head 各取一半，总数不超 maxDisplayLines。
        let headCount = max(1, (maxDisplayLines - 1) / 2)
        let beforeHead = before.prefix(headCount)
        let afterHead = after.prefix(headCount)
        var rows: [Row] = beforeHead.map { Row(kind: .removed, text: $0) }
        if before.count > headCount || after.count > headCount {
            rows.append(Row(kind: .omitted, text: ""))
        }
        rows.append(contentsOf: afterHead.map { Row(kind: .added, text: $0) })
        return Result(rows: rows, added: afterHead.count, removed: beforeHead.count)
    }

    /// 只截断**显示行**，计数仍按全文（卡片上"新增 X 行/删除 Y 行"不撒谎）。
    private static func capped(_ rows: [Row]) -> [Row] {
        guard rows.count > maxDisplayLines else { return rows }
        let head = Array(rows.prefix(maxDisplayLines - 1))
        return head + [Row(kind: .omitted, text: "")]
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
