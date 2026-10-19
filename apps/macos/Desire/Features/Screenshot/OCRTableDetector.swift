import Foundation

/// OCR 表格重建（v0.7.24）：从 Vision 的逐观察结果（文本 + 归一化包围盒）
/// 里识别**规则表格**并重建 Markdown。纯逻辑（Foundation-only，进 harness）。
///
/// 输入坐标：top-down 归一化（0-1，y 向下）——Vision 原生是左下原点，
/// 调用方（VisionOCRService.tableLines）负责翻转。
///
/// 判定口径（宁可漏、不可错）：行聚类后取"列数一致且 ≥2"的最长连续段，
/// 且各列中心的对齐偏差（中位）≤ 0.05；不满足返回 nil（照常显示纯文本）。
nonisolated enum OCRTableDetector {
    struct Line: Equatable {
        var text: String
        var minX: Double
        var maxX: Double
        var centerY: Double
        var height: Double
    }

    static func markdownTable(from lines: [Line], minRows: Int = 2, minColumns: Int = 2) -> String? {
        let meaningful = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard meaningful.count >= minRows * minColumns else { return nil }

        // 行聚类：按 centerY 排序，中心距 < 0.6×中位行高 的观察并进同一行。
        let sorted = meaningful.sorted { $0.centerY < $1.centerY }
        let heights = sorted.map(\.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let tolerance = max(0.004, medianHeight * 0.6)
        var rows: [[Line]] = []
        for line in sorted {
            if let last = rows.last {
                let mean = last.map(\.centerY).reduce(0, +) / Double(last.count)
                if abs(mean - line.centerY) < tolerance {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }

        // 最长连续段：列数一致且 ≥ minColumns。
        var best: [[Line]] = []
        var current: [[Line]] = []
        var currentCols = 0
        for row in rows {
            let cols = row.count
            if cols >= minColumns && (current.isEmpty || cols == currentCols) {
                if current.isEmpty { currentCols = cols }
                current.append(row)
            } else {
                if current.count > best.count { best = current }
                current = cols >= minColumns ? [row] : []
                currentCols = cols
            }
        }
        if current.count > best.count { best = current }
        guard best.count >= minRows else { return nil }

        // 列对齐：每列中心的中位偏差 ≤ 0.05（OCR 框本身有抖动，给宽松阈值）。
        var columnCenters: [[Double]] = Array(repeating: [], count: currentCols)
        for row in best {
            for (i, cell) in row.sorted(by: { $0.minX < $1.minX }).enumerated() {
                columnCenters[i].append((cell.minX + cell.maxX) / 2)
            }
        }
        let medians = columnCenters.map { values -> Double in
            let s = values.sorted()
            return s[s.count / 2]
        }
        for (i, values) in columnCenters.enumerated() {
            let deviation = values.map { abs($0 - medians[i]) }.sorted()[values.count / 2]
            if deviation > 0.05 { return nil }
        }

        func rowMarkdown(_ row: [Line]) -> String {
            let cells = row.sorted { $0.minX < $1.minX }.map { cell -> String in
                cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "|", with: "\\|")
            }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        var out = [rowMarkdown(best[0]),
                   "| " + Array(repeating: "---", count: currentCols).joined(separator: " | ") + " |"]
        out.append(contentsOf: best.dropFirst().map(rowMarkdown))
        return out.joined(separator: "\n")
    }
}
