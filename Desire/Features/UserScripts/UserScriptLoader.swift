import Foundation

/// Loads bundled JavaScript resources from `Desire/UserScripts/*.js`.
///
/// The project's file-system-synchronized group auto-includes non-Swift
/// files under `Desire/` as app-bundle resources, so every `.js` file in
/// `Desire/UserScripts/` is available via `Bundle.main` at runtime — no
/// pbxproj registration is required (same mechanism that bundles
/// `Localizable.xcstrings` and `Assets.xcassets`).
///
/// Usage:
/// ```
/// let js = UserScriptLoader.load("console-intercept")
/// ```
/// Pass the resource name **without** the `.js` extension.
///
/// On failure (missing file or bad encoding) this logs a clear diagnostic
/// and returns an empty string, so the caller's `WKUserScript` /
/// `evaluateJavaScript` path degrades gracefully rather than crashing.
/// A missing resource is always a build/packaging bug, not a user-facing
/// condition.
enum UserScriptLoader {
    static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            // TODO(stage 0): replace with OSLog once the logging subsystem lands.
            print("⚠️ UserScriptLoader: resource not found — UserScripts/\(name).js")
            return ""
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            print("⚠️ UserScriptLoader: failed to read UserScripts/\(name).js — \(error.localizedDescription)")
            return ""
        }
    }
}
