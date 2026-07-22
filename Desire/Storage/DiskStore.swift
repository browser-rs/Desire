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
/// Writes are **debounced and off-main**: the public `save` API is synchronous
/// to call from `@MainActor` stores, but it only stages the encoded payload and
/// hands it to a background `DiskStoreWriter` actor. Repeated writes to the same
/// key within the debounce window coalesce into a single file write, and the
/// actual `Data.write(.atomic)` runs on the actor (off the main thread). This
/// keeps hot paths (tab open/close, history add, conversation save in the AI
/// agent loop) from blocking the UI. Reads stay synchronous because they are
/// rare (init-time) and the cost of an async read would ripple through store
/// initializers.
enum DiskStore {
    /// Loads and decodes a value for `key`. Returns `nil` if the file is
    /// missing, unreadable, or fails to decode (callers already treat a
    /// missing load as "no data / use defaults"). Synchronous — only used at
    /// init time, never on a hot path.
    nonisolated static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Encodes `value` and schedules a debounced, off-main write for `key`.
    /// Encoding happens on the caller (cheap, and avoids needing `Encodable`
    /// constraints on the actor); the file write happens on the writer actor.
    /// Failures are silent — matching the old UserDefaults behavior. Within
    /// the debounce window, later writes to the same key win and earlier ones
    /// are dropped.
    nonisolated static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Fire-and-forget: the writer actor debounces and serializes. Using a
        // Task keeps this synchronous API callable from @MainActor stores
        // without an `await` ripple.
        Task { await writer.stage(data: data, key: key) }
    }

    /// Schedules a debounced removal of the file for `key`. No-op if missing.
    nonisolated static func remove(key: String) {
        Task { await writer.stageRemoval(key: key) }
    }

    /// The storage directory, created on first access. Lazily creates the
    /// full path (`Application Support/Desire/storage/`).
    nonisolated static var directory: URL {
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

    /// Shared background writer. Lazily initialized; the first `save`/`remove`
    /// pays the actor allocation, subsequent calls reuse it.
    nonisolated private static let writer = DiskStoreWriter()
}

/// Background actor that debounces and performs disk writes for `DiskStore`.
///
/// Per-key coalescing: a write scheduled for `key` waits `debounceInterval`
/// before flushing; if another write for the same key arrives in that window,
/// the timer resets and only the latest payload is written. This turns a burst
/// of `save` calls (e.g. one per tab mutation, one per history entry) into a
/// single file write.
actor DiskStoreWriter {
    /// Pending payloads waiting for their debounce window to elapse.
    private var pending: [String: Data] = [:]
    /// Pending removals (a key here cancels any staged write for it).
    private var pendingRemovals: Set<String> = []
    /// Active debounce tasks per key.
    private var tasks: [String: Task<Void, Never>] = [:]

    private let debounceInterval: Duration

    init(debounceInterval: Duration = .milliseconds(500)) {
        self.debounceInterval = debounceInterval
    }

    func stage(data: Data, key: String) {
        pending[key] = data
        pendingRemovals.remove(key)
        scheduleFlush(for: key)
    }

    func stageRemoval(key: String) {
        pending.removeValue(forKey: key)
        pendingRemovals.insert(key)
        scheduleFlush(for: key)
    }

    private func scheduleFlush(for key: String) {
        tasks[key]?.cancel()
        tasks[key] = Task { [weak self] in
            try? await Task.sleep(for: self?.debounceInterval ?? .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.flush(key: key)
        }
    }

    private func flush(key: String) {
        tasks[key] = nil
        let url = DiskStore.directory.appendingPathComponent("\(key).json")
        if pendingRemovals.contains(key) {
            pendingRemovals.remove(key)
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = pending.removeValue(forKey: key) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
