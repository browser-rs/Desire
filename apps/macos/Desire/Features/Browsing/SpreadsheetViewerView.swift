import SwiftUI

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
                save()
            } label: {
                Label(String(localized: "Save (⌘S)"), systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
            .disabled(buffer == nil)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
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
                    .frame(minWidth: 72, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        .frame(minWidth: 72, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editingCell = .init(row: row, col: col)
            editingDraft = value
        }
        .onTapGesture {
            selectedRow = row
        }
    }

    private func commitEdit(row: Int, col: Int) {
        guard var b = buffer else { return }
        b.set(row: row, col: col, value: editingDraft)
        buffer = b
        hasUnsavedChanges = true
        editingCell = nil
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
