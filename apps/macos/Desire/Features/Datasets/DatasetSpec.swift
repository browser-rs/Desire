import Foundation

/// 列表 → 表格作业的规格与纯逻辑（v0.8.2，进 harness）。
/// 采集本身是确定性 DOM 读取（不逐行调模型）；这里只做可测部分：
/// 字段行解析、CSV 转义、去重。
nonisolated struct DatasetSpec: Codable, Equatable {
    struct Field: Codable, Equatable {
        var key: String
        var selector: String
    }

    enum Pagination: String, Codable, CaseIterable {
        case none
        case nextButton
        case urlTemplate
        case scroll

        var label: String {
            switch self {
            case .none: String(localized: "Single page")
            case .nextButton: String(localized: "Next button")
            case .urlTemplate: String(localized: "URL template {page}")
            case .scroll: String(localized: "Scroll to load")
            }
        }
    }

    var startURL: String
    var rowSelector: String
    var fields: [Field]
    var pagination: Pagination
    var nextSelector: String?
    var urlTemplate: String?
    var maxPages: Int
    var maxRows: Int
    /// 用哪个字段去重（nil = 整行去重）。
    var dedupeKey: String?

    init(startURL: String, rowSelector: String, fields: [Field],
         pagination: Pagination = .none, nextSelector: String? = nil,
         urlTemplate: String? = nil, maxPages: Int = 10, maxRows: Int = 2000,
         dedupeKey: String? = nil) {
        self.startURL = startURL
        self.rowSelector = rowSelector
        self.fields = fields
        self.pagination = pagination
        self.nextSelector = nextSelector
        self.urlTemplate = urlTemplate
        self.maxPages = max(1, min(maxPages, 50))
        self.maxRows = max(1, min(maxRows, 20_000))
        self.dedupeKey = dedupeKey
    }

    /// 解析外部传入的翻页模式（桥/工具用短名 none|next|url|scroll）。
    static func parsePagination(_ raw: String) -> Pagination {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "url", "urltemplate": return .urlTemplate
        case "next", "nextbutton": return .nextButton
        case "scroll": return .scroll
        default: return .none
        }
    }

    /// "key=selector" 每行一条（也接受 "key: selector"）；忽略空行/无等号行。
    static func parseFields(_ text: String) -> [Field] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let selector = parts[1].trimmingCharacters(in: .whitespaces)
                return key.isEmpty || selector.isEmpty ? nil : Field(key: key, selector: selector)
            }
            let parts2 = trimmed.split(separator: ":", maxSplits: 1)
            if parts2.count == 2 {
                let key = parts2[0].trimmingCharacters(in: .whitespaces)
                let selector = parts2[1].trimmingCharacters(in: .whitespaces)
                return key.isEmpty || selector.isEmpty ? nil : Field(key: key, selector: selector)
            }
            return nil
        }
    }

    static func dedupe(_ rows: [[String: String]], key: String?) -> [[String: String]] {
        var seen = Set<String>()
        var out: [[String: String]] = []
        for row in rows {
            let identity: String
            if let key, let value = row[key] {
                identity = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } else {
                identity = row.keys.sorted()
                    .map { "\($0)=\((row[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))" }
                    .joined(separator: "|")
            }
            guard !identity.isEmpty, seen.insert(identity).inserted else { continue }
            out.append(row)
        }
        return out
    }

    /// CSV（带表头、RFC 4180 转义）。
    static func csv(rows: [[String: String]], fields: [Field]) -> String {
        func escape(_ raw: String) -> String {
            if raw.contains(",") || raw.contains("\"") || raw.contains("\n") {
                return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return raw
        }
        var lines = [fields.map { escape($0.key) }.joined(separator: ",")]
        for row in rows {
            lines.append(fields.map { escape(row[$0.key] ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// URL 模板展开（{page} 替换；无模板返回 nil）。
    static func pageURL(_ template: String?, page: Int) -> String? {
        guard let template, template.contains("{page}") else { return nil }
        return template.replacingOccurrences(of: "{page}", with: "\(page)")
    }
}
