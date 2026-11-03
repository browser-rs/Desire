import Combine
import Foundation

/// 后台命令（v0.8.39）：allowlisted binary + argv（无 shell），进程立即返回，
/// 输出写 `JobLogs/<jobID>.log`，退出后进入统一 Job 账本并走 JobEventCenter 回报。
///
/// 不承诺跨进程：app 退出后运行中的命令在下次启动标记 interrupted；不自动重启。
@MainActor
final class BackgroundCommandStore: ObservableObject {
    static let shared = BackgroundCommandStore()

    struct CommandSpec: Codable, Equatable {
        var jobID: UUID
        var tool: String
        var args: [String]
        var title: String
        var cwd: String?
        var timeoutMinutes: Double
        var conversationID: UUID?
        var createdAt: Date
        /// 队列/依赖/重试（v0.8.40；全部 optional，旧 spec 可解码）
        var priority: String? = nil
        var dependsOn: [String]? = nil
        var maxAttempts: Int? = nil
        var attempt: Int? = nil
        var retryOn: String? = nil
        var retryRoot: String? = nil
        var reportMode: String? = nil
    }

    private struct Running {
        let process: Process
        let spec: CommandSpec
        let sink: CommandLogSink
        let startedAt: Date
        var timeoutTask: Task<Void, Never>?
        var cancelledByUser: Bool = false
        var timedOut: Bool = false
    }

    @Published private(set) var runningIDs: Set<UUID> = []
    /// 排队中的命令（v0.8.40；按 priority + createdAt 排序）
    @Published private(set) var queuedIDs: [UUID] = []
    private var running: [UUID: Running] = [:]
    private var specs: [UUID: CommandSpec] = [:]
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    private static let specsKey = "jobs.commandSpecs"
    private static let maxConcurrent = 3
    private static let maxTimeoutHours: Double = 6
    private static let maxSpecs = 100

    private init() {
        let stored = DiskStore.load([CommandSpec].self, key: Self.specsKey) ?? []
        specs = Dictionary(uniqueKeysWithValues: stored.map { ($0.jobID, $0) })
        recoverInterrupted()
    }

    var logDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Desire/JobLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func spec(for id: UUID) -> CommandSpec? { specs[id] }

