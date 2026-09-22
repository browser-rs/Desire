import Foundation

/// 用系统已安装的 ffmpeg 下载 HLS 并直接封装成 MP4。
///
/// **为什么不内置 ffmpeg**：它是独立的 GPL/LGPL 项目，打进 app 包既有体积也有
/// 许可问题。所以这里只**探测**用户机器上装没装（Homebrew 的
/// `/opt/homebrew/bin/ffmpeg` 最常见），装了就用来下载 + 转封装，没装就退回
/// `MediaExporter` 里那套手写下载器——功能不降级，只是可能拿到 `.ts`。
///
/// 下面这些参数是 2026-09-23 在 ffmpeg 9.0.1 上逐条实测定的：
/// - **喂给 ffmpeg 的必须是 master 播放列表**：音轨分离（`EXT-X-MEDIA`）的站点，
///   媒体播放列表里只有视频；只喂 variant URL 会**丢音轨**。喂 master 时 ffmpeg
///   自己会把 `AUDIO="…"` 指向的音轨接上（实测 master → h264+aac，variant → h264）。
/// - **`-map 0:p:N` 选第 N 个 variant**（program 顺序 = 播放列表**文件顺序**，
///   不是按码率排序的），且会连带它的音频组；不传则 ffmpeg 默认挑最高码率
///   （实测默认选了 960x540 那档）。
/// - **不需要 `-bsf:a aac_adtstoasc`**：mov muxer 自己会插（TS→MP4 实测直出正常）。
/// - **防盗链头走 `-referer` / `-user_agent`**：`-headers` 里写字面 `\r\n` 会被
///   当成表头值的一部分传上去（实测服务器收到 `Referer=…\r\n`）。
/// - **live 播放列表绝不能交给 ffmpeg**：没有 `EXT-X-ENDLIST` 时它会一直等新分片，
///   `-t` 也拦不住（实测 40s 不退出）。live 仍走手写下载器，之后再本地转封装。
/// - 取消：SIGTERM 后 ffmpeg 立刻退出且不留残件（实测 0.00s、无输出文件），
///   但仍会在调用侧兜底删除。
enum FFmpegExporter {
    struct Outcome {
        let bytes: Int64
        /// stderr 末尾若干行，失败时用于给用户/模型一个可读原因。
        let diagnostics: String
    }

