import Foundation

/// 表格查看/编辑缓冲（v0.8.12 旗舰 A）纯逻辑：网格数据 + 单元格编辑 +
/// 排序/筛选 + 保存序列化。Foundation-only，进 tests/run.sh。
/// 与 SpreadsheetReader 的分工：Reader 负责"文件 → 行数组"（读），
/// 这里负责"行数组 → 编辑 → 文件"（写与视图状态）。
nonisolated struct SpreadsheetBuffer: Equatable {
    /// rows[0] 为表头（首行冻结语义）。
    var rows: [[String]]
    /// 编辑过的单元格（row, col）——保存提示与"未保存"角标用。
    private(set) var dirtyCells: Set<CellRef> = []
    /// 撤销/重做栈（v0.8.14 基础件 4）：每步存整表快照（表量级内存可接受）。
    /// 包装 struct：Swift 6.4 对 nonisolated struct 里 [[String]] 元素 append
    /// 的重载解析有 bug（实测最小复现失败），包装后正常。
    nonisolated struct Snapshot: Equatable {
        var rows: [[String]]
    }
    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []

    struct CellRef: Hashable {
        let row: Int
        let col: Int
    }

    init(rows: [[String]]) {
        self.rows = rows
    }

    var headers: [String] {
        rows.first ?? []
    }

    var bodyRows: ArraySlice<[String]> {
        rows.dropFirst()
    }

    var rowCount: Int { rows.count }
    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    mutating func set(row: Int, col: Int, value: String) {
        guard row >= 0, row < rows.count else { return }
        undoStack.append(Snapshot(rows: rows))
        redoStack.removeAll()
        if undoStack.count > 100 { undoStack.removeFirst() }
        while rows[row].count <= col { rows[row].append("") }
        rows[row][col] = value
        dirtyCells.insert(CellRef(row: row, col: col))
    }

    /// ⌘Z：回退到上一快照。无可撤销返回 false。
    mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(Snapshot(rows: rows))
        rows = previous.rows
        return true
    }

    /// ⌘⇧Z：重做。
    mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(Snapshot(rows: rows))
        rows = next.rows
        return true
    }

    // MARK: - 排序 / 筛选（视图层状态，不改原 rows）

    /// 按列排序的行索引（首行表头除外）；stable：等值保持原序。
    static func sortedIndices(rowCount: Int, by column: Int, ascending: Bool,
                              rows: [[String]]) -> [Int] {
        guard column >= 0, rowCount > 1, rows.count > 1 else {
            return Array(1..<max(1, rowCount))
        }
        struct RowIdx { let originalIndex: Int; let values: [String] }
        let indexed: [RowIdx] = rows.indices.dropFirst().map { RowIdx(originalIndex: $0, values: rows[$0]) }
        let sorted = indexed.sorted { (a: RowIdx, b: RowIdx) -> Bool in
            let av = a.values.count > column ? a.values[column] : ""
            let bv = b.values.count > column ? b.values[column] : ""
            // 数值优先（"10" < "9" 的字典序陷阱）；都非数值退字典序。
            if let an = Double(av), let bn = Double(bv) {
                return ascending ? an < bn : an > bn
            }
            return ascending ? av.localizedStandardCompare(bv) == .orderedAscending
                             : av.localizedStandardCompare(bv) == .orderedDescending
        }
        return sorted.map { $0.originalIndex }   // rows 全量下标（跳过表头已含在 originalIndex）
    }

    /// 关键字筛选（命中任意列的行下标；空关键字 = 全部）。
    static func filteredIndices(rows: [[String]], keyword: String) -> [Int] {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return Array(rows.indices.dropFirst()) }
        return rows.indices.dropFirst().filter { rowIdx in
            rows[rowIdx].contains { $0.localizedCaseInsensitiveContains(key) }
        }
    }

    // MARK: - 序列化（保存）

    /// CSV 行序列化：含逗号/引号/换行的字段加引号转义（RFC 4180）。
    nonisolated static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
                return field
            }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        .joined(separator: ",")
    }

    static func csvText(rows: [[String]]) -> String {
        rows.map { csvLine($0) }.joined(separator: "\n") + "\n"
    }

    /// A1 语法 → (row, col)（"B3" → row=2, col=1）；解析失败 nil。
    nonisolated static func parseA1(_ a1: String) -> CellRef? {
        let chars = Array(a1.uppercased())
        guard !chars.isEmpty else { return nil }
        var col = 0
        var idx = 0
        while idx < chars.count, chars[idx].isLetter {
            guard let scalar = chars[idx].asciiValue else { return nil }
            col = col * 26 + Int(scalar - 64)
            idx += 1
        }
        guard col > 0, let row = Int(String(chars[idx...])), row >= 1 else { return nil }
        return CellRef(row: row - 1, col: col - 1)
    }

    // MARK: - 选区导出（v0.8.14 融合：选区 → Agent 画图）

    /// 选区子矩阵 → TSV（rows[0] 为表头行，恒在首行）。单元格内的
    /// 制表符/换行摊平为空格防破格；行列封顶（超出截断）。
    /// 返回 (文本, 是否发生截断)。行区间不含表头行（row ≥ 1 才是数据）。
    nonisolated static func tsvSelection(rows: [[String]],
                                         rowRange: ClosedRange<Int>,
                                         colRange: ClosedRange<Int>,
                                         maxRows: Int = 60, maxCols: Int = 12) -> (text: String, truncated: Bool) {
        guard rowRange.lowerBound <= rowRange.upperBound,
              colRange.lowerBound <= colRange.upperBound else { return ("", false) }
        let cols = Array(colRange.lowerBound...min(colRange.upperBound, colRange.lowerBound + maxCols - 1))
        let dataRows = Array(rowRange.lowerBound...min(rowRange.upperBound, rowRange.lowerBound + maxRows - 1))
            .filter { $0 >= 1 && $0 < rows.count }
        let truncated = rowRange.count > maxRows || colRange.count > maxCols
        func cell(_ row: Int, _ col: Int) -> String {
            let raw = col < rows[row].count ? rows[row][col] : ""
            return raw
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        var lines: [String] = []
        let headerRow = rows.first ?? []
        lines.append(cols.map { $0 < headerRow.count ? headerRow[$0] : "" }
            .map { $0.replacingOccurrences(of: "\t", with: " ") }
            .joined(separator: "\t"))
        for row in dataRows {
            lines.append(cols.map { cell(row, $0) }.joined(separator: "\t"))
        }
        return (lines.joined(separator: "\n"), truncated)
    }
}
