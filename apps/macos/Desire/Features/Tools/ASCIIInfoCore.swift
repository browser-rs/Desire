import Foundation

/// ASCII 码表查询——纯逻辑。
nonisolated enum ASCIIInfoCore {
    struct Entry: Equatable, Sendable {
        var decimal: Int
        var hex: String
        var character: String
        var description: String
    }

    private static let controlNames: [Int: String] = [
        0: "NUL", 1: "SOH", 2: "STX", 3: "ETX", 4: "EOT", 5: "ENQ", 6: "ACK",
        7: "BEL", 8: "BS", 9: "TAB", 10: "LF", 11: "VT", 12: "FF", 13: "CR",
        14: "SO", 15: "SI", 16: "DLE", 17: "DC1", 18: "DC2", 19: "DC3", 20: "DC4",
        21: "NAK", 22: "SYN", 23: "ETB", 24: "CAN", 25: "EM", 26: "SUB", 27: "ESC",
        28: "FS", 29: "GS", 30: "RS", 31: "US", 127: "DEL",
    ]

    static func entry(for code: Int) -> Entry? {
        guard (0...127).contains(code) else { return nil }
        let character: String
        let description: String
        if let name = controlNames[code] {
            character = code == 9 ? "⇥" : (code == 10 || code == 13 ? "↵" : "␀")
            description = name
        } else {
            character = String(UnicodeScalar(code)!)
            description = character
        }
        return Entry(decimal: code, hex: String(format: "%02X", code),
                     character: character, description: description)
    }

    static func entry(forCharacter character: Character) -> Entry? {
        guard let scalar = character.unicodeScalars.first,
              scalar.value <= 127 else { return nil }
        return entry(for: Int(scalar.value))
    }

    static func search(_ query: String) -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if let code = Int(trimmed), let entry = entry(for: code) {
            return [entry]
        }
        if trimmed.count == 1, let entry = entry(forCharacter: Character(trimmed)) {
            return [entry]
        }
        let needle = trimmed.uppercased()
        return (0...127).compactMap { code in
            guard let entry = entry(for: code),
                  entry.description.contains(needle) else { return nil }
            return entry
        }
    }
}