    enum ExportError: LocalizedError {
        case launchFailed(String)
        case failed(code: Int32, diagnostics: String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .launchFailed(let reason): "Could not start ffmpeg: \(reason)"
            case .failed(let code, let diagnostics):
                diagnostics.isEmpty ? "ffmpeg exited with code \(code)" : "ffmpeg exited with code \(code): \(diagnostics)"
            case .timedOut: "Export exceeded the 30-minute time limit"
            }
        }
    }

    /// ffmpeg 的安装位置。GUI 进程的 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，
    /// Homebrew 的两个 bin 目录都不在里面，必须显式探测（沿用
    /// `SystemCommandStore.searchPaths` 的清单，保持一致）。
    private static let searchPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    /// 每次导出都现场探测（几次 `fileExists`，代价可忽略）：用户现装 ffmpeg 后
    /// 不必重启 app。
    static func locate() -> URL? {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isAvailable: Bool { locate() != nil }

    /// 把 `url`（master 或媒体播放列表）下载并转封装成 `destination`（.mp4）。
    ///
    /// - Parameter programIndex: 选中 variant 在 master 里的**文件顺序**下标
    ///   （来自 `MediaExporter.listVariants` 的 `index` 字段）；给 nil 就让
    ///   ffmpeg 自己挑最高码率。
    /// - Parameter totalSeconds: 播放列表里 `EXTINF` 之和，仅用于进度换算。
    /// - Parameter progress: (已完成秒数, 总秒数)。
    nonisolated static func export(
        executable: URL,
        playlist: URL,
        referer: URL?,
        userAgent: String?,
        programIndex: Int?,
        totalSeconds: Double,
        destination: URL,
        deadline: Date,
        progress: @MainActor @escaping (Int, Int) -> Void
    ) async throws -> Outcome {
        /// ffmpeg ≥ 7.1 默认 `-extension_picky 1`，分片扩展名不在白名单就直接拒收
        /// （实测 `.bin` 分片、**无扩展名分片**都被拒："detected format mpegts extension
        /// none mismatches allowed extensions"）。老版本没有这两个选项、会报
        /// "Unrecognized option"，所以先带新选项试，失败再退回只用 `-f hls`。
        func arguments(modernHLSFlags: Bool) -> [String] {
            var args = [
                "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                // 网络读取停顿时长上限（微秒）：CDN 卡住时让 ffmpeg 自己报错退出。
                "-rw_timeout", "120000000",
                // HLS 取 AES-128 密钥要 file/crypto，防盗链要 http(s)。
                "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
                // 强制按 HLS 解析：站点常用**没有 .m3u8 后缀**的播放列表 URL，
                // 光靠嗅探 ffmpeg 会拒收（"Not detecting m3u8/hls with non standard
                // extension and non standard mime type"，实测退出码 187）。
                "-f", "hls",
            ]
            if modernHLSFlags {
                args += ["-allowed_segment_extensions", "ALL", "-extension_picky", "0"]
            }
            if let referer {
                args += ["-referer", referer.absoluteString]
            }
            if let userAgent {
                args += ["-user_agent", userAgent]
            }
            args += ["-i", playlist.absoluteString]
            // ⚠️ `-map` 是**输出**选项，必须排在 `-i` 之后：放在前面 ffmpeg 直接拒收
            // （"Option map … cannot be applied to input url … you are trying to apply an
            // input option to an output file or vice versa"，实测退出码 234）。
            if let programIndex {
                args += ["-map", "0:p:\(programIndex)"]
            }
            args += [
                // 纯转封装：视频/音频都不重编码，速度只受网络限制。
                "-c", "copy",
                "-f", "mp4",
                "-progress", "pipe:1", "-nostats",
                destination.path,
            ]
            return args
        }

        let diagnostics: String
        do {
            diagnostics = try await run(
                executable: executable,
                arguments: arguments(modernHLSFlags: true),
                totalSeconds: totalSeconds,
                deadline: deadline,
                progress: progress
            )
        } catch let error as ExportError {
            // 老版本 ffmpeg：新选项不认。只在这种"选项级"失败上重试，真正的下载
            // 失败（404、连不上）不再重跑一遍。
            guard case .failed(_, let firstDiagnostics) = error,
                  firstDiagnostics.contains("Unrecognized option")
                    || firstDiagnostics.contains("Option not found")
                    || firstDiagnostics.contains("Error parsing options") else { throw error }
            diagnostics = try await run(
                executable: executable,
                arguments: arguments(modernHLSFlags: false),
                totalSeconds: totalSeconds,
                deadline: deadline,
                progress: progress
            )
        }
        return Outcome(bytes: fileSize(destination), diagnostics: diagnostics)
    }

    /// 本地文件转封装成 MP4（手写下载器产出 `.ts` 时用，live 也走这条路）。
    nonisolated static func remux(
        executable: URL,
        source: URL,
        destination: URL,
        deadline: Date
    ) async throws -> Outcome {
        let arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-i", source.path,
            "-c", "copy",
            "-f", "mp4",
            destination.path,
        ]
        let diagnostics = try await run(
            executable: executable,
            arguments: arguments,
            totalSeconds: 0,
            deadline: deadline,
            progress: { _, _ in }
        )
        return Outcome(bytes: fileSize(destination), diagnostics: diagnostics)
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - 进程

    /// 跑 ffmpeg，转发取消（SIGTERM），并在 deadline 到期时终止。
    private nonisolated static func run(
        executable: URL,
        arguments: [String],
        totalSeconds: Double,
        deadline: Date,
        progress: @MainActor @escaping (Int, Int) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collector = Collector()
        // `-progress pipe:1` 是 key=value 行；只认 out_time_us（注意
        // out_time_ms 其实也是微秒，是 ffmpeg 的著名笔误，所以别用它）。
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendProgressLines(data, totalSeconds: totalSeconds) { done, total in
                Task { @MainActor in progress(done, total) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendDiagnostics(data)
        }

        let watchdog = Task {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            collector.markTimedOut()
            process.terminate()
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            watchdog.cancel()
            throw ExportError.launchFailed(error.localizedDescription)
        }

        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // waitUntilExit 是阻塞调用，放到后台线程。
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        } onCancel: {
            process.terminate()
        }
        watchdog.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        let diagnostics = collector.diagnosticsTail()
        if Task.isCancelled { throw CancellationError() }
        if collector.didTimeOut { throw ExportError.timedOut }
        guard status == 0 else { throw ExportError.failed(code: status, diagnostics: diagnostics) }
        return diagnostics
    }

    /// 读取回调在任意线程上跑，这里只做加锁累加。
    ///
    /// **`nonisolated` 不能省**：模块默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 嵌套在这个 enum 里的类会被推断成 MainActor 隔离，而它是在 `readabilityHandler`
    /// 的回调线程上被调用的——不标就会报一堆 "main actor-isolated … cannot be called
    /// from outside of the actor"（2026-09-23 用户贴出的警告清单）。线程安全靠
    /// `NSLock` + `@unchecked Sendable`，与 actor 无关。
    private nonisolated final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var lineBuffer = ""
        private var diagnostics = ""
        private var lastReportedSecond = -1
        private var total = 0.0
        private var timedOut = false

        func appendProgressLines(_ data: Data, totalSeconds: Double, emit: @escaping (Int, Int) -> Void) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            total = totalSeconds
            lineBuffer += text
            var lines: [String] = []
            while let newline = lineBuffer.firstIndex(of: "\n") {
                lines.append(String(lineBuffer[..<newline]))
                lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
            }
            var reports: [(Int, Int)] = []
            for line in lines where line.hasPrefix("out_time_us=") {
                guard let micros = Double(line.dropFirst("out_time_us=".count)), totalSeconds > 0 else { continue }
                let seconds = Int(micros / 1_000_000)
                if seconds > lastReportedSecond {
                    lastReportedSecond = seconds
                    reports.append((seconds, Int(totalSeconds.rounded())))
                }
            }
            lock.unlock()
            for report in reports { emit(report.0, report.1) }
        }

        func appendDiagnostics(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            diagnostics += text
            if diagnostics.count > 4000 { diagnostics = String(diagnostics.suffix(4000)) }
            lock.unlock()
        }

        func markTimedOut() {
            lock.lock(); timedOut = true; lock.unlock()
        }

        var didTimeOut: Bool {
            lock.lock(); defer { lock.unlock() }; return timedOut
        }

        func diagnosticsTail() -> String {
            lock.lock(); defer { lock.unlock() }
            let lines = diagnostics.split(separator: "\n").suffix(4)
            return lines.joined(separator: " | ").trimmingCharacters(in: .whitespaces)
        }
    }
}
