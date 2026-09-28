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
        // 编码发生在 writer actor 上，**不在调用方线程**（PERF-1）：TabManager 的
        // 15s 会话持久化每拍要在主线程编码多 MB JSON（含各标签 interactionState），
        // 是周期性掉帧的直接来源；ConversationStore/HistoryStore 等热路径同样受益。
        // 失败静默的取舍不变。
        //
        // 装箱过隔离边界：本项目的 Model 全是**值类型**（struct/数组/字典），按值
        // 传入后闭包持有独占副本，actor 上编码不存在共享可变状态——这是
        // @unchecked 的安全论证。不直接给泛型加 Sendable 约束的原因：模块默认
        // MainActor 隔离让 Model 的 Encodable conformance 变成 actor 隔离的，
        // `& Sendable` 会让 18 个类型全数编译失败（其中 ShortcutMapping 依赖
        // AppKit，无法 nonisolated 化）。
        let box = EncodableBox(value: value)
        // 编码与入库分两段：encode 在 detached 任务（nonisolated 上下文）跑，
        // 只有 Data（确定 Sendable）进 actor——避免把"可能隔离的 Encodable
        // conformance"带进 actor 隔离上下文（#IsolatedConformances 警告）。
        Task.detached {
            guard let data = try? JSONEncoder().encode(box.value) else { return }
            await writer.stage(data: data, key: key)
        }
    }

    /// Schedules a debounced removal of the file for `key`. No-op if missing.
    nonisolated static func remove(key: String) {
        Task { await writer.stageRemoval(key: key) }
    }

    /// Blocks briefly (capped at 3s) until every staged write/removal is on
    /// disk. Terminate-time only: a hard quit inside the 500 ms debounce
    /// window would otherwise lose the last save.
    nonisolated static func flushSync() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await writer.flushNow()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
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

/// 值装箱（安全论证见 DiskStore.save）。`@unchecked` 的依据是"值语义 + 闭包
/// 独占所有权"，不是这个声明本身——**只允许装箱值类型**；哪天要存 class 类型
/// 必须回到调用方线程编码。
fileprivate nonisolated struct EncodableBox<T>: @unchecked Sendable {
    let value: T
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

    /// Writes every pending payload immediately and cancels debounce timers.
    /// Terminate-time: a quit must not lose saves still inside their
    /// debounce window.
    func flushNow() {
        for key in tasks.keys { tasks[key]?.cancel() }
        tasks.removeAll()
        for key in pendingRemovals {
            pendingRemovals.remove(key)
            let url = DiskStore.directory.appendingPathComponent("\(key).json")
            try? FileManager.default.removeItem(at: url)
        }
        for (key, data) in pending {
            let url = DiskStore.directory.appendingPathComponent("\(key).json")
            try? data.write(to: url, options: .atomic)
        }
        pending.removeAll()
    }
}
