import Combine
import Foundation
import Security

@MainActor
class PasswordStore: ObservableObject {
    @Published var entries: [PasswordEntry] = []

    private let serviceName = "me.siwi.Desire"

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
