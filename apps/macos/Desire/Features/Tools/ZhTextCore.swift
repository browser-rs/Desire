import Foundation

/// 中文文本工具（v0.8.33 文本批）：简繁转换、拼音、中文排版清理。
/// 转换用系统 ICU transform（字符级；一简对多繁的专名需人工核对）。
/// 纯 Foundation、进 tests/run.sh。
nonisolated enum ZhTextCore {

    enum PinyinStyle: String, CaseIterable, Identifiable, Sendable {
        case toneMarks, plain, initials
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .toneMarks: return String(localized: "Tone marks")
            case .plain: return String(localized: "Plain pinyin")
            case .initials: return String(localized: "Initials")
            }
        }
    }

    struct TypographyOptions: OptionSet, Sendable {
        let rawValue: Int
        static let cjkLatinSpacing = TypographyOptions(rawValue: 1 << 0)
        static let removeCJKSpace = TypographyOptions(rawValue: 1 << 1)
        static let fullWidthPunctuation = TypographyOptions(rawValue: 1 << 2)
        static let trimTrailing = TypographyOptions(rawValue: 1 << 3)
        static let collapseBlankLines = TypographyOptions(rawValue: 1 << 4)
        static let all: TypographyOptions = [
            .cjkLatinSpacing, .removeCJKSpace, .fullWidthPunctuation,
            .trimTrailing, .collapseBlankLines,
        ]
    }

    // MARK: - 简繁

    static func simplifiedToTraditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: false)
            ?? text
    }

    static func traditionalToSimplified(_ text: String) -> String {
        text.applyingTransform(StringTransform("Simplified-Traditional"), reverse: true)
            ?? text
    }

    // MARK: - 拼音

    static func pinyin(_ text: String, style: PinyinStyle) -> String {
        let latin = text.applyingTransform(.mandarinToLatin, reverse: false) ?? text
        switch style {
        case .toneMarks:
            return latin
        case .plain:
            return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        case .initials:
            return latin.components(separatedBy: " ").map { token in
                guard let first = token.first(where: { $0.isLetter }) else { return token }
                return String(first)
            }.joined(separator: " ")
        }
    }

    // MARK: - 排版

    static func typography(_ text: String, options: TypographyOptions = .all) -> String {
        var output = text
        if options.contains(.trimTrailing) {
            output = output.components(separatedBy: "\n").map { line in
                line.replacingOccurrences(of: "[ \\t]+$", with: "",
                                          options: .regularExpression)
            }.joined(separator: "\n")
        }
        if options.contains(.fullWidthPunctuation) {
            output = normalizePunctuation(output)
        }
        if options.contains(.cjkLatinSpacing) {
            output = addCJKLatinSpacing(output)
        }
        if options.contains(.removeCJKSpace) {
            output = removeSpacesBetweenCJK(output)
        }
        if options.contains(.collapseBlankLines) {
            while output.contains("\n\n\n") {
                output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
        }
        return output
    }

    /// 半角 `, . ; : ! ?` 在中文后面 → 全角。
    private static func normalizePunctuation(_ text: String) -> String {
        let map: [Character: Character] = [
            ",": "，", ".": "。", ";": "；", ":": "：", "!": "！", "?": "？",
        ]
        var output = ""
        var previous: Character?
        for character in text {
            if let fullWidth = map[character],
               let last = previous, isCJKIdeograph(last) {
                output.append(fullWidth)
            } else {
                output.append(character)
            }
            if !character.isWhitespace { previous = character }
        }
        return output
    }

    /// 中文与 ASCII 字母/数字之间补一个空格。
    private static func addCJKLatinSpacing(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        for (index, character) in characters.enumerated() {
            if index > 0 {
                let previous = characters[index - 1]
                let previousIsCJK = isCJKIdeograph(previous)
                let currentIsCJK = isCJKIdeograph(character)
                let previousIsLatin = isASCIIAlphanumeric(previous)
                let currentIsLatin = isASCIIAlphanumeric(character)
                if (previousIsCJK && currentIsLatin) || (previousIsLatin && currentIsCJK) {
                    output.append(" ")
                }
            }
            output.append(character)
        }
        return output
    }

    /// 去掉两个汉字之间的空格。
    private static func removeSpacesBetweenCJK(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                var next = index
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                let previousIsCJK = output.last.map(isCJKIdeograph) ?? false
                let nextIsCJK = next < characters.count && isCJKIdeograph(characters[next])
                if previousIsCJK && nextIsCJK {
                    index = next
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func isCJKIdeograph(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
