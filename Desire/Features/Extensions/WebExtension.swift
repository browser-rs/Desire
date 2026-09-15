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

    struct ContentScript: Codable, Equatable {
        var matches: [String]
        var js: [String]
        var css: [String]

        enum CodingKeys: String, CodingKey {
            case matches, js, css
        }

        init(matches: [String], js: [String], css: [String]) {
            self.matches = matches
            self.js = js
            self.css = css
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            matches = try container.decodeIfPresent([String].self, forKey: .matches) ?? []
            js = try container.decodeIfPresent([String].self, forKey: .js) ?? []
            css = try container.decodeIfPresent([String].self, forKey: .css) ?? []
        }
    }
}

/// Decoded manifest.json (snake_case keys).
struct WebExtensionManifest: Codable {
    var name: String?
    var version: String?
    var manifestVersion: Int?
    var contentScripts: [WebExtension.ContentScript]?
}
