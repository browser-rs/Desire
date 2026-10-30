import Foundation

/// 摩斯电码编解码——纯逻辑。
nonisolated enum MorseCore {
    static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.",
        "G": "--.", "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..",
        "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
        "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "'": ".----.", "!": "-.-.--",
        "/": "-..-.", "(": "-.--.", ")": "-.--.-", "&": ".-...", ":": "---...",
        ";": "-.-.-.", "=": "-...-", "+": ".-.-.", "-": "-....-", "_": "..--.-",
        "\"": ".-..-.", "$": "...-..-", "@": ".--.-.",
    ]

    static func encode(_ text: String) -> String {
        let words = text.uppercased().components(separatedBy: " ")
        var encodedWords: [String] = []
        for word in words {
            var letters: [String] = []
            for character in word {
                if let code = table[character] {
                    letters.append(code)
                }
            }
            if !letters.isEmpty { encodedWords.append(letters.joined(separator: " ")) }
        }
        return encodedWords.joined(separator: " / ")
    }

    static func decode(_ text: String) -> Result<String, ToolboxError> {
        let reverse = Dictionary(uniqueKeysWithValues: table.map { ($0.value, $0.key) })
        var output = ""
        let words = text.components(separatedBy: "/")
        for (index, word) in words.enumerated() {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if index > 0 { output.append(" ") }
            var letters = ""
            for token in trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
                guard let character = reverse[String(token)] else {
                    return .failure(ToolboxError(message: "Unknown Morse code: \(token)"))
                }
                letters.append(character)
            }
            output += letters
        }
        return .success(output)
    }
}
