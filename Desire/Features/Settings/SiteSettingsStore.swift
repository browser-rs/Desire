import Combine
import Foundation

struct SiteSettings: Codable {
    var zoom: Double
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
            settings.removeValue(forKey: domain)
        } else {
            settings[domain] = SiteSettings(zoom: zoom)
        }
        save()
    }

    func resetAll() {
        settings.removeAll()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
