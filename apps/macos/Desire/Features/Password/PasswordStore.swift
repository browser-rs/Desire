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
        // **只列元数据，不读密码**（2026-10-22）：读 data 会为每条条目弹一次
        // 钥匙串授权；旧实现启动时 readAll 把 service 下 26 条（含 AI Key/
        // 同步令牌/网站密码）全读一遍，用户看到"每条不同的 key 各弹一次"。
        // 密码在显示/复制/填入/导出时按需读（一次一条）。
        loadMetadata()
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

    /// 某域名下的存档凭据。
    /// `loadSecrets`：true 时对命中条目按需读取密码（一次一条；用于登录提交
    /// / Agent fillLogin 这类用户动作）。**页面加载中的自动填充必须传 false**
    /// ——读 data 会弹授权，不能因为打开一个登录页就打扰用户。
    func find(domain: String, loadSecrets: Bool = true, interactive: Bool = true) -> [PasswordEntry] {
        var matches = entries.filter {
            $0.domain == domain || $0.domain.hasSuffix("." + domain) || domain.hasSuffix("." + $0.domain)
        }
        guard loadSecrets else { return matches }
        for i in matches.indices where matches[i].password.isEmpty {
            if let p = readPassword(domain: matches[i].domain,
                                    username: matches[i].username,
                                    interactive: interactive) {
                matches[i].password = p
                if let index = entries.firstIndex(where: { $0.id == matches[i].id }) {
                    entries[index].password = p
                }
            }
        }
        return matches
    }

    /// 单条密码的按需读取（面板显示/复制用）。读到的值回填内存，之后不再读。
    func password(for entry: PasswordEntry, interactive: Bool = true) -> String? {
        if !entry.password.isEmpty { return entry.password }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        if !entries[index].password.isEmpty { return entries[index].password }
        guard let p = readPassword(domain: entries[index].domain,
                                   username: entries[index].username,
                                   interactive: interactive) else { return nil }
        entries[index].password = p
        return p
    }

    private func readPassword(domain: String, username: String, interactive: Bool) -> String? {
        KeychainService.readString(account: username, service: serviceName,
                                   server: domain, httpsOnly: true, interactive: interactive)
    }

    /// 显式动作（CSV 导出）前把所有密码读进内存——会逐条触发授权，**绝不能
    /// 放在启动/自动路径**。
    func loadAllSecrets() {
        for index in entries.indices where entries[index].password.isEmpty {
            if let p = readPassword(domain: entries[index].domain,
                                    username: entries[index].username,
                                    interactive: true) {
                entries[index].password = p
            }
        }
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
    /// 显式导出：先把密码按需读齐（会逐条触发授权，仅此路径允许）。
    func exportCSV() -> String {
        loadAllSecrets()
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

    private func loadMetadata() {
        // 属性枚举：拿到域名/用户名用于列表，**不取密码**（无授权弹窗）。
        // httpsOnly 排除同一 service 下的 AI Key / 同步令牌条目。
        entries = KeychainService.listAttributes(service: serviceName, httpsOnly: true).map {
            PasswordEntry(id: UUID(), domain: $0.server, username: $0.account,
                          password: "", createdAt: Date())
        }
    }
}
