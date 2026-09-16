import Combine
import Foundation
import os

/// Executes allowlisted system binaries (ffmpeg, brew, python3, …) on
/// behalf of the agent — the layer that turns the browser into a real
/// agent host.
///
/// Security model (defense in depth):
/// 1. **Binary allowlist** (persisted, user-editable in Settings → AI →
///    System Access). Unknown binaries are refused; there is no shell —
///    arguments go to the process as argv, so no injection surface.
/// 2. **PATH resolution** over the standard Homebrew + system locations.
/// 3. **Agent-tier gating**: `runCommand` classifies as DANGEROUS in
///    `ToolRisk`, so every call prompts with the exact command line —
///    unless the user enabled FULL ACCESS.
/// 4. Hard timeout (default 120s, cap 600s) kills the process; combined
///    output is truncated before it reaches the model.
@MainActor
final class SystemCommandStore: ObservableObject {
    static let shared = SystemCommandStore()

    private static let key = "ai-cli-allowlist"

    private static let log = Log.agent

    @Published private(set) var allowedBinaries: Set<String>

    /// Sensible defaults for a media/browsing agent.
    static let defaultBinaries: Set<String> = [
        "ffmpeg", "ffprobe", "brew", "python3", "pip3", "node", "npm",
        "osascript", "say", "sips", "textutil", "curl", "git", "qlmanage",
    ]

    private static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/usr/local/sbin",
    ]

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        allowedBinaries = stored.isEmpty ? Self.defaultBinaries : Set(stored)
    }

    private func save() {
        UserDefaults.standard.set(Array(allowedBinaries).sorted(), forKey: Self.key)
    }

    func allow(_ binary: String) {
        let name = binary.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }
        allowedBinaries.insert(name)
        save()
    }

    func disallow(_ binary: String) {
        allowedBinaries.remove(binary.trimmingCharacters(in: .whitespaces).lowercased())
        save()
    }

    /// Finds the executable in the standard PATH locations. Returns nil when
    /// the binary is unknown or not installed.
    func resolve(_ binary: String) -> URL? {
        let fm = FileManager.default
        for dir in Self.searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(binary)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Execution

    struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let truncated: Bool
        let duration: TimeInterval
        let timedOut: Bool

        /// Uniform refusal shape for pre-flight failures.
        static func failure(_ message: String) -> CommandResult {
            CommandResult(exitCode: -1, stdout: "", stderr: message,
                          truncated: false, duration: 0, timedOut: false)
        }

        var summary: String {
            let status = timedOut
                ? "TIMED OUT"
                : (exitCode == 0 ? "ok" : "exit \(exitCode)")
            return "(\(status), \(String(format: "%.1f", duration))s)"
        }
    }

    /// Runs `tool` with `args`. The binary must be allowlisted. There is no
    /// shell: `args` are passed as argv, so quoting/injection does not apply.
    func run(
        tool: String,
        args: [String],
        timeout: TimeInterval = 120
    ) async -> CommandResult {
        let name = tool.trimmingCharacters(in: .whitespaces).lowercased()
        guard allowedBinaries.contains(name) else {
            return .failure("Binary '\(tool)' is not allowlisted. The user can add it in Settings → AI → System Access. Allowlisted: \(allowedBinaries.sorted().joined(separator: ", "))")
        }
        guard let executable = resolve(name) else {
            return .failure("'\(tool)' is allowlisted but not installed (searched \(Self.searchPaths.joined(separator: ", "))). Try: brew install \(name == "brew" ? "" : name)")
        }

        let clampedTimeout = min(max(timeout, 5), 600)
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = ["PATH": Self.searchPaths.joined(separator: ":"), "HOME": NSHomeDirectory()]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Accumulate off the main thread: pipes deadlock when their 64 KB
        // buffer fills and nobody drains them.
        final class Accumulator: @unchecked Sendable {
            private let lock = NSLock()
            // Lock-guarded; isolation is opted out per-member because the
            // project defaults every declaration to the main actor.
            nonisolated(unsafe) private var data = Data()
            // Pipe handlers drain on WebKit/POSIX queues, not the main
            // actor — isolation must be opted out explicitly here.
            nonisolated func append(_ chunk: Data) {
                lock.lock(); data.append(chunk); lock.unlock()
            }
            nonisolated var value: Data {
                lock.lock(); defer { lock.unlock() }; return data
            }
        }
        let outAcc = Accumulator()
        let errAcc = Accumulator()
        stdout.fileHandleForReading.readabilityHandler = { outAcc.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errAcc.append($0.availableData) }

        let started = Date()
        do {
            try process.run()
        } catch {
            Self.log.error("runCommand spawn failed: \(error.localizedDescription, privacy: .public)")
            return .failure("Failed to launch \(name): \(error.localizedDescription)")
        }

        // Wait for exit or timeout.
        while process.isRunning && Date().timeIntervalSince(started) < clampedTimeout {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            for _ in 0..<10 where process.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        let exitCode = process.terminationStatus
        let duration = Date().timeIntervalSince(started)

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        outAcc.append(stdout.fileHandleForReading.readDataToEndOfFile())
        errAcc.append(stderr.fileHandleForReading.readDataToEndOfFile())

        return Self.buildResult(
            exitCode: exitCode,
            stdout: String(data: outAcc.value, encoding: .utf8) ?? "",
            stderr: String(data: errAcc.value, encoding: .utf8) ?? "",
            duration: duration,
            timedOut: timedOut
        )
    }

    nonisolated static func buildResult(
        exitCode: Int32, stdout: String, stderr: String,
        duration: TimeInterval, timedOut: Bool
    ) -> CommandResult {
        // Keep the payload under the model's practical per-tool budget.
        let cap = 8000
        var text = ""
        var truncated = false
        if !stdout.isEmpty {
            let chunk = String(stdout.prefix(cap))
            text += "stdout:\n\(chunk)\n"
            truncated = truncated || stdout.count > cap
        }
        if !stderr.isEmpty {
            let chunk = String(stderr.prefix(2000))
            text += "stderr:\n\(chunk)\n"
            truncated = truncated || stderr.count > 2000
        }
        if text.isEmpty { text = "(no output)" }
        return CommandResult(
            exitCode: exitCode,
            stdout: text,
            stderr: "",
            truncated: truncated,
            duration: duration,
            timedOut: timedOut
        )
    }
}
