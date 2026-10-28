import Foundation

/// 最小 xlsx 写入器（v0.8.16 基础件 3）：SpreadsheetBuffer 行数组 →
/// inlineStr/数值单元格的极简工作簿（zip 打包，零第三方依赖）。
/// 只写值不写公式——"xlsx 写缓存值"既有口径的写侧；无样式/多表/共享字符串。
/// XML 拼装为纯逻辑进 tests/run.sh；roundtrip（写 → SpreadsheetReader 读回）
/// 也在 harness 直测（ditto/unzip 系统自带，runner 可用）。
nonisolated enum SpreadsheetXLSXWriter {

    // MARK: - XML parts（纯逻辑）

    /// "B3" 风格引用（row/col 均 1-based）。
    nonisolated static func cellRef(row: Int, col: Int) -> String {
        var n = col
        var letters = ""
        repeat {
            let r = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + r))) + letters
            n = (n - 1) / 26
        } while n > 0
        return letters + String(row)
    }

    nonisolated static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 工作表 XML：数值-looking 单元格写数字（Excel 可计算），其余 inlineStr。
    nonisolated static func sheetXML(rows: [[String]]) -> String {
        var body = ""
        for (r, row) in rows.enumerated() {
            var cells = ""
            for (c, field) in row.enumerated() {
                let ref = cellRef(row: r + 1, col: c + 1)
                if let number = numericValue(field) {
                    cells += "<c r=\"\(ref)\"><v>\(number)</v></c>"
                } else {
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeXML(field))</t></is></c>"
                }
            }
            body += "<row r=\"\(r + 1)\">\(cells)</row>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<sheetData>\(body)</sheetData></worksheet>"
    }

    /// 数值-looking → 按数值写（整数无前导零；小数含 `.`/`e`）；
    /// 其余（"007"、编号、电话带前导零等）按文本写。
    nonisolated static func numericValue(_ field: String) -> String? {
        let cleaned = field.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        if let i = Int(cleaned) {
            return String(i) == cleaned ? cleaned : nil   // "007" 保持文本
        }
        if let d = Double(cleaned), d.isFinite,
           cleaned.contains(".") || cleaned.contains("e") || cleaned.contains("E") {
            return cleaned
        }
        return nil
    }

    // MARK: - 打包（IO）

    /// 行数组 → xlsx 文件（temp 目录摆 parts → ditto 封 zip）。
    @discardableResult
    static func write(rows: [[String]], sheetName: String, to url: URL) -> Bool {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("xlsx-write-\(UUID().uuidString)")
        let xl = dir.appendingPathComponent("xl", isDirectory: true)
        let rels = dir.appendingPathComponent("_rels", isDirectory: true)
        let xlRels = xl.appendingPathComponent("_rels", isDirectory: true)
        let ws = xl.appendingPathComponent("worksheets", isDirectory: true)
        for d in [dir, xl, rels, xlRels, ws] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let safeSheet = sheetName.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let parts: [(String, String)] = [
            ("[Content_Types].xml",
             "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                 + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                 + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                 + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                 + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
                 + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
                 + "</Types>"),
            ("_rels/.rels",
             "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                 + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                 + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
                 + "</Relationships>"),
            ("xl/workbook.xml",
             "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                 + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
                 + " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
                 + "<sheets><sheet name=\"\(escapeXML(safeSheet))\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels",
             "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                 + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                 + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
                 + "</Relationships>"),
            ("xl/worksheets/sheet1.xml", sheetXML(rows: rows)),
        ]
        for (relative, content) in parts {
            do {
                try content.write(to: dir.appendingPathComponent(relative),
                                  atomically: true, encoding: .utf8)
            } catch {
                try? fm.removeItem(at: dir)
                return false
            }
        }
        // 先删目标（zip 追加语义会并进旧包）；cwd=临时目录、传相对路径。
        // 注：ditto -c -k 多源会报 "Can't archive multiple sources"——这里用
        // /usr/bin/zip（系统自带；读侧 /usr/bin/unzip 对称）。
        try? fm.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = dir
        process.arguments = ["-q", "-r", url.path, "[Content_Types].xml", "_rels", "xl"]
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? fm.removeItem(at: dir)
            return false
        }
        try? fm.removeItem(at: dir)
        guard process.terminationStatus == 0, fm.fileExists(atPath: url.path) else { return false }
        return true
    }
}
