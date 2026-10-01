import Combine
import Foundation
import os
import LocalAuthentication
import Security

/// A save/update-password prompt awaiting a decision. The prompt presents as
/// a non-modal bar (a blocking runModal here froze the whole app — and the
/// automation bridge — on every login submit); `respond` is single-fire.
/// `isUpdate` marks the password-change case: the username already has a
/// stored credential whose password differs from the submitted one.
@MainActor
final class PendingPasswordSave {
    let domain: String
    let username: String
    let isUpdate: Bool
    var programmaticDismiss: (() -> Void)?

    private let completion: (Bool) -> Void
    private var resolved = false

    init(domain: String, username: String, isUpdate: Bool = false, completion: @escaping (Bool) -> Void) {
        self.isUpdate = isUpdate
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

    /// Rewrites a stored credential in place (password-change flow). The
    /// keychain path deletes then re-adds, so this is safe to call on an
    /// entry that is already persisted.
    func updatePassword(_ entry: PasswordEntry, to newPassword: String) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].password = newPassword
        addToKeychain(domain: entry.domain, username: entry.username, password: newPassword)
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
        for _ in stride(from: 0, to: length * 2, by: buffer.count) {
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
    /// The header is skipped only when actually present.
    @discardableResult
    func importCSV(_ csv: String) -> Int {
        var imported = 0
        let csv = csv.hasPrefix("\u{FEFF}") ? String(csv.dropFirst()) : csv
        var lines = csv.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // P1-11：按**表头**映射列——此前写死 Chrome 列序（url/name/username/
        // password），Firefox 导出（url,username,password,…）会把 username 当
        // domain、时间戳当 password 真实写进 Keychain。
        var col: (url: Int, username: Int, password: Int) = (1, 2, 3)  // Chrome 缺省
        if let first = lines.first,
           let header = parseCSVLine(first).map({ $0.lowercased() }) as [String]? {
            func idx(_ keys: [String]) -> Int? {
                header.firstIndex { h in keys.contains { h.contains($0) } }
            }
            if let u = idx(["url"]), let un = idx(["username", "login", "user"]),
               let p = idx(["password"]) {
                col = (u, un, p)
            }
            if header.contains("username") && header.contains("password") {
                lines.removeFirst()
            }
        }

        for line in lines {
            let fields = parseCSVLine(line)
            guard fields.count > max(col.url, col.username, col.password) else { continue }
            let rawURL = fields[col.url]
            let username = fields[col.username]
            let password = fields[col.password]
            guard !username.isEmpty, !password.isEmpty else { continue }
            // Extract host from the URL column (may be full URL or bare domain).
            let host: String
            if let url = URL(string: rawURL), let h = url.host {
                host = h
            } else {
                host = rawURL
            }
            guard !host.isEmpty else { continue }
            save(domain: host, username: username, password: password)
            imported += 1
        }
        return imported
    }

    /// RFC-4180-style single-line parser: double quotes toggle quoting,
    /// `""` inside quotes is a literal quote, commas only split when unquoted.
    /// (The previous version only looked for single quotes and never
    /// toggled; an iterator-peek rewrite then ate the character following a
    /// closing quote — index-based walk keeps the lookahead side-effect free.)
    private func parseCSVLine(_ line: String) -> [String] {
        let chars = Array(line)
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if inQuotes {
                if char == "\"", i + 1 < chars.count, chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 2
                    continue
                }
                if char == "\"" { inQuotes = false } else { current.append(char) }
            } else if char == "\"" {
                inQuotes = true
            } else if char == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            i += 1
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

        // P0-C：必须带 kSecAttrService——loadAll 按 service 过滤，缺了它写入的
        // 条目重启后永远读不回来（存得进读不出，实测类数据丢失）。
        let status = KeychainService.write(passwordData, account: username,
                                           service: serviceName, server: domain,
                                           httpsProtocol: true)
        if status != errSecSuccess {
            Log.app.error("password keychain add failed: \(status, privacy: .public)")
        }
    }

    private func findFromKeychain(domain: String, username: String) -> String? {
        // 旧语义保留：按 server+account 查找、不过滤 service（service: nil）。
        KeychainService.readString(account: username, service: nil, server: domain, interactive: true)
    }

    private func deleteFromKeychain(domain: String, username: String) {
        KeychainService.delete(account: username, service: nil, server: domain)
    }

    private func loadAll() {
        // init 在启动路径上跑 → 非交互枚举（ACL 失配失败成空面板，
        // 用户重存/授权一次即恢复——2026-09-24 隐窗授权教训）。
        entries = KeychainService.readAll(service: serviceName).map {
            PasswordEntry(id: UUID(), domain: $0.server, username: $0.account,
                          password: String(data: $0.data, encoding: .utf8) ?? "", createdAt: Date())
        }
    }
}
