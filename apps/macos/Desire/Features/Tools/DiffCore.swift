import Foundation

/// 文本行对比（LCS）——纯逻辑，进 harness。
nonisolated enum DiffCore {
    enum Kind: String, Sendable {
        case equal
        case insert
        case delete
    }

    struct Row: Equatable, Sendable {
        var kind: Kind
        var text: String
        var oldLine: Int?
        var newLine: Int?
    }

    /// 行级 diff：删除行在前、插入行在后的经典排布；超过 maxLines 只比较前缀。
    static func diff(old: String, new: String, maxLines: Int = 600) -> [Row] {
        var oldLines = old.components(separatedBy: "\n")
        var newLines = new.components(separatedBy: "\n")
        var truncated = false
        if oldLines.count > maxLines {
            oldLines = Array(oldLines.prefix(maxLines))
            truncated = true
        }
        if newLines.count > maxLines {
            newLines = Array(newLines.prefix(maxLines))
            truncated = true
        }
        let n = oldLines.count
        let m = newLines.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if oldLines[i] == newLines[j] {
                        table[i][j] = table[i + 1][j + 1] + 1
                    } else {
                        table[i][j] = max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
        }
        var rows: [Row] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                rows.append(Row(kind: .equal, text: oldLines[i], oldLine: i + 1, newLine: j + 1))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                rows.append(Row(kind: .delete, text: oldLines[i], oldLine: i + 1, newLine: nil))
                i += 1
            } else {
                rows.append(Row(kind: .insert, text: newLines[j], oldLine: nil, newLine: j + 1))
                j += 1
            }
        }
        while i < n {
            rows.append(Row(kind: .delete, text: oldLines[i], oldLine: i + 1, newLine: nil))
            i += 1
        }
        while j < m {
            rows.append(Row(kind: .insert, text: newLines[j], oldLine: nil, newLine: j + 1))
            j += 1
        }
        if truncated {
            rows.append(Row(kind: .equal, text: "…[truncated to \(maxLines) lines]", oldLine: nil, newLine: nil))
        }
        return rows
    }

    /// 统计各类型行数。
    static func stats(_ rows: [Row]) -> (inserted: Int, deleted: Int, equal: Int) {
        var inserted = 0
        var deleted = 0
        var equal = 0
        for row in rows {
            switch row.kind {
            case .insert: inserted += 1
            case .delete: deleted += 1
            case .equal: equal += 1
            }
        }
        return (inserted, deleted, equal)
    }
}
