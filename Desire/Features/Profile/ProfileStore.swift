import Combine
import Foundation
import WebKit
import os

/// A named browsing persona (Profile): scopes the default data store,
/// bookmarks, history, and other browsing data to a persona (work, personal,
/// etc.). Containers are per-tab; Profiles are per-window.
struct DesireProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var colorIndex: Int
    var createdAt: Date

    static let palette: [String] = [
        "blue", "green", "orange", "purple", "pink", "red", "teal", "indigo",
    ]

    var colorName: String { Self.palette[abs(colorIndex) % Self.palette.count] }
}

/// Store for browsing profiles. Each profile owns a persistent
/// `WKWebsiteDataStore` — cookies, sessions, and site storage are fully
/// isolated per profile. The default profile (nil) uses the system default.
@MainActor
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published private(set) var profiles: [DesireProfile] = []
    @Published var activeProfileID: UUID?

    private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    private static let storageKey = "desire-profiles"

    private init() {
        profiles = DiskStore.load([DesireProfile].self, key: Self.storageKey) ?? []
    }

    private func save() {
        DiskStore.save(profiles, key: Self.storageKey)
    }

    func profile(for id: UUID?) -> DesireProfile? {
        guard let id else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    func profile(named name: String) -> DesireProfile? {
        profiles.first(where: { $0.name.lowercased() == name.lowercased() })
    }

    @discardableResult
    func addProfile(name: String) -> DesireProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = DesireProfile(
            id: UUID(), name: trimmed,
            colorIndex: profiles.count % DesireProfile.palette.count,
            createdAt: Date())
        profiles.append(profile)
        save()
        return profile
    }

    func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        save()
        dataStores.removeValue(forKey: id)
        // 清该人物的各数据桶（0.3.5）：书签/历史/快拨 + webext 存储。
        // Chrome 语义：删人物即删其数据。
        if let active = activeProfileID, active == id {
            activeProfileID = nil
            UserDefaults.standard.removeObject(forKey: "desire.activeProfile")
        }
        for key in Self.scopedBucketKeys(id: id) {
            DiskStore.remove(key: key)
        }
        UserDefaults.standard.removeObject(forKey: "desire.webext.storage.\(id.uuidString)")
    }

    /// 与各 store 的 scopedKey 规则保持一致（新增作用域 store 时同步）。
    static func scopedBucketKeys(id: UUID) -> [String] {
        ["bookmarks.\(id.uuidString)", "history.\(id.uuidString)",
         "desire.quickdials.\(id.uuidString)"]
    }

    /// The persistent data store for a profile. Each profile gets its own
    /// `WKWebsiteDataStore(forIdentifier:)` so cookies/sessions are fully
    /// isolated. Falls back to `.default()` for nil/Default.
    func dataStore(for profileID: UUID?) -> WKWebsiteDataStore {
        guard let pid = profileID, profiles.contains(where: { $0.id == pid }) else {
            return .default()
        }
        if let cached = dataStores[pid] { return cached }
        let store = WKWebsiteDataStore(forIdentifier: pid)
        dataStores[pid] = store
        return store
    }
}
