import Combine
import Foundation

/// The agent's persistent working directory: file tools (readFile /
/// writeFile / listDirectory) and system commands (runCommand cwd) resolve
/// here, so multi-step file work feels like a resident assistant instead of
/// a one-off visitor.
///
/// Access model:
/// - Relative paths always resolve against the workspace.
/// - Without FULL ACCESS: reads/writes are limited to the workspace plus
///   the user's Downloads / Documents / Desktop.
/// - With FULL ACCESS: any path (the mode's whole point), chosen by the
///   user in the panel.
@MainActor
final class AgentWorkspace: ObservableObject {
    static let shared = AgentWorkspace()

    private static let key = "agentWorkspacePath"

    @Published private(set) var directory: URL

    private init() {
        if let stored = UserDefaults.standard.string(forKey: Self.key) {
            directory = URL(fileURLWithPath: (stored as NSString).expandingTildeInPath)
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            directory = documents.appendingPathComponent("DesireAgent", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func set(_ url: URL) {
        directory = url
        UserDefaults.standard.set(url.path, forKey: Self.key)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        set(documents.appendingPathComponent("DesireAgent", isDirectory: true))
    }

    // MARK: - Path resolution

    enum FileAccess {
        case granted(URL)
        case denied(String)
    }

    /// Resolves a user/agent-supplied path: tilde expansion, relative paths
    /// against the workspace, and an allowlist check unless FULL ACCESS.
    func resolve(_ rawPath: String, write: Bool) -> FileAccess {
        let fullAccess = UserDefaults.standard.bool(forKey: "aiFullAccess")
        let hasScheme = rawPath.contains("://")
        let expanded = (rawPath as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded)
        if !hasScheme && !expanded.hasPrefix("/") {
            url = directory.appendingPathComponent(expanded)
        }
        let resolved = url.standardizedFileURL.path

        if !fullAccess {
            var roots = [directory.standardizedFileURL.path]
            for variant in [FileManager.SearchPathDirectory.downloadsDirectory,
                            .documentDirectory,
                            .desktopDirectory] {
                if let base = FileManager.default.urls(for: variant, in: .userDomainMask).first {
                    roots.append(base.standardizedFileURL.path)
                }
            }
            let inside = roots.contains { root in
                resolved == root || resolved.hasPrefix(root + "/")
            }
            guard inside else {
                let verb = write ? "write to" : "read"
                return .denied("Path '\(resolved)' is outside the workspace and user folders — cannot \(verb) it. "
                    + "Use a path inside \(directory.path), enable FULL ACCESS, or ask the user.")
            }
        }
        return .granted(url.standardizedFileURL)
    }
}
