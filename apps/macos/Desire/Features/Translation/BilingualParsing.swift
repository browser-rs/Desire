import Foundation

/// 双语对照翻译输出的**解析纯逻辑**（进单测 harness）。
enum BilingualParsing {

    /// 模型输出 → 与期望条数对齐的译文数组。
    /// 优先整段里的 JSON 数组（容忍 ```json 围栏与前后杂散文字）；JSON 失败
    /// 时按行回退（剥掉 "12. " / "12) " 编号前缀）。**条数不等一律返回 nil**
    /// ——整批丢弃而不是错位落到页面上（对齐错误比没翻译更伤）。
    static func parseTranslations(_ raw: String, expected: Int) -> [String]? {
        guard expected > 0 else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let array = jsonArray(in: trimmed) {
            return array.count == expected ? array : nil
        }
        let lines = trimmed.split(separator: "\n").map { line -> String in
            var text = String(line).trimmingCharacters(in: .whitespaces)
            if let match = text.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
                text.removeSubrange(match)
            }
            return text
        }.filter { !$0.isEmpty }
        return lines.count == expected ? lines : nil
    }

    private static func jsonArray(in text: String) -> [String]? {
        var candidate = text
        if let start = candidate.firstIndex(of: "["), let end = candidate.lastIndex(of: "]"), start < end {
            candidate = String(candidate[start...end])
        }
        guard let data = candidate.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        return array.map { ($0 as? String) ?? String(describing: $0) }
    }
}
