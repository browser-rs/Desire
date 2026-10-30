import Foundation

/// CSV ⇄ JSON 转换——纯逻辑（RFC 4180 解析，含引号与换行）。
nonisolated enum CSVJSONCore {
    /// 解析分隔文本（支持 "" 转义与引号内换行）。
    static func parseCSV(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else {
                if character == "\"" {
                    inQuotes = true
                } else if character == delimiter {
                    row.append(field)
                    field = ""
                } else if character == "\n" || character == "\r\n" {
                    row.append(field)
                    field = ""
                    rows.append(row)
                    row = []
                    if character == "\r" {
                        let next = text.index(after: index)
                        if next < text.endIndex, text[next] == "\n" {
                            index = next
                        }
                    }
                } else {
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // 去掉全空行
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// 首行当表头 → 对象数组 JSON。空表头跳过；重复表头加后缀。
    static func csvToJSON(_ text: String, delimiter: Character = ",") -> Result<String, ToolboxError> {
        let rows = parseCSV(text, delimiter: delimiter)
        guard let header = rows.first, !header.isEmpty else {
            return .failure(ToolboxError(message: "CSV is empty"))
        }
        var keys: [String] = []
        var seen = Set<String>()
        for (index, raw) in header.enumerated() {
            var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { key = "Column \(index + 1)" }
            var unique = key
            var suffix = 2
            while seen.contains(unique) {
                unique = "\(key) \(suffix)"
                suffix += 1
            }
            seen.insert(unique)
            keys.append(unique)
        }
        var objects: [[String: String]] = []
        for row in rows.dropFirst() where !row.isEmpty {
            var object: [String: String] = [:]
            for (index, key) in keys.enumerated() {
                object[key] = index < row.count ? row[index] : ""
            }
            objects.append(object)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(ToolboxError(message: "Could not encode JSON"))
        }
        return .success(json)
    }
}
