import Combine
import Foundation
import Security

/// A save-password prompt awaiting a decision. The prompt presents as a
/// non-modal sheet (a blocking runModal here froze the whole app — and the
/// automation bridge — on every login submit); `respond` is single-fire.
@MainActor
final class PendingPasswordSave {
    let domain: String
    let username: String
    var programmaticDismiss: (() -> Void)?

    private let completion: (Bool) -> Void
    private var resolved = false

    init(domain: String, username: String, completion: @escaping (Bool) -> Void) {
        self.domain = domain
        self.username = username
        self.completion = completion
    }

    func respond(_ save: Bool) {
        guard !resolved else { return }
        resolved = true
        programmaticDismiss?()
        completion(save)
    }
}

@MainActor
class PasswordStore: ObservableObject {
    @Published var entries: [PasswordEntry] = []
    /// A save-password sheet awaiting the user's (or the automation bridge's)
    /// decision. nil when nothing is pending.
    @Published var pendingSave: PendingPasswordSave?

    private let serviceName = "me.siwi.Desire"
    private static let suppressedKey = "passwordSaveSuppressedDomains"

    /// Resolves the pending save-password prompt (bar button or bridge).
    func resolvePendingSave(_ save: Bool) {
        pendingSave?.respond(save)
    }

    /// Domains the user chose "Never for This Site" on.
    func isSuppressed(domain: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: Self.suppressedKey) ?? []).contains(domain)
    }

    func suppress(domain: String) {
        var list = UserDefaults.standard.stringArray(forKey: Self.suppressedKey) ?? []
        if !list.contains(domain) {
            list.append(domain)
            UserDefaults.standard.set(list, forKey: Self.suppressedKey)
        }
    }

    init() {
        loadAll()
    }

    func save(domain: String, username: String, password: String) {
        let entry = PasswordEntry(id: UUID(), domain: domain, username: username, password: password, createdAt: Date())
        addToKeychain(domain: domain, username: username, password: password)
        entries.insert(entry, at: 0)
    }

    func find(domain: String) -> [PasswordEntry] {
        entries.filter { $0.domain == domain || $0.domain.hasSuffix("." + domain) || domain.hasSuffix("." + $0.domain) }
    }

    func delete(_ entry: PasswordEntry) {
        deleteFromKeychain(domain: entry.domain, username: entry.username)
        entries.removeAll { $0.id == entry.id }
    }

    func clearAll() {
        for entry in entries {
            deleteFromKeychain(domain: entry.domain, username: entry.username)
        }
        entries.removeAll()
    }

    // MARK: - Password Center (0.2.6)

    /// Generates a cryptographically secure password.
    static func generatePassword(length: Int = 16, includeSymbols: Bool = true) -> String {
        let length = max(8, min(128, length))
        var chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        if includeSymbols { chars += Array("!@#$%^&*") }
        var result = ""
        var buffer = [UInt8](repeating: 0, count: length * 2)
        for offset in stride(from: 0, to: length * 2, by: buffer.count) {
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
            for byte in buffer where result.count < length {
                result.append(chars[Int(byte) % chars.count])
            }
        }
        return result
    }

    /// Exports all entries as CSV (Chrome-compatible column order).
    func exportCSV() -> String {
        var out = "name,url,username,password\n"
        for entry in entries {
            out += Self.csvLine([entry.domain, "https://" + entry.domain, entry.username, entry.password])
        }
        return out
    }

    /// Imports passwords from CSV (Chrome format: name,url,username,password).
    @discardableResult
    func importCSV(_ csv: String) -> Int {
        var imported = 0
        for line in csv.components(separatedBy: .newlines).dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count >= 4, !fields[1].isEmpty, !fields[3].isEmpty else { continue }
            // Extract host from the URL column (may be full URL or bare domain).
            let rawURL = fields[1]
            let host: String
            if let url = URL(string: rawURL), let h = url.host {
                host = h
            } else {
                host = rawURL
            }
            guard !host.isEmpty else { continue }
            save(domain: host, username: fields[2], password: fields[3])
            imported += 1
        }
        return imported
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "'" { current.append(char); continue }
            if char == "," && !inQuotes { fields.append(current); current = ""; continue }
            current.append(char)
        }
        fields.append(current)
        return fields
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            if field.contains(",") || field.contains("\"") || field.contains("\n") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: ",")
    }

    // MARK: - Keychain

    private func addToKeychain(domain: String, username: String, password: String) {
        guard let passwordData = password.data(using: .utf8) else { return }

        // Remove existing entry first
        deleteFromKeychain(domain: domain, username: username)

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecValueData as String: passwordData,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func findFromKeychain(domain: String, username: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return password
    }

    private func deleteFromKeychain(domain: String, username: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func loadAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            // Scope to OUR service name — an unfiltered kSecMatchLimitAll
            // query sweeps OTHER apps' internet passwords (and floods the
            // user with keychain access prompts).
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }

        entries = items.compactMap { dict in
            guard let domain = dict[kSecAttrServer as String] as? String,
                  let username = dict[kSecAttrAccount as String] as? String,
                  let passwordData = dict[kSecValueData as String] as? Data,
                  let password = String(data: passwordData, encoding: .utf8) else { return nil }
            return PasswordEntry(id: UUID(), domain: domain, username: username, password: password, createdAt: Date())
        }
    }
}
