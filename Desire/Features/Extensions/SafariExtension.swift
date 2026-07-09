import Foundation

/// Safari Web Extension 数据模型
/// 兼容 manifest.json (Web Extensions API)
struct SafariExtension: Identifiable, Codable {
    let id: UUID
    var manifest: ExtensionManifest
    var localizedName: String { manifest.name }
    var localizedDescription: String { manifest.description ?? "" }
    var version: String { manifest.version }
    var isEnabled: Bool
    var installedAt: Date
    var bundleURL: URL? // 扩展包路径（.safariextension 或解压后的目录）

    init(id: UUID = UUID(), manifest: ExtensionManifest, isEnabled: Bool = true, installedAt: Date = Date(), bundleURL: URL? = nil) {
        self.id = id
        self.manifest = manifest
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.bundleURL = bundleURL
    }

    /// 权限状态
    var permissionsGranted: Set<String> = []
    var hostPermissionsGranted: Set<String> = []

    /// 需要请求的权限
    var requiredPermissions: [String] { manifest.permissions ?? [] }
    var requiredHostPermissions: [String] { manifest.host_permissions ?? [] }

    /// 是否需要权限请求
    var needsPermissionRequest: Bool {
        let required = Set(requiredPermissions)
        let granted = permissionsGranted
        return !required.isSubset(of: granted)
    }

    /// 是否需要主机权限请求
    var needsHostPermissionRequest: Bool {
        let required = Set(requiredHostPermissions)
        let granted = hostPermissionsGranted
        return !required.isSubset(of: granted)
    }
}

// MARK: - Extension Manifest (manifest.json)

struct ExtensionManifest: Codable {
    let manifest_version: Int
    let name: String
    let version: String
    let description: String?
    let author: String?

    // Icons
    let icons: [String: String]?
    let action: ExtensionAction?
    let browser_action: ExtensionAction? // Legacy (V2)

    // Background
    let background: ExtensionBackground?

    // Content Scripts
    let content_scripts: [ContentScript]?

    // Permissions
    let permissions: [String]?
    let host_permissions: [String]? // V3
    let optional_permissions: [String]?
    let optional_host_permissions: [String]?

    // Web Accessible Resources
    let web_accessible_resources: [WebAccessibleResource]?

    // Content Security Policy
    let content_security_policy: ContentSecurityPolicy?

    // Options
    let options_ui: OptionsUI?
    let options_page: String?

    // Commands (Keyboard Shortcuts)
    let commands: [String: ExtensionCommand]?

    // Storage
    let storage: ExtensionStorage?

    // Version info
    let minimum_chrome_version: String?
    let browser_specific_settings: BrowserSpecificSettings?
}

// MARK: - Manifest Components

struct ExtensionAction: Codable {
    let default_icon: IconDefinition?
    let default_title: String?
    let default_popup: String?
    let default_badge_text: String?
    let default_badge_background_color: String?
}

struct IconDefinition: Codable {
    let defaultIcon: String?
    let sizes: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case defaultIcon = "default"
        case sizes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            defaultIcon = str
            sizes = nil
        } else if let dict = try? container.decode([String: String].self) {
            defaultIcon = nil
            sizes = dict
        } else {
            defaultIcon = nil
            sizes = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let defaultIcon = defaultIcon {
            try container.encode(defaultIcon)
        } else if let sizes = sizes {
            try container.encode(sizes)
        }
    }
}

struct ExtensionBackground: Codable {
    let scripts: [String]? // V2
    let service_worker: String? // V3
    let page: String?
    let persistent: Bool?
    let type: String?
}

struct ContentScript: Codable {
    let matches: [String]
    let exclude_matches: [String]?
    let js: [String]?
    let css: [String]?
    let run_at: RunAt?
    let all_frames: Bool?
    let match_about_blank: Bool?

    enum RunAt: String, Codable {
        case document_start = "document_start"
        case document_end = "document_end"
        case document_idle = "document_idle"
    }
}

struct WebAccessibleResource: Codable {
    let resources: [String]
    let matches: [String]?
    let extension_ids: [String]?
}

struct ContentSecurityPolicy: Codable {
    let extension_pages: String?
    let sandbox: String?
}

struct OptionsUI: Codable {
    let page: String
    let open_in_tab: Bool?
    let browser_style: Bool?
}

struct ExtensionCommand: Codable {
    let suggested_key: SuggestedKey?
    let description: String?
}

struct SuggestedKey: Codable {
    let `default`: String?
    let mac: String?
    let windows: String?
    let linux: String?
}

struct ExtensionStorage: Codable {
    let managed_schema: String?
}

struct BrowserSpecificSettings: Codable {
    let safari: SafariSettings?
    let gecko: GeckoSettings?

    struct SafariSettings: Codable {
        let strict_min_version: String?
    }

    struct GeckoSettings: Codable {
        let strict_min_version: String?
        let id: String?
    }
}