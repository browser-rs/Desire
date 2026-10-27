import Foundation

/// 表格取数（端上，零第三方依赖）：`.xlsx`（zip + XML 直接解析）与
/// `.csv` / `.tsv` 文本表格 → 规整行数组 → Markdown 表交给模型。
///
/// 口径（诚实标注，写进工具返回的头）：
/// - xlsx 取**指定工作表**（默认第 1 个）的**缓存值**——公式读的是上次保存的
///   计算结果；日期/货币可能是 Excel 序列号或原样数字（不做样式解析）。
/// - 行列超上限截断并标注，避免大表撑爆上下文。
/// - `.numbers` / 旧版 `.xls` 不支持（私有格式 / 未收录），提示用户另存。
enum SpreadsheetReader {
    struct Sheet {
        var name: String
        var rows: [[String]]
        /// 因上限被截掉的行数（0 = 全量）。
        var truncatedRows: Int = 0
    }

    // MARK: - 读取（IO）

    /// .csv / .tsv：分隔符嗅探（逗号 / 分号 / 制表符），UTF-8 失败回退 GB18030
    /// （中文表格导出常见）。
    static func readCSV(from url: URL, maxRows: Int = 200, maxCols: Int = 40) -> Sheet? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        // GB18030（中文表格导出常见）：CFStringEncodings.GB_18030_2000 的
        // NSStringEncoding 原值（0x80000000 | 0x0632）——写原值保持本文件
        // Foundation-only（harness 与 app 都能直接编译，不引 CoreFoundation）。
        let gb18030 = String.Encoding(rawValue: 0x8000_0632)
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030)
        guard let text else { return nil }
        let delimiter = sniffDelimiter(text)
        let all = parseDelimited(text, delimiter: delimiter)
        return Sheet(name: url.lastPathComponent, rows: capped(all, maxRows: maxRows, maxCols: maxCols))
    }

    /// .xlsx：`unzip -p` 取 sharedStrings / 工作表 XML，XMLParser 直接解析。
    /// 系统自带 `/usr/bin/unzip`；条目缺失（inline string 工作簿没有
    /// sharedStrings.xml）按空表处理。
    /// 工作表清单（v0.8.13 基础件 1）：sheetIndex → 显示名（workbook.xml 顺序）。
    /// 表格查看器底部标签栏的数据源；非 xlsx 返回空。
    static func sheetList(of url: URL) -> [(index: Int, name: String)] {
        guard let xml = unzipEntry(url, "xl/workbook.xml") else { return [] }
        return parseSheetNames(xml: xml).enumerated()
            .map { (index: $0.offset + 1, name: $0.element) }
    }

    static func readXLSX(from url: URL, sheetIndex: Int = 1, maxRows: Int = 200, maxCols: Int = 40) -> Sheet? {
        let index = max(1, sheetIndex)
        let shared = unzipEntry(url, "xl/sharedStrings.xml").map(parseSharedStrings) ?? []
        guard let sheetXML = unzipEntry(url, "xl/worksheets/sheet\(index).xml") else { return nil }
        let rows = parseSheetRows(xml: sheetXML, sharedStrings: shared)
        let names = unzipEntry(url, "xl/workbook.xml").map(parseSheetNames) ?? []
        let name = names.indices.contains(index - 1) ? names[index - 1] : "sheet\(index)"
        return Sheet(name: name, rows: capped(rows, maxRows: maxRows, maxCols: maxCols))
    }

    private static func capped(_ rows: [[String]], maxRows: Int, maxCols: Int) -> [[String]] {
        var out: [[String]] = []
        for row in rows.prefix(maxRows) {
            out.append(Array(row.prefix(maxCols)))
        }
        return out
    }

    /// `unzip -p <archive> <entry>` → 数据；条目不存在/工具缺失返回 nil。
    /// 注：整个条目读进内存（工作表 XML 量级为 MB～数十 MB，可接受）；
    /// 行数上限在解析层用 abortParsing 提前止损。
    private static func unzipEntry(_ archive: URL, _ entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.isEmpty ? nil : data
    }

    // MARK: - 渲染

    /// Markdown 表（首行当表头）。总长封顶，截断处标注。
    nonisolated static func markdown(from sheet: Sheet, maxChars: Int = 40_000) -> String {
        guard let header = sheet.rows.first else { return "(empty sheet)" }
        func esc(_ cell: String) -> String {
            cell.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        var lines: [String] = [
            "| " + header.map(esc).joined(separator: " | ") + " |",
            "| " + header.map { _ in "---" }.joined(separator: " | ") + " |",
        ]
        var chars = lines.reduce(0) { $0 + $1.count }
        var droppedBody = 0
        for row in sheet.rows.dropFirst() {
            let line = "| " + row.map(esc).joined(separator: " | ") + " |"
            if chars + line.count > maxChars {
                droppedBody = sheet.rows.count - 1 - (lines.count - 2)
                break
            }
            lines.append(line)
            chars += line.count
        }
        if droppedBody > 0 { lines.append("…[\(droppedBody) more row(s) truncated]") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 纯逻辑（tests/run.sh 直测）

    /// RFC 4180 风格：引号包裹字段、字段内 `""` 转义引号、引号内可含换行
    /// 与分隔符；`\r\n` / `\r` / `\n` 均算行分隔。末尾换行不产生空行。
    nonisolated static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        // Swift 的 String 迭代按字素簇走——"\r\n" 是**单个 Character**，
        // 逐字符匹配 "\r"/"\n" 分支都不会命中（实测：整段 CRLF 输入被当成
        // 一行一个字段）。入口统一归一化成 "\n"。
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var hasContent = false
        var iter = text.makeIterator()
        var pending: Character?
        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
            hasContent = false
        }
        while true {
            let ch: Character
            if let p = pending { ch = p; pending = nil }
            else if let next = iter.next() { ch = next }
            else { break }
            if inQuotes {
                if ch == "\"" {
                    // 预读：`""` = 字面引号；否则结束引用段
                    if let next = iter.next() {
                        if next == "\"" { field.append("\"") }
                        else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                    hasContent = true
                case delimiter:
                    endField()
                    hasContent = true
                case "\n":
                    endRow()
                case "\r":
                    if let next = iter.next(), next != "\n" { pending = next }
                    endRow()
                default:
                    field.append(ch)
                    hasContent = true
                }
            }
        }
        if hasContent || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// 首行（引号外）里出现最多的候选分隔符。
    nonisolated static func sniffDelimiter(_ text: String) -> Character {
        // 同 parseDelimited：CRLF 先归一化，否则"首行结束"判定永远不命中。
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let candidates: [Character] = [",", ";", "\t"]
        var counts: [Character: Int] = [:]
        var inQuotes = false
        var firstLineDone = false
        for ch in text {
            if firstLineDone { break }
            if ch == "\"" { inQuotes.toggle() }
            else if !inQuotes, ch == "\n" { firstLineDone = true }
            else if !inQuotes, candidates.contains(ch) { counts[ch, default: 0] += 1 }
        }
        return candidates.max(by: { (counts[$0] ?? 0) < (counts[$1] ?? 0) })
            .flatMap { counts[$0, default: 0] > 0 ? $0 : nil } ?? ","
    }

    /// "C12" → (col: 3, row: 12)（1 基）。非法返回 nil。
    nonisolated static func cellCoordinates(_ ref: String) -> (col: Int, row: Int)? {
        var col = 0
        var row = 0
        var sawLetters = false
        var sawDigits = false
        for ch in ref.uppercased() {
            if ch >= "A", ch <= "Z" {
                guard !sawDigits else { return nil }
                sawLetters = true
                col = col * 26 + Int(ch.asciiValue! - 64)
            } else if ch >= "0", ch <= "9" {
                sawDigits = true
                row = row * 10 + Int(ch.asciiValue! - 48)
            } else {
                return nil
            }
        }
        guard sawLetters, sawDigits, col > 0, row > 0 else { return nil }
        return (col, row)
    }

    /// xl/sharedStrings.xml → 字符串表。`<si>` 内所有 `<t>` 顺序拼接；
    /// `<rPh>`（东亚注音）内的 `<t>` 丢弃。
    nonisolated static func parseSharedStrings(xml: Data) -> [String] {
        let delegate = SharedStringsDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    /// xl/worksheets/sheetN.xml → 行数组（按单元格 r 引用补空位）。
    /// `rowCap` 兜底：超大表提前 abortParsing（已收的行仍然可用）。
    nonisolated static func parseSheetRows(xml: Data, sharedStrings: [String], rowCap: Int = 5_000) -> [[String]] {
        let delegate = SheetDelegate(sharedStrings: sharedStrings, rowCap: rowCap)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    /// xl/workbook.xml → 工作表名（按出现顺序，与 sheetN 文件序号对应）。
    nonisolated static func parseSheetNames(xml: Data) -> [String] {
        let delegate = SheetNamesDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.names
    }

    // MARK: - XML 委托（私有实现细节）

    nonisolated private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current: String?
        private var inPhonetic = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            switch elementName {
            case "si": current = ""
            case "rPh": inPhonetic += 1
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inPhonetic == 0, current != nil else { return }
            current? += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch elementName {
            case "si":
                strings.append(current ?? "")
                current = nil
            case "rPh":
                inPhonetic = max(0, inPhonetic - 1)
            default: break
            }
        }
    }

    nonisolated private final class SheetDelegate: NSObject, XMLParserDelegate {
        let sharedStrings: [String]
        let rowCap: Int
        var rows: [[String]] = []
        private var cells: [String] = []
        private var cellRef: String?
        private var cellType: String?
        private var cellValue: String?
        private var inlineText: String?
        private var inInline = false

        init(sharedStrings: [String], rowCap: Int) {
            self.sharedStrings = sharedStrings
            self.rowCap = rowCap
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            switch elementName {
            case "row":
                cells = []
            case "c":
                cellRef = attributes["r"]
                cellType = attributes["t"]
                cellValue = nil
                inlineText = nil
            case "is":
                inInline = true
                inlineText = ""
            case "v":
                cellValue = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if cellValue != nil, !inInline { cellValue? += string }
            else if inInline { inlineText? += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch elementName {
            case "c":
                let raw = cellValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let text: String
                switch cellType {
                case "s":
                    let idx = Int(raw ?? "") ?? -1
                    text = sharedStrings.indices.contains(idx) ? sharedStrings[idx] : raw ?? ""
                case "inlineStr":
                    text = inlineText ?? ""
                case "b":
                    text = raw == "1" ? "TRUE" : "FALSE"
                default:
                    text = raw ?? ""
                }
                if let ref = cellRef, let coords = SpreadsheetReader.cellCoordinates(ref) {
                    let col = coords.col - 1
                    while cells.count < col { cells.append("") }
                    if cells.count == col { cells.append(text) } else { cells[col] = text }
                } else {
                    cells.append(text)
                }
                cellRef = nil
                cellType = nil
                cellValue = nil
            case "is":
                inInline = false
            case "row":
                rows.append(cells)
                if rows.count >= rowCap { parser.abortParsing() }
            default: break
            }
        }
    }

    nonisolated private final class SheetNamesDelegate: NSObject, XMLParserDelegate {
        var names: [String] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if elementName == "sheet", let name = attributes["name"] { names.append(name) }
        }
    }
}