    /// 启动后台命令。验证（允许名单/协商）在启动前完成；立即返回 jobID。
    /// 并发满或依赖未满足时进入队列，不报错（v0.8.40）。
    func start(tool: String, args: [String], title: String?,
               cwd: String?, timeoutMinutes: Double,
               conversationID: UUID?, report: JobWatch.Mode?,
               retryOf: UUID? = nil, after: [UUID] = [],
               maxAttempts: Int = 1, retryOn: String = "nonZero",
               priority: String = "normal", attempt: Int = 1,
               retryRoot: UUID? = nil) async -> Result<UUID, CommandLaunchError> {
        let name = tool.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return .failure(CommandLaunchError("Missing tool")) }
        let resolution = await SystemCommandStore.shared.resolveAllowedBinary(name)
        switch resolution {
        case .success: break
        case .failure(let error): return .failure(error)
        }
        let cwdURL = resolveWorkingDirectory(cwd)
        guard FileManager.default.fileExists(atPath: cwdURL.path) else {
            return .failure(CommandLaunchError(String(localized: "Working directory does not exist: \(cwdURL.path)")))
        }
        let minutes = min(max(timeoutMinutes, 0.1), Self.maxTimeoutHours * 60)
        let resolvedTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "\(name) \(args.prefix(4).joined(separator: " "))"
        let jobID = JobStore.shared.start(
            title: resolvedTitle, kind: .command,
            detail: String(localized: "Starting…"),
            source: "agent-command",
            conversationID: conversationID,
            retryOf: retryOf)
        let logURL = logDirectory.appendingPathComponent("\(jobID.uuidString).log")
        JobStore.shared.setLogFile(jobID, path: logURL.path)
        if let report {
            _ = JobWatchStore.shared.register(
                jobIDs: [jobID.uuidString],
                conversationID: conversationID, mode: report,
                reason: String(localized: "Background command"))
        }
        let spec = CommandSpec(
            jobID: jobID, tool: name, args: args, title: resolvedTitle,
            cwd: cwdURL.path, timeoutMinutes: minutes,
            conversationID: conversationID, createdAt: Date(),
            priority: priority.lowercased(),
            dependsOn: after.map(\.uuidString),
            maxAttempts: min(max(maxAttempts, 1), 5),
            attempt: max(1, attempt),
            retryOn: retryOn.lowercased(),
            retryRoot: (retryRoot ?? retryOf)?.uuidString,
            reportMode: report?.rawValue)
        specs[jobID] = spec
        persistSpecs()
        if running.count < Self.maxConcurrent && dependenciesSatisfied(spec) {
            JobStore.shared.update(jobID, detail: String(localized: "Starting…"))
            launch(spec, appendLog: false)
        } else {
            enqueue(jobID, spec: spec)
        }
        return .success(jobID)
    }

    /// 打开/续跑同一 job 的进程（自动重试用同一 jobID，watcher 不失效）。
    private func launch(_ spec: CommandSpec, appendLog: Bool) {
        let jobID = spec.jobID
        guard let executable = SystemCommandStore.shared.resolve(spec.tool) else {
            JobStore.shared.finish(
                jobID, state: .failed,
                detail: String(localized: "\(spec.tool) is not installed"),
                error: String(localized: "\(spec.tool) is not installed"))
            JobEventCenter.shared.recordTerminal(jobID: jobID)
            return
        }
        let logURL = logDirectory.appendingPathComponent("\(jobID.uuidString).log")
        let sink = CommandLogSink(url: logURL, append: appendLog) { event in
            Task { @MainActor in
                Self.applyProgressEvent(event, to: jobID)
            }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = spec.args
        process.currentDirectoryURL = spec.cwd.map { URL(fileURLWithPath: $0) }
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/usr/local/sbin",
            "HOME": NSHomeDirectory(),
            "DESIRE_JOB_ID": jobID.uuidString,
            "DESIRE_LOG_FILE": logURL.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { sink.append(data) }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.handleExit(jobID: jobID, process: finished)
            }
        }
        do {
            try process.run()
        } catch {
            sink.close()
            JobStore.shared.finish(
                jobID, state: .failed,
                detail: String(localized: "Failed to launch \(spec.tool)"),
                error: String(localized: "Failed to launch \(spec.tool): \(error.localizedDescription)"))
            JobEventCenter.shared.recordTerminal(jobID: jobID)
            return
        }
        var entry = Running(process: process, spec: spec, sink: sink,
                            startedAt: Date())
        entry.timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(spec.timeoutMinutes * 60 * 1_000_000_000))
            guard let self, let current = self.running[jobID],
                  current.process.isRunning else { return }
            self.running[jobID]?.timedOut = true
            JobStore.shared.update(
                jobID,
                detail: String(localized: "Timed out after \(Int(spec.timeoutMinutes)) min"))
            self.terminate(jobID)
        }
        running[jobID] = entry
        runningIDs.insert(jobID)
        retryTasks[jobID] = nil
        let attempt = spec.attempt ?? 1
        let maxAttempts = spec.maxAttempts ?? 1
        if attempt > 1 {
            JobStore.shared.update(
                jobID,
                detail: String(localized: "Attempt \(attempt)/\(maxAttempts) running…"))
        }
    }

    // MARK: - 队列 / 依赖

    private func enqueue(_ jobID: UUID, spec: CommandSpec) {
        if !queuedIDs.contains(jobID) { queuedIDs.append(jobID) }
        sortQueue()
        let position = (queuedIDs.firstIndex(of: jobID) ?? 0) + 1
        JobStore.shared.update(
            jobID, state: .queued,
            detail: String(localized: "Queued · position \(position)"))
    }

    private func sortQueue() {
        queuedIDs.sort { lhs, rhs in
            let lp = priorityRank(specs[lhs]?.priority)
            let rp = priorityRank(specs[rhs]?.priority)
            if lp != rp { return lp < rp }
            return (specs[lhs]?.createdAt ?? .distantPast)
                < (specs[rhs]?.createdAt ?? .distantPast)
        }
    }

    private func priorityRank(_ raw: String?) -> Int {
        switch raw?.lowercased() {
        case "high": return 0
        case "low": return 2
        default: return 1
        }
    }

    private func dependenciesSatisfied(_ spec: CommandSpec) -> Bool {
        let deps = spec.dependsOn ?? []
        guard !deps.isEmpty else { return true }
        for raw in deps {
            guard let id = UUID(uuidString: raw),
                  let job = JobStore.shared.job(id: id) else { return false }
            guard !job.state.isActive else { return false }
            guard job.state == .done else { return false }
        }
        return true
    }

    private func dependencyFailed(_ spec: CommandSpec) -> Bool {
        for raw in spec.dependsOn ?? [] {
            guard let id = UUID(uuidString: raw),
                  let job = JobStore.shared.job(id: id) else { return true }
            if job.state == .failed || job.state == .cancelled { return true }
        }
        return false
    }

    private func drainQueue() {
        guard !queuedIDs.isEmpty else { return }
        var launchedOne = true
        while launchedOne, running.count < Self.maxConcurrent {
            launchedOne = false
            sortQueue()
            for id in queuedIDs {
                guard let spec = specs[id] else {
                    queuedIDs.removeAll { $0 == id }
                    continue
                }
                if dependencyFailed(spec) {
                    queuedIDs.removeAll { $0 == id }
                    JobStore.shared.finish(
                        id, state: .cancelled,
                        detail: String(localized: "Dependency failed"),
                        error: String(localized: "A dependency failed, so this command was not started."))
                    JobEventCenter.shared.recordTerminal(jobID: id)
                    launchedOne = true
                    break
                }
                guard dependenciesSatisfied(spec) else { continue }
                queuedIDs.removeAll { $0 == id }
                JobStore.shared.update(id, state: .running,
                                       detail: String(localized: "Starting…"))
                launch(spec, appendLog: false)
                launchedOne = true
                break
            }
        }
    }

    func cancel(_ id: UUID) {
        if let retry = retryTasks.removeValue(forKey: id) {
            retry.cancel()
            JobStore.shared.finish(
                id, state: .cancelled,
                detail: String(localized: "Cancelled before the scheduled retry"),
                error: nil)
            JobEventCenter.shared.recordTerminal(jobID: id)
            drainQueue()
            return
        }
        if queuedIDs.contains(id) {
            queuedIDs.removeAll { $0 == id }
            JobStore.shared.finish(
                id, state: .cancelled,
                detail: String(localized: "Cancelled while queued"))
            JobEventCenter.shared.recordTerminal(jobID: id)
            drainQueue()
            return
        }
        guard let entry = running[id], entry.process.isRunning else { return }
        running[id]?.cancelledByUser = true
        JobStore.shared.update(id, detail: String(localized: "Cancelling…"))
        terminate(id)
    }

    func retry(_ id: UUID) async -> Result<UUID, CommandLaunchError> {
        guard let spec = specs[id] else {
            return .failure(CommandLaunchError(String(localized: "No retry information for this task.")))
        }
        guard !runningIDs.contains(id) else {
            return .failure(CommandLaunchError(String(localized: "This command is still running.")))
        }
        return await start(
            tool: spec.tool, args: spec.args, title: spec.title,
            cwd: spec.cwd, timeoutMinutes: spec.timeoutMinutes,
            conversationID: spec.conversationID, report: nil,
            retryOf: id,
            after: (spec.dependsOn ?? []).compactMap(UUID.init(uuidString:)),
            maxAttempts: spec.maxAttempts ?? 1,
            retryOn: spec.retryOn ?? "nonZero",
            priority: spec.priority ?? "normal",
            attempt: 1,
            retryRoot: (spec.retryRoot.flatMap(UUID.init(uuidString:)) ?? id))
    }

    /// 状态工具用的日志尾部（最后 40 行，最多 8KB）。
    func logTail(_ id: UUID, maxLines: Int = 40) -> String {
        guard let path = JobStore.shared.job(id: id)?.logFile else { return "" }
        return Self.readTail(path: path, maxLines: maxLines)
    }

    // MARK: - 内部

    private func terminate(_ id: UUID) {
        guard let entry = running[id] else { return }
        entry.process.terminate()
        let pid = entry.process.processIdentifier
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.running[id]?.process.isRunning == true else { return }
            kill(pid, SIGKILL)
        }
    }

    private func handleExit(jobID: UUID, process: Process) {
        guard let entry = running.removeValue(forKey: jobID) else { return }
        entry.timeoutTask?.cancel()
        process.terminationHandler = nil
        runningIDs.remove(jobID)
        if let handle = (process.standardOutput as? Pipe)?.fileHandleForReading {
            handle.readabilityHandler = nil
            let remainder = handle.readDataToEndOfFile()
            if !remainder.isEmpty { entry.sink.append(remainder) }
        }
        entry.sink.close()
        let exit = process.terminationStatus
        let state: JobRecord.State
        if entry.cancelledByUser {
            state = .cancelled
        } else if entry.timedOut || exit != 0 {
            state = .failed
        } else {
            state = .done
        }
        let elapsed = Int(Date().timeIntervalSince(entry.startedAt))
        var detail = state == .done
            ? String(localized: "Finished in \(elapsed)s")
            : String(localized: "Exit \(exit) after \(elapsed)s")
        if entry.timedOut {
            detail = String(localized: "Timed out after \(elapsed)s")
        } else if entry.cancelledByUser {
            detail = String(localized: "Cancelled after \(elapsed)s")
        }
        // 自动重试（v0.8.40）：同一 jobID 续跑，watcher 不会提前收到失败终态。
        let spec = entry.spec
        let attempt = spec.attempt ?? 1
        let maxAttempts = max(1, spec.maxAttempts ?? 1)
        let retryOn = (spec.retryOn ?? "nonZero").lowercased()
        let retryMatches: Bool
        switch retryOn {
        case "never": retryMatches = false
        case "always": retryMatches = true
        case "timeout": retryMatches = entry.timedOut
        default: retryMatches = entry.timedOut || exit != 0
        }
        let retryable = !entry.cancelledByUser && attempt < maxAttempts
            && retryMatches
        if retryable {
            var next = spec
            next.attempt = attempt + 1
            specs[jobID] = next
            persistSpecs()
            let delay = min(900, 1 << min(attempt, 9))
            JobStore.shared.update(
                jobID,
                detail: String(localized: "Attempt \(attempt)/\(maxAttempts) failed; retry in \(delay)s"))
            retryTasks[jobID] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                guard !Task.isCancelled, let self,
                      self.specs[jobID]?.attempt == attempt + 1,
                      !self.runningIDs.contains(jobID) else { return }
                self.launch(next, appendLog: true)
            }
            drainQueue()
            return
        }
        JobStore.shared.finish(
            jobID, state: state,
            detail: detail,
            receipt: detail,
            error: state == .failed ? detail : nil,
            exitCode: exit)
        JobEventCenter.shared.recordTerminal(jobID: jobID)
        drainQueue()
    }

    private func resolveWorkingDirectory(_ raw: String?) -> URL {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        return AgentWorkspace.shared.directory
    }

    private func persistSpecs() {
        let values = Array(specs.values)
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.maxSpecs)
        DiskStore.save(Array(values), key: Self.specsKey)
    }

    /// 启动时把上次残留的“运行中”命令标 interrupted（不自动重启）。
    private func recoverInterrupted() {
        let runningJobs = JobStore.shared.jobs.filter {
            $0.kind == .command && $0.state.isActive
        }
        for job in runningJobs {
            JobStore.shared.finish(
                job.id, state: .failed,
                error: String(localized: "Interrupted by app restart."))
            JobEventCenter.shared.recordTerminal(jobID: job.id)
        }
        // 清理日志：7 天前或总量超过 50MB 的旧文件。
        cleanupLogs()
    }

    private func cleanupLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
            if (values?.contentModificationDate ?? .distantPast) < cutoff {
                try? fm.removeItem(at: file)
            }
        }
        guard total > 50 * 1024 * 1024 else { return }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
        }
        for file in sorted {
            guard total > 50 * 1024 * 1024 else { break }
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? fm.removeItem(at: file)
            total -= size
        }
    }

    /// 命令自报进度/产物/链接/阶段（控制行不写日志）。
    private static func applyProgressEvent(_ event: CommandProgressEvent, to jobID: UUID) {
        switch event {
        case .progress(let percent, let message):
            let detail = message.map { "\(Int((percent * 100).rounded()))% · \($0)" }
                ?? "\(Int((percent * 100).rounded()))%"
            JobStore.shared.update(jobID, detail: detail, progress: percent)
        case .artifact(let path):
            JobStore.shared.update(jobID, artifactURL: path)
        case .link(let url, let title):
            let text = title.map { "\($0): \(url)" } ?? url
            JobStore.shared.update(jobID, detail: String(text.prefix(200)))
        case .phase(let name):
            JobStore.shared.update(jobID, detail: String(name.prefix(120)))
        }
    }

    nonisolated static func readTail(path: String, maxLines: Int) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 16_384
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return JobLogRedactor.redact(lines.suffix(maxLines).joined(separator: "\n"))
    }
}

