import Foundation
import os

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
/// to call from `@MainActor` stores, but encoding and file writes happen in
/// tracked background tasks. Repeated writes to the same key within the
/// debounce window coalesce into a single file write, and termination can wait
/// for every task that was scheduled before its flush barrier.
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
    /// Encoding and writing are tracked so termination can wait for work that
    /// was accepted before its flush barrier.
    nonisolated static func save<T: Encodable>(_ value: T, key: String) {
        // 装箱过隔离边界：本项目的 Model 全是**值类型**（struct/数组/字典），按值
        // 传入后闭包持有独占副本，actor 上编码不存在共享可变状态——这是
        // @unchecked 的安全论证。不直接给泛型加 Sendable 约束的原因：模块默认
        // MainActor 隔离让 Model 的 Encodable conformance 变成 actor 隔离的，
        // `& Sendable` 会让 18 个类型全数编译失败（其中 ShortcutMapping 依赖
        // AppKit，无法 nonisolated 化）。
        let box = EncodableBox(value: value)
        _ = coordination.schedule { generation in
            // 编码与入库分两段：encode 在 detached 任务（nonisolated 上下文）跑，
            // 只有 Data（确定 Sendable）进 actor。
            Task.detached {
                guard let data = try? JSONEncoder().encode(box.value) else {
                    Log.storage.error("DiskStore encode failed for key \(key, privacy: .public) generation \(generation, privacy: .public)")
                    return
                }
                await writer.stage(data: data, key: key, generation: generation)
            }
        }
    }

    /// Schedules a debounced removal of the file for `key`. No-op if missing.
    nonisolated static func remove(key: String) {
        _ = coordination.schedule { generation in
            Task.detached {
                await writer.stageRemoval(key: key, generation: generation)
            }
        }
    }

    /// Blocks briefly (capped at 3s) until every staged write/removal is on
    /// disk. Terminate-time only: a hard quit inside the 500 ms debounce
    /// window would otherwise lose the last save.
    nonisolated static func flushSync() {
        let semaphore = DispatchSemaphore(value: 0)
        let targetGeneration = coordination.currentGeneration()
        let tasks = coordination.tasks(upTo: targetGeneration)
        let writer = writer
        let coordination = coordination
        // QoS 对齐（Xcode 倒挂警告）：flushSync 跑在主线程（UI QoS），
        // 信号量等的后台任务若是 Default QoS = 高优等低优的优先级倒挂。
        // 显式 userInitiated——termination 路径的落盘本就是用户发起的最高优。
        Task.detached(priority: .userInitiated) {
            for task in tasks {
                await task.value
            }
            await writer.flushNow(upTo: targetGeneration)
            coordination.complete(upTo: targetGeneration)
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
    nonisolated private static let coordination = DiskStoreWriteCoordinator()
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
    private enum PendingOperation {
        case write(generation: UInt64, data: Data)
        case remove(generation: UInt64)

        var generation: UInt64 {
            switch self {
            case .write(let generation, _), .remove(let generation): return generation
            }
        }
    }

    /// Pending operations waiting for their debounce window to elapse.
    private var pending: [String: PendingOperation] = [:]
    /// Active debounce tasks per key.
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Monotonic staging generation used by deterministic flush barriers.
    private var nextGeneration: UInt64 = 0

    private let directory: URL
    private let debounceInterval: Duration

    init(directory: URL = DiskStore.directory, debounceInterval: Duration = .milliseconds(500)) {
        self.directory = directory
        self.debounceInterval = debounceInterval
    }

    @discardableResult
    func stage(data: Data, key: String) -> UInt64 {
        nextGeneration &+= 1
        stage(data: data, key: key, generation: nextGeneration)
        return nextGeneration
    }

    func stage(data: Data, key: String, generation: UInt64) {
        nextGeneration = max(nextGeneration, generation)
        pending[key] = .write(generation: generation, data: data)
        scheduleFlush(for: key)
    }

    @discardableResult
    func stageRemoval(key: String) -> UInt64 {
        nextGeneration &+= 1
        stageRemoval(key: key, generation: nextGeneration)
        return nextGeneration
    }

    func stageRemoval(key: String, generation: UInt64) {
        nextGeneration = max(nextGeneration, generation)
        pending[key] = .remove(generation: generation)
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
        guard let operation = pending.removeValue(forKey: key) else { return }
        let url = directory.appendingPathComponent("\(key).json")
        switch operation {
        case .remove:
            try? FileManager.default.removeItem(at: url)
        case .write(_, let data):
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Writes every pending payload immediately and cancels debounce timers.
    /// Terminate-time: a quit must not lose saves still inside their
    /// debounce window.
    func flushNow(upTo limit: UInt64? = nil) {
        let target = limit ?? .max
        for key in Array(pending.keys) {
            guard let operation = pending[key], operation.generation <= target else { continue }
            tasks[key]?.cancel()
            tasks[key] = nil
            pending.removeValue(forKey: key)
            let url = directory.appendingPathComponent("\(key).json")
            switch operation {
            case .remove:
                try? FileManager.default.removeItem(at: url)
            case .write(_, let data):
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// Coordinates detached encoders with the writer actor. The lock only guards
/// task registration and snapshots; encoding and disk IO stay off the caller.
private nonisolated final class DiskStoreWriteCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var tasks: [UInt64: Task<Void, Never>] = [:]

    func schedule(_ makeTask: (UInt64) -> Task<Void, Never>) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration &+= 1
        let generation = nextGeneration
        tasks[generation] = makeTask(generation)
        return generation
    }

    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nextGeneration
    }

    func tasks(upTo generation: UInt64) -> [Task<Void, Never>] {
        lock.lock()
        defer { lock.unlock() }
        return tasks
            .filter { $0.key <= generation }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    func complete(upTo generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        tasks = tasks.filter { $0.key > generation }
    }
}
