import Foundation

/// 历史正文索引的一条记录（v0.8.0）。默认 opt-in，只存去空白后的前 3000 字，
/// 不随云同步。
nonisolated struct HistoryContentRecord: Codable, Equatable {
    var url: String
    var title: String
    var text: String
    var updatedAt: Date
}

/// 正文检索命中（片段用于面板/桥展示）。
nonisolated struct HistoryContentHit: Equatable {
    let record: HistoryContentRecord
    let score: Double
    let snippet: String
}

/// 本地正文检索（纯逻辑，进 harness）。
///
/// 中文按**单字 + 相邻双字**切分：查询要求所有单字出现（"北大" 命中
/// "北京大学"），双字命中额外加分；英文/数字按词切分，要求所有词出现。
/// 不做向量/模型调用，确定性、可离线。
nonisolated enum HistoryContentSearch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: .current)
    }

    /// 建立索引/查询用的 token 集合。
    static func indexTokens(_ text: String) -> Set<String> {
        var out = Set<String>()
        let scalars = Array(normalize(text).unicodeScalars)
        var word = ""
        var cjkRun: [String] = []

        func flushWord() {
            if word.count >= 2 { out.insert(word) }
            word = ""
        }
        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            for ch in cjkRun { out.insert(ch) }
            if cjkRun.count >= 2 {
                for i in 0..<(cjkRun.count - 1) {
                    out.insert(cjkRun[i] + cjkRun[i + 1])
                }
            }
            cjkRun.removeAll()
        }

        for scalar in scalars {
            if isCJK(scalar) {
                flushWord()
                cjkRun.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                word.unicodeScalars.append(scalar)
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return out
    }

    /// 查询必含 token（英文词 + 中文字）；中文双字作为加分 token。
    static func queryParts(_ query: String) -> (required: [String], bonus: [String]) {
        var required: [String] = []
        var bonus: [String] = []
        let scalars = Array(normalize(query).unicodeScalars)
        var word = ""
        var cjkRun: [String] = []

        func flushWord() {
            if word.count >= 2 { required.append(word) }
            word = ""
        }
        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            required.append(contentsOf: cjkRun)
            if cjkRun.count >= 2 {
                for i in 0..<(cjkRun.count - 1) {
                    bonus.append(cjkRun[i] + cjkRun[i + 1])
                }
            }
            cjkRun.removeAll()
        }

        for scalar in scalars {
            if isCJK(scalar) {
                flushWord()
                cjkRun.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                word.unicodeScalars.append(scalar)
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return (Array(Set(required)), Array(Set(bonus)))
    }

    static func search(query: String, records: [HistoryContentRecord],
                       limit: Int = 20) -> [HistoryContentHit] {
        let parts = queryParts(query)
        guard !parts.required.isEmpty else { return [] }
        let bonus = Set(parts.bonus)
        var hits: [HistoryContentHit] = []
        for record in records {
            let all = indexTokens(record.title + " " + record.text)
            guard parts.required.allSatisfy({ all.contains($0) }) else { continue }
            var score = Double(parts.required.count)
            score += Double(bonus.intersection(all).count) * 2
            let titleTokens = indexTokens(record.title)
            score += Double(parts.required.filter { titleTokens.contains($0) }.count) * 2
            hits.append(HistoryContentHit(
                record: record,
                score: score,
                snippet: snippet(text: record.text, query: query)))
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.record.updatedAt > $1.record.updatedAt
        }
        return Array(hits.prefix(max(1, limit)))
    }

    /// 命中词周围的窗口（在原文上定位；大写/变音符不敏感）。
    static func snippet(text: String, query: String, radius: Int = 70) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !flat.isEmpty else { return "" }
        var range: Range<String.Index>?
        if !query.isEmpty {
            range = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        }
        if range == nil {
            for token in queryParts(query).required {
                if let found = flat.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                    range = found
                    break
                }
            }
        }
        guard let range else {
            return String(flat.prefix(radius * 2))
        }
        let start = flat.index(range.lowerBound, offsetBy: -radius,
                               limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius,
                             limitedBy: flat.endIndex) ?? flat.endIndex
        var out = String(flat[start..<end])
        if start != flat.startIndex { out = "…" + out }
        if end != flat.endIndex { out += "…" }
        return out
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
