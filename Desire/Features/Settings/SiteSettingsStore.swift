import Combine
import Foundation

@MainActor
class SiteSettingsStore: ObservableObject {
    @Published private var settings: [String: SiteSettings] = [:]

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let key = "desire.siteSettings"

    init() {
        if let decoded = DiskStore.load([String: SiteSettings].self, key: key) {
            settings = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: SiteSettings].self, from: data) {
            settings = decoded
            save()
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func zoom(for domain: String) -> Double {
        settings[domain]?.zoom ?? 1.0
    }

    func setZoom(_ zoom: Double, for domain: String) {
        if zoom == 1.0 {
            settings[domain]?.zoom = 1.0
            cleanEmpty(domain)
        } else {
            var s = settings[domain] ?? SiteSettings(zoom: 1.0)
            s.zoom = zoom
            settings[domain] = s
        }
        save()
    }

    func darkModeEnabled(for domain: String) -> Bool {
        settings[domain]?.darkMode ?? false
    }

    func setDarkMode(_ enabled: Bool, for domain: String) {
        if enabled {
            var s = settings[domain] ?? SiteSettings(zoom: 1.0)
            s.darkMode = true
            settings[domain] = s
        } else {
            settings[domain]?.darkMode = false
            cleanEmpty(domain)
        }
        save()
        objectWillChange.send()
    }

    func blockedSelectors(for domain: String) -> [String] {
        settings[domain]?.blockedSelectors ?? []
    }

    func addBlockedSelector(_ selector: String, for domain: String) {
        var s = settings[domain] ?? SiteSettings(zoom: 1.0)
        if !s.blockedSelectors.contains(selector) {
            s.blockedSelectors.append(selector)
            settings[domain] = s
            save()
            objectWillChange.send()
        }
    }

    func removeBlockedSelector(_ selector: String, for domain: String) {
        settings[domain]?.blockedSelectors.removeAll { $0 == selector }
        cleanEmpty(domain)
        save()
        objectWillChange.send()
    }

    func resetAll() {
        settings.removeAll()
        save()
    }

    private func cleanEmpty(_ domain: String) {
        if let s = settings[domain], s.zoom == 1.0, !s.darkMode, s.blockedSelectors.isEmpty {
            settings.removeValue(forKey: domain)
        }
    }

    private func save() {
        DiskStore.save(settings, key: key)
    }
}
