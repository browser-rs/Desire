import Combine
import Foundation

enum PermissionDecision: String, Codable {
    case allow, deny
}

enum PermissionType: String, Codable {
    case camera, microphone, cameraAndMicrophone, geolocation
}

struct PermissionRule: Codable {
    let host: String
    let type: PermissionType
    let decision: PermissionDecision
}

@MainActor
class PermissionStore: ObservableObject {
    @Published private(set) var rules: [PermissionRule] = []

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let key = "desire.permissionRules"

    init() {
        if let decoded = DiskStore.load([PermissionRule].self, key: key) {
            rules = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PermissionRule].self, from: data) {
            rules = decoded
            save()
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func decision(for host: String, type: PermissionType) -> PermissionDecision? {
        rules.first(where: { $0.host == host && $0.type == type })?.decision
    }

    func set(host: String, type: PermissionType, decision: PermissionDecision) {
        rules.removeAll { $0.host == host && $0.type == type }
        rules.append(PermissionRule(host: host, type: type, decision: decision))
        save()
    }

    func remove(host: String) {
        rules.removeAll { $0.host == host }
        save()
    }

    func removeAll() {
        rules.removeAll()
        save()
    }

    private func save() {
        DiskStore.save(rules, key: key)
    }
}
