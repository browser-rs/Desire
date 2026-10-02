import Foundation
import os

/// MCP client over the **stdio transport** (2026-10-02 完整 MCP)：本地子进程
/// 的 stdin/stdout 上跑 JSON-RPC，消息为换行分隔的 JSON（MCP 规范：行内
/// 不得有裸换行）。与 HTTP 版（MCPConnection）同一握手与 tools 语义。
///
/// 生命周期：init 即 spawn；`connect()` 握手；`terminate()` 撕进程。
/// 响应按 JSON-RPC id 匹配挂起的 continuation；通知/日志行（无 id）丢弃。
@MainActor
final class MCPStdioConnection {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    /// 诊断尾随（连接失败时带回最后几行 stderr）。
    private var stderrTail: [String] = []
    private let serverName: String

    private var buffer = Data()
    private var nextRequestID = 0
    private var pending: [Int: CheckedContinuation<[String: Any]?, Error>] = [:]
    private var didExit = false
    private var exitStatus: Int32 = 0

    static let log = Log.ai
    /// tools/list 走握手；tools/call 可能是真的在跑慢工具——放宽。
    private var callTimeout: TimeInterval = 120

    /// 裸命令名 → PATH 解析；含 "/" 或解析不到则原样返回（Process 自己报错）。
    private static func resolveExecutable(_ name: String) -> String {
        guard !name.contains("/") else { return name }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return name
    }

    init(serverName: String, argv: [String], env: [String: String]?) throws {
        guard let rawExecutable = argv.first, !rawExecutable.isEmpty else {
            throw MCPError.badResponse
        }
        self.serverName = serverName
        let proc = Process()
        // Process 不做 PATH 查找——裸命令名（python3/npx）按环境 PATH 解析，
        // 与 shell 语义一致（生态配置里几乎没人写绝对路径）。
        let executable = Self.resolveExecutable(rawExecutable)
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = Array(argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        if let env { for (k, v) in env { environment[k] = v } }
        proc.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading

        // 两段初始化：存储属性全部赋值后才能碰 self——handler 在 run 之后装
        // 也覆盖得到退出（进程刚跑就退的竞态由 didExit 标志兜底）。
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.didExit = true
                // 进程死了：所有挂起请求以失败唤醒（否则 await 永远悬挂）。
                for (_, continuation) in self.pending {
                    continuation.resume(throwing: MCPError.rpc("stdio server exited"))
                }
                self.pending.removeAll()
            }
        }

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            Task { @MainActor in self.ingest(data) }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            Task { @MainActor in
                if let line = String(data: data, encoding: .utf8) {
                    self.stderrTail = (self.stderrTail + line.split(separator: "\n").map(String.init)).suffix(8)
                    Self.log.debug("stdio MCP \(self.serverName, privacy: .public) stderr: \(line.prefix(200), privacy: .public)")
                }
            }
        }
        Self.log.info("stdio MCP server \(serverName, privacy: .public) spawned: \(executable, privacy: .public)")
    }

    deinit {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    func terminate() {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    var isRunning: Bool { process.isRunning && !didExit }

    var lastStderr: String { stderrTail.joined(separator: " | ") }

    // MARK: - Handshake + tools

    func connect() async throws -> [MCPTool] {
        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Desire", "version": "0.1"],
        ], timeout: 20)
        sendNotification(method: "notifications/initialized", params: nil)
        let listResult = try await request(method: "tools/list", params: [String: Any](), timeout: 20)
        let toolsJSON = listResult["tools"] as? [[String: Any]] ?? []
        return toolsJSON.compactMap(MCPConnection.tool(fromJSON:))
    }

    func callTool(named name: String, arguments: [String: Any]) async throws -> String {
        let result = try await request(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            timeout: callTimeout
        )
        if (result["isError"] as? Bool) == true {
            let text = MCPConnection.text(fromContent: result["content"])
            throw MCPError.rpc(text.isEmpty ? "Tool reported an error" : text)
        }
        let text = MCPConnection.text(fromContent: result["content"])
        return text.isEmpty ? "(empty result)" : text
    }

    // MARK: - JSON-RPC over lines

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { continue }
            if let error = obj["error"] as? [String: Any], obj["id"] == nil {
                // 无 id 的错误/日志行：进诊断尾随即可。
                Self.log.debug("stdio MCP \(self.serverName, privacy: .public) notice: \(error["message"] as? String ?? "?", privacy: .public)")
                continue
            }
            guard let id = obj["id"] as? Int else { continue } // 通知行
            guard let continuation = pending.removeValue(forKey: id) else { continue }
            if let error = obj["error"] as? [String: Any] {
                continuation.resume(throwing: MCPError.rpc((error["message"] as? String) ?? "MCP error"))
            } else {
                continuation.resume(returning: obj["result"] as? [String: Any])
            }
        }
    }

    private func request(method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        guard isRunning else {
            throw MCPError.rpc("stdio server not running. \(lastStderr)")
        }
        nextRequestID += 1
        let id = nextRequestID
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { body["params"] = params }

        let lineData = try JSONSerialization.data(withJSONObject: body)
        var line = lineData
        line.append(0x0A)
        stdinHandle.write(line)

        let result: [String: Any]? = try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    if self.didExit {
                        continuation.resume(throwing: MCPError.rpc("stdio server exited"))
                        return
                    }
                    self.pending[id] = continuation
                }
            }
            group.addTask { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let continuation = self.pending.removeValue(forKey: id) {
                    continuation.resume(throwing: MCPError.rpc("stdio request timed out (\(Int(timeout))s)"))
                }
                return nil
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        guard let resultObject = result else { throw MCPError.badResponse }
        return resultObject
    }

    private func sendNotification(method: String, params: [String: Any]?) {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { body["params"] = params }
        if let lineData = try? JSONSerialization.data(withJSONObject: body) {
            var line = lineData
            line.append(0x0A)
            stdinHandle.write(line)
        }
    }
}
