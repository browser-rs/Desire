import Foundation

/// 划词就地卡的模式与提示词（v0.7.25 旗舰）：纯逻辑（Foundation-only，进
/// harness）——模式判定、系统提示、用户提示都在这里定死，服务层只做流式调用。
nonisolated enum SelectionAssistMode: String, CaseIterable {
    case explain
    case translate
    case dictionary

    var title: String {
        switch self {
        case .explain: "解释"
        case .translate: "翻译"
        case .dictionary: "词典"
        }
    }

    /// 自动判定（"解释"入口用）：词级输入走词典（音标/词性/释义/例句），
    /// 句子/段落走解释。CJK ≤8 字且无空白 → 词；拉丁单 token ≤30 字符 → 词。
    static func detect(_ text: String) -> SelectionAssistMode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .explain }
        let hasCJK = trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if hasCJK {
            let hasWhitespace = trimmed.contains { $0.isWhitespace }
            return (!hasWhitespace && trimmed.count <= 8) ? .dictionary : .explain
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return (words.count == 1 && trimmed.count <= 30) ? .dictionary : .explain
    }

    static func systemPrompt(for mode: SelectionAssistMode) -> String {
        switch mode {
        case .explain:
            "You explain selected text in the user's language. Be concise and direct; no greetings, no restating the question."
        case .translate:
            "You are a translator. Output only the translation in the user's language; no notes, no quotes."
        case .dictionary:
            "You are a concise dictionary. Give pronunciation, part of speech, a one-line definition and one example sentence. Plain text, no greetings."
        }
    }

    static func userPrompt(for text: String, mode: SelectionAssistMode) -> String {
        switch mode {
        case .explain:
            "请用中文解释以下选中文本的含义，如有术语请一并说明：\n\n\(text)"
        case .translate:
            "将以下内容翻译成中文（若原文已是中文则翻译成英文），只输出译文：\n\n\(text)"
        case .dictionary:
            "给出这个词的读音、词性、简明释义与一个例句（中文说明）：\n\n\(text)"
        }
    }
}
