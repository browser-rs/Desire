import Foundation

/// Privacy mode state model
struct PrivacyModeState: Codable {
    var isEnabled: Bool = false
    var blockThirdPartyCookies: Bool = true
    var blockAllCookies: Bool = false
    var preventCrossSiteTracking: Bool = true
    var hideIPAddress: Bool = false
    var disableWebRTC: Bool = false
}

/// Cookie accept policy options
enum CookieAcceptPolicy: String, Codable, CaseIterable {
    case always = "always"
    case never = "never"
    case onlyFromMainDocumentDomain = "onlyFromMainDocumentDomain"

    var displayName: String {
        switch self {
        case .always: return "Always Accept"
        case .never: return "Never Accept"
        case .onlyFromMainDocumentDomain: return "Block Third-Party Cookies"
        }
    }
}