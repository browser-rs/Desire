import Foundation
import Combine

/// Privacy settings that control tracking protection, cookie behavior, and HTTPS upgrade.
@MainActor
class PrivacySettings: ObservableObject, Codable {
    // Tracking protection
    @Published var blockSocialMediaTrackers: Bool = true
    @Published var blockAnalyticsTrackers: Bool = true
    @Published var blockFingerprinting: Bool = true
    @Published var blockCryptominers: Bool = true
    
    // Cookie settings
    @Published var blockThirdPartyCookies: Bool = true
    @Published var cookieAcceptPolicy: CookieAcceptPolicy = .onlyFromMainDocumentDomain
    
    // HTTPS upgrade
    @Published var enforceHTTPS: Bool = true
    
    // Privacy mode (use PrivacyModeState from PrivacyMode feature)
    @Published var defaultPrivacyModeEnabled: Bool = false
    
    enum CookieAcceptPolicy: String, Codable, CaseIterable {
        case always
        case never
        case onlyFromMainDocumentDomain
        
        var displayName: String {
            switch self {
            case .always: String(localized: "Always accept")
            case .never: String(localized: "Never accept")
            case .onlyFromMainDocumentDomain: String(localized: "Only from same domain")
            }
        }
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case blockSocialMediaTrackers
        case blockAnalyticsTrackers
        case blockFingerprinting
        case blockCryptominers
        case blockThirdPartyCookies
        case cookieAcceptPolicy
        case enforceHTTPS
        case defaultPrivacyModeEnabled
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blockSocialMediaTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockSocialMediaTrackers) ?? true
        blockAnalyticsTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockAnalyticsTrackers) ?? true
        blockFingerprinting = try container.decodeIfPresent(Bool.self, forKey: .blockFingerprinting) ?? true
        blockCryptominers = try container.decodeIfPresent(Bool.self, forKey: .blockCryptominers) ?? true
        blockThirdPartyCookies = try container.decodeIfPresent(Bool.self, forKey: .blockThirdPartyCookies) ?? true
        cookieAcceptPolicy = try container.decodeIfPresent(CookieAcceptPolicy.self, forKey: .cookieAcceptPolicy) ?? .onlyFromMainDocumentDomain
        enforceHTTPS = try container.decodeIfPresent(Bool.self, forKey: .enforceHTTPS) ?? true
        defaultPrivacyModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .defaultPrivacyModeEnabled) ?? false
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blockSocialMediaTrackers, forKey: .blockSocialMediaTrackers)
        try container.encode(blockAnalyticsTrackers, forKey: .blockAnalyticsTrackers)
        try container.encode(blockFingerprinting, forKey: .blockFingerprinting)
        try container.encode(blockCryptominers, forKey: .blockCryptominers)
        try container.encode(blockThirdPartyCookies, forKey: .blockThirdPartyCookies)
        try container.encode(cookieAcceptPolicy, forKey: .cookieAcceptPolicy)
        try container.encode(enforceHTTPS, forKey: .enforceHTTPS)
        try container.encode(defaultPrivacyModeEnabled, forKey: .defaultPrivacyModeEnabled)
    }
    
    init() {}
    
    // MARK: - Persistence

    private static let storageKey = "privacySettings"

    func save() {
        DiskStore.save(self, key: Self.storageKey)
    }

    static func load() -> PrivacySettings {
        if let settings = DiskStore.load(PrivacySettings.self, key: storageKey) {
            return settings
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let settings = try? JSONDecoder().decode(PrivacySettings.self, from: data) {
            DiskStore.save(settings, key: storageKey)
            UserDefaults.standard.removeObject(forKey: storageKey)
            return settings
        }
        return PrivacySettings()
    }
}