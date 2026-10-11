import Foundation

enum BearerAuthentication {
    static func matches(header: String?, token: String) -> Bool {
        guard let header, !token.isEmpty else { return false }
        let parts = header.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else {
            return false
        }
        let credential = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAmbiguousCharacter = credential.contains(" ")
            || credential.contains("\t")
            || credential.contains(",")
        guard !credential.isEmpty, !hasAmbiguousCharacter else {
            return false
        }
        return credential == token
    }
}
