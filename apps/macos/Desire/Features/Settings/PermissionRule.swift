import Foundation

/// A per-host permission decision (allow/deny) for a capability
/// (camera/microphone/geolocation), persisted by `PermissionStore`.
nonisolated struct PermissionRule: Codable {
    let host: String
    let type: PermissionType
    let decision: PermissionDecision
}

nonisolated enum PermissionDecision: String, Codable {
    case allow, deny
}

nonisolated enum PermissionType: String, Codable {
    case camera, microphone, cameraAndMicrophone, geolocation
}
