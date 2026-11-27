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
    /// 弹窗（`window.open` / `target=_blank`，v0.8.80）：未设置 = 允许（既有行为），
    /// deny = 拦截。WebKit 不会问用户，开不开窗完全由宿主决定——所以这一类是
    /// 真权限，不需要系统提示。
    case popups
    /// 剪贴板读取（v0.8.80）：WebKit **没有**剪贴板权限 API（`permissions.query`
    /// 对 `clipboard-read` 抛 TypeError），无用户手势时读取本身就被平台拒绝。
    /// deny 时注入页面脚本把 `navigator.clipboard.readText/read` 改为拒绝——
    /// 只能"拦截"，不能"强制允许"。
    case clipboardRead
}

extension PermissionType {
    /// 矩阵列 / 锁弹层的图标。
    var systemImage: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .cameraAndMicrophone: "video.badge.ellipsis"
        case .geolocation: "location"
        case .popups: "arrow.up.forward.square"
        case .clipboardRead: "doc.on.clipboard"
        }
    }

    var displayName: String {
        switch self {
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        case .cameraAndMicrophone: String(localized: "Camera & Microphone")
        case .geolocation: String(localized: "Location")
        case .popups: String(localized: "Popups")
        case .clipboardRead: String(localized: "Clipboard Read")
        }
    }
}
