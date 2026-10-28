import AppKit
import CryptoKit
import UniformTypeIdentifiers
import SwiftUI
import WebKit

/// 表格直开查看/编辑器（v0.8.12 旗舰 A）：CSV/TSV/XLSX 拖入即网格视图。
/// 读取复用 SpreadsheetReader；编辑/排序/筛选/保存走 SpreadsheetBuffer。
/// 大表首屏只物化可视区附近行（窗口截取），⌘S 保存（.bak 快照 + 原子写）。
struct SpreadsheetViewerView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void

    @State private var buffer: SpreadsheetBuffer?
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var loadError: String?
    @State private var isXLSX = false
    /// 视图层状态：排序（列下标，nil = 原序）/筛选关键字/跳转文本。
    @State private var sortColumn: Int?
    @State private var sortAscending = true
    @State private var filterText = ""
    @State private var jumpText = ""
    @State private var editingCell: SpreadsheetBuffer.CellRef?
    @State private var editingDraft = ""
    @State private var hasUnsavedChanges = false
    @State private var statusNote: String?
    @State private var selectedRow: Int?
    /// xlsx 多工作表（v0.8.13）：清单 + 当前选中 index（1-based）。
    @State private var sheets: [(index: Int, name: String)] = []
    @State private var activeSheetIndex = 1
    /// 选区（v0.8.14 融合）：锚点格 + ⇧点扩展的终点（nil = 单格选区）。
    @State private var selectionAnchor: SpreadsheetBuffer.CellRef?
    @State private var selectionEnd: SpreadsheetBuffer.CellRef?
    /// 列宽覆盖（列下标 → 宽度）：拖表头右缘调整，按文件+工作表记忆。
    @State private var columnWidths: [Int: CGFloat] = [:]
    @State private var dragColumn: Int?
    @State private var dragBaseWidth: CGFloat = 0

    private var displayRows: [[Int]] {
        guard let buffer else { return [] }
        var indices: [Int]
        if !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            indices = SpreadsheetBuffer.filteredIndices(rows: buffer.rows, keyword: filterText)
        } else if let col = sortColumn {
            indices = SpreadsheetBuffer.sortedIndices(
                rowCount: buffer.rowCount, by: col, ascending: sortAscending, rows: buffer.rows)
        } else {
            indices = Array(buffer.rows.indices.dropFirst())
        }
        return indices.map { [$0] + Array(buffer.rows[$0].indices) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            if sheets.count > 1 {
                sheetTabs
            }
            if let buffer {
                grid(buffer)
            } else if let loadError {
                errorPane(loadError)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            statusBar
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: load)
        .onChange(of: fileURL) { _, _ in load() }
    }

    // MARK: - 加载

    private func load() {
        loadError = nil
        let ext = fileURL.pathExtension.lowercased()
        isXLSX = ext == "xlsx"
        if isXLSX {
            sheets = SpreadsheetReader.sheetList(of: fileURL)
        } else {
            sheets = []
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let sheet: SpreadsheetReader.Sheet?
            if ext == "xlsx" {
                sheet = SpreadsheetReader.readXLSX(from: fileURL, sheetIndex: activeSheetIndex,
                                                   maxRows: 5_000, maxCols: 100)
            } else {
                sheet = SpreadsheetReader.readCSV(from: fileURL, maxRows: 5_000, maxCols: 100)
            }
            DispatchQueue.main.async {
                guard let sheet else {
                    loadError = String(localized: "Could not read this table.")
                    return
                }
                buffer = SpreadsheetBuffer(rows: sheet.rows)
                canUndo = false
                canRedo = false
                selectionAnchor = nil
                selectionEnd = nil
                loadColumnWidths()
            }
        }
    }

    // MARK: - 保存（.bak 快照 + 原子写）

    private func save() {
        guard let buffer else { return }
        let text = SpreadsheetBuffer.csvText(rows: buffer.rows)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                let backup = fileURL.deletingPathExtension()
                    .appendingPathExtension(fileURL.pathExtension + ".bak")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: fileURL, to: backup)
            }
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            hasUnsavedChanges = false
            flash(String(localized: "Saved (backup: .\(fileURL.pathExtension).bak)"))
        } catch {
            flash(String(localized: "Save failed: \(error.localizedDescription)"))
        }
    }

    /// 另存为 xlsx（v0.8.16 基础件 3）：SpreadsheetXLSXWriter 管道（只写值）。
    private func exportXLSX() {
        guard let buffer else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            ((fileName as NSString).deletingPathExtension) + ".xlsx"
        panel.allowedContentTypes = [.init(filenameExtension: "xlsx") ?? .data]
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let name = sheets.first(where: { $0.index == activeSheetIndex })?.name ?? "Sheet1"
        let ok = SpreadsheetXLSXWriter.write(rows: buffer.rows, sheetName: name, to: dest)
        flash(ok
            ? String(localized: "Exported → \(dest.lastPathComponent)")
            : String(localized: "Export failed"))
    }

    private func flash(_ text: String) {
        statusNote = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if statusNote == text { statusNote = nil }
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(spacing: 10) {
            Button { onBack() } label: {
                Label(String(localized: "Back to Page"), systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            Text(fileName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            if hasUnsavedChanges {
                Text("Edited")
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Button {
                doUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo (⌘Z)")
            Button {
                doRedo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo (⌘⇧Z)")
            Button {
                save()
            } label: {
                Label(String(localized: "Save (⌘S)"), systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            .disabled(buffer == nil)
            .keyboardShortcut("s", modifiers: .command)
            Button {
                exportXLSX()
            } label: {
                Image(systemName: "tablecells")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(buffer == nil)
            .help(String(localized: "Export as xlsx…"))
            Button {
                printTable()
            } label: {
                Image(systemName: "printer")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(buffer == nil)
            .keyboardShortcut("p", modifiers: .command)
            .help(String(localized: "Print (⌘P)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 打印（v0.8.14 基础件 2）：表格 → HTML table → 隐藏 WKWebView →
    /// 系统打印面板（横向内容自动分页）。
    private func printTable() {
        guard let buffer else { return }
        var table = "<table><thead><tr>"
        for cell in buffer.headers { table += "<th>\(cell)</th>" }
        table += "</tr></thead><tbody>"
        for row in buffer.rows.dropFirst() {
            table += "<tr>"
            for cell in row { table += "<td>\(cell)</td>" }
            table += "</tr>"
        }
        table += "</tbody></table>"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, sans-serif; font-size: 11px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #bbb; padding: 4px 6px; text-align: left; }
        th { background: #eee; }
        tr { page-break-inside: avoid; }
        </style></head><body>\(table)</body></html>
        """
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let coordinator = PrintCoordinator()
        printCoordinator = coordinator
        webView.navigationDelegate = coordinator
        webView.loadHTMLString(html, baseURL: nil)
        printWebView = webView
    }

    @State private var printWebView: WKWebView?
    @State private var printCoordinator: PrintCoordinator?

    private final class PrintCoordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                webView.printOperation(with: NSPrintInfo.shared).run()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Filter"), text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 130)
            }
            HStack(spacing: 4) {
                Text("Go")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("A1", text: $jumpText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 60)
                    .onSubmit { jump() }
            }
            if isXLSX {
                Text(String(localized: "XLSX: cached values are edited; formulas recompute in Excel"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                chartSelectionWithAI()
            } label: {
                Label(String(localized: "Chart with AI"), systemImage: "chart.bar.xaxis")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            .disabled(selectionAnchor == nil)
            .help(String(localized: "Send the selected cells to the Agent for a whiteboard chart"))
            if let sortColumn {
                Button {
                    self.sortColumn = nil
                } label: {
                    Label(String(localized: "Clear sort (col \(sortColumn + 1))"), systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var sheetTabs: some View {
        HStack(spacing: 4) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            ForEach(sheets, id: \.index) { sheet in
                Button(sheet.name) {
                    guard activeSheetIndex != sheet.index else { return }
                    activeSheetIndex = sheet.index
                    sortColumn = nil
                    filterText = ""
                    selectedRow = nil
                    selectionAnchor = nil
                    selectionEnd = nil
                    editingCell = nil
                    hasUnsavedChanges = false
                    load()
                }
                .font(.system(size: 10.5, weight: activeSheetIndex == sheet.index ? .semibold : .regular))
                .buttonStyle(.plain)
                .foregroundStyle(activeSheetIndex == sheet.index ? appAccent : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(activeSheetIndex == sheet.index ? appAccent.opacity(0.12) : Color.secondary.opacity(0.08))
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func grid(_ buffer: SpreadsheetBuffer) -> some View {
        let rows = displayRows
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                // 表头（首行冻结）
                Section(header: headerRow(buffer)) {
                    ForEach(rows, id: \.self) { rowPath in
                        if rowPath.count >= 2 {
                            dataRow(buffer, rowIndex: rowPath[0], cells: buffer.rows[rowPath[0]])
                        }
                    }
                }
                if rows.isEmpty, !filterText.isEmpty {
                    Text(String(localized: "No rows match the filter"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func headerRow(_ buffer: SpreadsheetBuffer) -> some View {
        HStack(spacing: 0) {
            // 行号栏占位：与数据行的行号列同宽，表头列才能对齐各自的数据列。
            Color.clear
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 4)
            ForEach(buffer.headers.indices, id: \.self) { col in
                Button {
                    if sortColumn == col {
                        sortAscending.toggle()
                    } else {
                        sortColumn = col
                        sortAscending = true
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(buffer.headers[col].isEmpty ? " " : buffer.headers[col])
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: sortColumn == col
                              ? (sortAscending ? "chevron.up" : "chevron.down") : "arrow.up.arrow.down")
                            .font(.system(size: 7.5))
                            .foregroundStyle(sortColumn == col ? AnyShapeStyle(appAccent) : AnyShapeStyle(.tertiary))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: columnWidth(col), alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) { resizeHandle(col) }
                Divider()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func dataRow(_ buffer: SpreadsheetBuffer, rowIndex: Int, cells: [String]) -> some View {
        HStack(spacing: 0) {
            // 行号
            Text("\(rowIndex + 1)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 4)
            ForEach(cells.indices, id: \.self) { col in
                cellView(buffer, row: rowIndex, col: col, value: cells[col])
                Divider().opacity(0.3)
            }
        }
        .background(selectedRow == rowIndex ? appAccent.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }

    @ViewBuilder
    private func cellView(_ buffer: SpreadsheetBuffer, row: Int, col: Int, value: String) -> some View {
        let isEditing = editingCell == .init(row: row, col: col)
        Group {
            if isEditing {
                TextField("", text: $editingDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit { commitEdit(row: row, col: col) }
                    .onExitCommand { editingCell = nil }
            } else {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: columnWidth(col), alignment: .leading)
        .background(isCellSelected(row: row, col: col) ? appAccent.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editingCell = .init(row: row, col: col)
            editingDraft = value
        }
        .onTapGesture {
            selectedRow = row
            handleCellTap(row: row, col: col)
        }
    }

    private func commitEdit(row: Int, col: Int) {
        guard var b = buffer else { return }
        b.set(row: row, col: col, value: editingDraft)
        buffer = b
        canUndo = !b.undoStack.isEmpty
        canRedo = !b.redoStack.isEmpty
        hasUnsavedChanges = true
        editingCell = nil
    }

    private func doUndo() {
        guard var b = buffer, b.undo() else { return }
        buffer = b
        canUndo = !b.undoStack.isEmpty
        canRedo = !b.redoStack.isEmpty
        hasUnsavedChanges = true
    }

    private func doRedo() {
        guard var b = buffer, b.redo() else { return }
        buffer = b
        canUndo = !b.undoStack.isEmpty
        canRedo = !b.redoStack.isEmpty
        hasUnsavedChanges = true
    }

    private func jump() {
        guard let buffer,
              let target = SpreadsheetBuffer.parseA1(jumpText.trimmingCharacters(in: .whitespaces)) else {
            flash(String(localized: "Use A1-style cell reference (e.g. B3)"))
            return
        }
        selectedRow = target.row
        flash(String(localized: "Jumped to \(jumpText.uppercased())"))
        _ = buffer
    }

    // MARK: - 选区画图（v0.8.14 融合：选区 → Agent 白板）

    /// 点击选中单元格；按住 ⇧ 点击把选区从锚点扩展成矩形。
    private func handleCellTap(row: Int, col: Int) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, selectionAnchor != nil {
            selectionEnd = SpreadsheetBuffer.CellRef(row: row, col: col)
        } else {
            selectionAnchor = SpreadsheetBuffer.CellRef(row: row, col: col)
            selectionEnd = nil
        }
    }

    private func isCellSelected(row: Int, col: Int) -> Bool {
        guard let a = selectionAnchor else { return false }
        let b = selectionEnd ?? a
        return row >= min(a.row, b.row) && row <= max(a.row, b.row)
            && col >= min(a.col, b.col) && col <= max(a.col, b.col)
    }

    /// 选区子矩阵 → TSV → 活 Agent 会话：要求模型用 whiteboard 工具按数据
    /// 形态挑图型出图（图型选择交给模型；超 60 行/12 列在提示词里注明截断）。
    private func chartSelectionWithAI() {
        guard let buffer, let a = selectionAnchor else { return }
        let b = selectionEnd ?? a
        let tsv = SpreadsheetBuffer.tsvSelection(
            rows: buffer.rows,
            rowRange: min(a.row, b.row)...max(a.row, b.row),
            colRange: min(a.col, b.col)...max(a.col, b.col))
        guard !tsv.text.isEmpty else { return }
        let truncation = tsv.truncated ? "（超出 60 行/12 列的部分已截断）" : ""
        let prompt = String(localized: "请把下面这段表格数据（来自文件 \(fileName)）画成图表：用 whiteboard 工具，按数据形态挑合适的图型（趋势选折线、构成选饼图、对比选柱状图），把可视化结果渲染到白板上。数据为 TSV，首行是表头\(truncation)：\n\(tsv.text)")
        guard let session = AgentScheduler.shared.deliveryTarget else {
            flash(String(localized: "No live agent session"))
            return
        }
        session.sendMessage(prompt, recordHistory: true)
        NotificationCenter.default.post(name: .desireShowAgentPanel, object: nil)
        flash(String(localized: "Selection sent to the Agent"))
    }

    // MARK: - 列宽调整与记忆（v0.8.14 基础件：按文件路径哈希 + 工作表）

    private let defaultColumnWidth: CGFloat = 96

    private func columnWidth(_ col: Int) -> CGFloat {
        columnWidths[col] ?? defaultColumnWidth
    }

    /// 表头右缘 6pt 拖拽手柄：拖动调宽、松手落盘；手势吃掉窄条上的点击，
    /// 不会误触排序按钮。
    private func resizeHandle(_ col: Int) -> some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragColumn != col {
                        dragColumn = col
                        dragBaseWidth = columnWidths[col] ?? defaultColumnWidth
                    }
                    columnWidths[col] = min(640, max(56, dragBaseWidth + value.translation.width))
                }
                .onEnded { _ in
                    dragColumn = nil
                    persistColumnWidths()
                })
    }

    /// 键 = 文件路径 SHA256 前 8 字节（defaults 不落明文路径）；
    /// 值 = { 工作表 index → 列宽表 }（0 = 未调整过，用默认宽）。
    private var layoutDefaultsKey: String {
        let digest = SHA256.hash(data: Data(fileURL.path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "viewer.table.layout.\(hex)"
    }

    private func loadColumnWidths() {
        guard let data = UserDefaults.standard.data(forKey: layoutDefaultsKey),
              let all = try? JSONDecoder().decode([String: [Double]].self, from: data),
              let widths = all[String(activeSheetIndex)] else {
            columnWidths = [:]
            return
        }
        var mapped: [Int: CGFloat] = [:]
        for (index, width) in widths.enumerated() where width > 0 {
            mapped[index] = CGFloat(width)
        }
        columnWidths = mapped
    }

    private func persistColumnWidths() {
        var all: [String: [Double]] = [:]
        if let data = UserDefaults.standard.data(forKey: layoutDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: [Double]].self, from: data) {
            all = decoded
        }
        let maxCol = max(buffer?.columnCount ?? 0,
                         columnWidths.keys.max().map { $0 + 1 } ?? 0)
        var widths = [Double](repeating: 0, count: maxCol)
        for (index, width) in columnWidths { widths[index] = Double(width) }
        all[String(activeSheetIndex)] = widths
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: layoutDefaultsKey)
        }
    }

    private func errorPane(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let buffer {
                Text("\(buffer.rowCount - 1) rows × \(buffer.columnCount) cols")
                    .font(.system(size: 10, design: .monospaced))
            }
            Spacer()
            if let statusNote {
                Text(statusNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(appAccent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .overlay(alignment: .top) { Divider() }
    }
}
