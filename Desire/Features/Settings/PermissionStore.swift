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

    private let key = "desire.permissionRules"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let rules = try? JSONDecoder().decode([PermissionRule].self, from: data) {
            self.rules = rules
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
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
