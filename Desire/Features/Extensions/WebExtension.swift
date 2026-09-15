import Foundation

/// An installed WebExtension (manifest.json folder, MV2/MV3 subset).
struct WebExtension: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var version: String
    /// Security-scoped bookmark back to the unpacked extension folder.
    var folderBookmark: Data
    var isEnabled: Bool
    /// Content scripts from the manifest (js/css + match patterns).
    var contentScripts: [ContentScript]
    /// Raw manifest.json — served to `chrome.runtime.getManifest`.
    var manifestJSON: String
    /// browser_action/action.default_popup (relative path), if any.
    var popupPath: String? = nil
    /// background.page (MV2), if any.
    var backgroundPage: String? = nil
    /// background.scripts + background.service_worker (MV2/MV3), if any.
    var backgroundScripts: [String] = []

    /// True when the manifest declares any background context.
    var hasBackground: Bool {
        backgroundPage != nil || !backgroundScripts.isEmpty
    }

    struct ContentScript: Codable, Equatable {
        var matches: [String]
        var js: [String]
        var css: [String]
        /// "document_start" | "document_end" (default).
        var runAt: String?

        enum CodingKeys: String, CodingKey {
            case matches, js, css
            case runAt = "run_at"
        }

        init(matches: [String], js: [String], css: [String], runAt: String? = nil) {
            self.matches = matches
            self.js = js
            self.css = css
            self.runAt = runAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            matches = try container.decodeIfPresent([String].self, forKey: .matches) ?? []
            js = try container.decodeIfPresent([String].self, forKey: .js) ?? []
            css = try container.decodeIfPresent([String].self, forKey: .css) ?? []
            runAt = try container.decodeIfPresent(String.self, forKey: .runAt)
        }
    }
}

/// Decoded manifest.json (snake_case keys).
struct WebExtensionManifest: Codable {
    var name: String?
    var version: String?
    var manifestVersion: Int?
    var contentScripts: [WebExtension.ContentScript]?
    var background: BackgroundConfig?
    var browserAction: BrowserActionConfig?
    var action: BrowserActionConfig?

    struct BackgroundConfig: Codable {
        var page: String?
        var scripts: [String]?
        var serviceWorker: String?
        enum CodingKeys: String, CodingKey {
            case page, scripts
            case serviceWorker = "service_worker"
        }
    }

    struct BrowserActionConfig: Codable {
        var defaultPopup: String?
        enum CodingKeys: String, CodingKey {
            case defaultPopup = "default_popup"
        }
    }

    var backgroundScripts: [String] {
        var files: [String] = []
        if let s = background?.scripts { files += s }
        if let w = background?.serviceWorker { files.append(w) }
        return files
    }

    var popupPath: String? {
        browserAction?.defaultPopup ?? action?.defaultPopup
    }
}
