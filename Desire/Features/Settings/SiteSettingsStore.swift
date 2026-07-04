import Combine
import Foundation

struct SiteSettings: Codable {
    var zoom: Double
    var darkMode: Bool = false
}

@MainActor
class SiteSettingsStore: ObservableObject {
    @Published private var settings: [String: SiteSettings] = [:]

    private let key = "desire.siteSettings"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let settings = try? JSONDecoder().decode([String: SiteSettings].self, from: data) {
            self.settings = settings
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

    func resetAll() {
        settings.removeAll()
        save()
    }

    private func cleanEmpty(_ domain: String) {
        if let s = settings[domain], s.zoom == 1.0, !s.darkMode {
            settings.removeValue(forKey: domain)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
