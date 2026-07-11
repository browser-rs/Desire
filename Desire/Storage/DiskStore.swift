import Foundation

/// Lightweight file-based persistence for larger or growing `Codable` data.
///
/// Replaces UserDefaults JSON blobs for data that doesn't fit the
/// "small user preferences" profile (browsing history, tab sessions with
/// `WKWebView.interactionState` blobs, AI conversation logs, search history).
/// UserDefaults is optimized for small scalar prefs and gets slow / brittle
/// when fed megabytes of JSON — see `docs/ARCHITECTURE.md` (debt A4).
///
/// Files live under `~/Library/Application Support/Desire/storage/<key>.json`.
/// Under App Sandbox this path resolves inside the app's container, which is
/// read/write with no extra entitlement.
///
/// The API mirrors the UserDefaults load/save pattern the stores already use,
/// so migration is mechanical: swap `UserDefaults.standard.data(forKey:)` →
/// `DiskStore.load(_:key:)`. Callers are `@MainActor` stores; the synchronous
/// I/O here is intentionally the same shape as the old UserDefaults writes
/// (small individual write cost). Async/background writes are a later
/// optimization.
enum DiskStore {
    /// Loads and decodes a value for `key`. Returns `nil` if the file is
    /// missing, unreadable, or fails to decode (callers already treat a
    /// missing load as "no data / use defaults").
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Encodes and writes `value` to the file for `key`. Failures are silent
    /// — matching the existing UserDefaults behavior where a failed encode
    /// is swallowed. Writes are atomic to avoid torn files on crash.
    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let url = directory.appendingPathComponent("\(key).json")
        try? data.write(to: url, options: .atomic)
    }

    /// Removes the file for `key`, if present. No-op if missing.
    static func remove(key: String) {
        let url = directory.appendingPathComponent("\(key).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// The storage directory, created on first access. Lazily creates the
    /// full path (`Application Support/Desire/storage/`).
    static var directory: URL {
        let fm = FileManager.default
        // `.applicationSupportDirectory` resolves to the sandbox container's
        // Library/Application Support on a sandboxed app — always writable.
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base
            .appendingPathComponent("Desire", isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