/// 命令输出 → 日志文件（后台队列写；2MB 上限，超出截断并留标记）。
/// 按行解析 `@@desire:` 控制行（进度/产物/链接/阶段），控制行不写入正文；
/// 其余行脱敏后落盘。
private final class CommandLogSink: @unchecked Sendable {
    // 全部由 lock 保护；类默认 MainActor，而 pipe handler 在后台队列，
    // 因此可变成员显式 nonisolated(unsafe)。
    private let handle: FileHandle
    private let lock = NSLock()
    nonisolated(unsafe) private var bytes = 0
    nonisolated(unsafe) private var truncated = false
    nonisolated(unsafe) private var buffer = ""
    private let cap = 2 * 1024 * 1024
    private let onEvent: @Sendable (CommandProgressEvent) -> Void

    init(url: URL, append: Bool = false,
         onEvent: @escaping @Sendable (CommandProgressEvent) -> Void) {
        if !append || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let file = (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
        if append { _ = try? file.seekToEnd() }
        handle = file
        self.onEvent = onEvent
    }

    nonisolated func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !truncated else { return }
        buffer += String(decoding: data, as: UTF8.self)
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            consume(line)
        }
        // 无换行的进度条/在途行：超过 8KB 先落盘，避免无限缓存。
        if buffer.count > 8_192 {
            write(JobLogRedactor.redact(buffer))
            buffer = ""
        }
    }

    nonisolated func close() {
        lock.lock()
        defer { lock.unlock() }
        if !buffer.isEmpty {
            consume(buffer)
            buffer = ""
        }
        try? handle.close()
    }

    private nonisolated func consume(_ line: String) {
        if let event = CommandProgressParser.parse(line: line) {
            onEvent(event)
            return
        }
        write(JobLogRedactor.redact(line) + "\n")
    }

    private nonisolated func write(_ text: String) {
        guard !truncated, !text.isEmpty else { return }
        let data = Data(text.utf8)
        if bytes + data.count > cap {
            let room = max(0, cap - bytes)
            if room > 0 { try? handle.write(contentsOf: data.prefix(room)) }
            bytes = cap
            truncated = true
            try? handle.write(contentsOf: Data("\n…[log truncated at 2 MB]…\n".utf8))
            return
        }
        bytes += data.count
        try? handle.write(contentsOf: data)
    }
}
