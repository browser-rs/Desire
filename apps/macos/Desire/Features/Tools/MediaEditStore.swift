import AVFoundation
import Combine
import Foundation

/// 媒体剪辑执行引擎（v0.8.27 媒体批）：剪切 / 拼接 / 提音轨。
///
/// 路线：**AVFoundation 优先**（无外部依赖、系统编码器），失败或异形容器
/// （mkv/webm/flac…）回退 **ffmpeg**（`FFmpegExporter.locate()` 探测，未装则
/// 给出可读错误）。两条硬规矩：
/// - **长任务模式**（同 MediaExportStore）：`launch` 立即登记 Job、后台 Task
///   执行、进度可观察、可取消——绝不 await 到底阻塞调用方。
/// - **进度**：AVFoundation 用 `states(updateInterval:)` 异步流（`progress`
///   属性在 macOS 27 已废弃）；ffmpeg 解析 `-progress pipe:1` 的
///   `out_time_us`（按已播时长 / 估算总时长换算）。
///
/// AVFoundation 侧 API 形态（macOS 26 SDK 实测）：`export(to:as:)` async throws
/// 支持 Task 取消；`states()` 流须与 export **并发**消费（export 前单消费会挂住）。
@MainActor
final class MediaEditStore: ObservableObject {
    static let shared = MediaEditStore()

    enum JobKind {
        case trimVideo, trimAudio, concatVideo, concatAudio, extractAudio

        var symbol: String {
            switch self {
            case .trimVideo: "film"
            case .trimAudio: "waveform"
            case .concatVideo: "film.stack"
            case .concatAudio: "waveform.stack"
            case .extractAudio: "music.note.list"
            }
        }
    }

    enum JobState: Equatable {
        case running, done, failed, cancelled
    }

    struct Job: Identifiable {
        let id: UUID
        let kind: JobKind
        let label: String
        var progress: Double
        var state: JobState
        var outputURL: URL?
        var message: String?
    }

    @Published private(set) var jobs: [Job] = []

    private var tasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - 公开入口

    func trimVideo(source: URL, plan: MediaEditCore.TrimPlan, precise: Bool) {
        let label = String(localized: "Trim video: \(source.lastPathComponent)")
        launch(kind: .trimVideo, label: label) { progress in
            try await MediaEditEngine.trimVideo(source: source, plan: plan,
                                                precise: precise, progress: progress)
        }
    }

    func trimAudio(source: URL, plan: MediaEditCore.TrimPlan) {
        let label = String(localized: "Trim audio: \(source.lastPathComponent)")
        launch(kind: .trimAudio, label: label) { progress in
            try await MediaEditEngine.trimAudio(source: source, plan: plan, progress: progress)
        }
    }

    func concatVideo(sources: [URL]) {
        let label = String(localized: "Merge \(sources.count) clips")
        launch(kind: .concatVideo, label: label) { progress in
            try await MediaEditEngine.concatVideo(sources: sources, progress: progress)
        }
    }

    func concatAudio(sources: [URL]) {
        let label = String(localized: "Merge \(sources.count) audio clips")
        launch(kind: .concatAudio, label: label) { progress in
            try await MediaEditEngine.concatAudio(sources: sources, progress: progress)
        }
    }

    func extractAudio(source: URL) {
        let label = String(localized: "Extract audio: \(source.lastPathComponent)")
        launch(kind: .extractAudio, label: label) { progress in
            try await MediaEditEngine.extractAudio(source: source, progress: progress)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    // MARK: - 任务登记

    private func launch(kind: JobKind, label: String,
                        body: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> URL) {
        let id = UUID()
        jobs.insert(Job(id: id, kind: kind, label: label, progress: 0,
                        state: .running, outputURL: nil, message: nil), at: 0)
        if jobs.count > 12 { jobs.removeLast(jobs.count - 12) }
        let report: @Sendable (Double) -> Void = { fraction in
            let value = min(1, max(0, fraction))
            // 强捕获 self：MediaEditStore 是 app 级单例，生命周期=进程。
            Task { @MainActor in
                self.update(id) { $0.progress = value }
            }
        }
        tasks[id] = Task { [weak self] in
            do {
                let url = try await body(report)
                self?.finish(id: id, state: .done, url: url, message: nil)
            } catch is CancellationError {
                self?.finish(id: id, state: .cancelled, url: nil, message: nil)
            } catch {
                self?.finish(id: id, state: .failed, url: nil, message: error.localizedDescription)
            }
        }
    }

    private func update(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    private func finish(id: UUID, state: JobState, url: URL?, message: String?) {
        tasks[id] = nil
        update(id) {
            $0.state = state
            $0.progress = state == .done ? 1 : $0.progress
            $0.outputURL = url
            $0.message = message
        }
    }
}

// MARK: - 错误

enum MediaEditError: LocalizedError {
    case noInputs
    case engineUnavailable
    case ffmpegMissing
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputs:
            return String(localized: "Choose at least two clips to merge.")
        case .engineUnavailable:
            return String(localized: "This file can't be processed by the built-in engine.")
        case .ffmpegMissing:
            return String(localized: "This container needs ffmpeg, which isn't installed (brew install ffmpeg).")
        case .ffmpegFailed(let diagnostics):
            return String(localized: "ffmpeg failed: \(diagnostics)")
        }
    }
}

// MARK: - 探测（视图侧可用的薄包装）

nonisolated enum MediaEditProbe {
    /// 媒体时长（秒）：AVFoundation 优先，异形容器由 ffprobe 兜底。
    static func duration(_ url: URL) async -> Double? {
        await MediaEditEngine.probeDuration(url)
    }
}

// MARK: - 引擎（无隔离：后台 Task 里跑）

private nonisolated enum MediaEditEngine {

    // MARK: 剪切

    static func trimVideo(source: URL, plan: MediaEditCore.TrimPlan, precise: Bool,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = resolveDestination(source: source, suffix: "trimmed",
                                      ext: MediaEditCore.outputExtension(source: source, audioOnly: false))
        // 局部函数改名 fallback：与引擎的 runFFmpeg(arguments:) 撞名会解析到零参局部函数。
        func fallbackFFmpeg() async throws -> URL {
            try await runFFmpeg(arguments: MediaEditCore.appendingProgressArgs(
                MediaEditCore.ffmpegTrimArgs(input: source.path, output: dest.path,
                                             plan: plan, reencode: precise)),
                durationHint: plan.duration, progress: progress)
        }
        guard MediaEditCore.isAVFoundationFriendly(ext: source.pathExtension) else {
            return try await fallbackFFmpeg()
        }
        do {
            let session = try makeSession(asset: AVURLAsset(url: source),
                                          preset: precise ? AVAssetExportPresetHighestQuality
                                                          : AVAssetExportPresetPassthrough)
            try await export(session: session, to: dest, fileType: .mp4,
                             timeRange: CMTimeRange(start: CMTime(seconds: plan.start, preferredTimescale: 600),
                                                    end: CMTime(seconds: plan.end, preferredTimescale: 600)),
                             progress: progress)
            return dest
        } catch {
            guard FFmpegExporter.locate() != nil else { throw error }
            return try await fallbackFFmpeg()
        }
    }

    static func trimAudio(source: URL, plan: MediaEditCore.TrimPlan,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = resolveDestination(source: source, suffix: "trimmed", ext: "m4a")
        func fallbackFFmpeg() async throws -> URL {
            try await runFFmpeg(arguments: MediaEditCore.appendingProgressArgs(
                MediaEditCore.ffmpegTrimAudioArgs(input: source.path, output: dest.path, plan: plan)),
                durationHint: plan.duration, progress: progress)
        }
        // AVFoundation 的 AppleM4A 预设能吃 mp3/wav/aiff 等常见音频；其余交给 ffmpeg。
        let avFriendly = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "mp4", "mov", "m4v"]
            .contains(source.pathExtension.lowercased())
        guard avFriendly else { return try await fallbackFFmpeg() }
        do {
            let session = try makeSession(asset: AVURLAsset(url: source),
                                          preset: AVAssetExportPresetAppleM4A)
            try await export(session: session, to: dest, fileType: .m4a,
                             timeRange: CMTimeRange(start: CMTime(seconds: plan.start, preferredTimescale: 600),
                                                    end: CMTime(seconds: plan.end, preferredTimescale: 600)),
                             progress: progress)
            return dest
        } catch {
            guard FFmpegExporter.locate() != nil else { throw error }
            return try await fallbackFFmpeg()
        }
    }

    // MARK: 拼接

    static func concatVideo(sources: [URL],
                            progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard sources.count >= 2 else { throw MediaEditError.noInputs }
        let first = sources[0]
        let dest = resolveDestination(source: first, suffix: "merged",
                                      ext: MediaEditCore.outputExtension(source: first, audioOnly: false))

        // 快路径：同壳 + 同编码 + 同尺寸 + 音轨状况一致 + 有 ffmpeg → 流复制（秒级）。
        if FFmpegExporter.locate() != nil {
            let probe = await streamConcatProbe(sources: sources)
            if probe.canStream {
                let list = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("desire-concat-\(UUID().uuidString).txt")
                try MediaEditCore.buildConcatList(sources.map { $0.path })
                    .write(to: list, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: list) }
                return try await runFFmpeg(arguments: MediaEditCore.appendingProgressArgs(
                    MediaEditCore.ffmpegConcatCopyArgs(listFile: list.path, output: dest.path)),
                    durationHint: probe.totalDuration, progress: progress)
            }
        }

        // AVFoundation 合成（重编码，混合分辨率/编码也稳）。
        if MediaEditCore.isAVFoundationFriendly(ext: first.pathExtension) {
            do {
                let composition = try await buildComposition(sources: sources)
                let session = try makeSession(asset: composition,
                                              preset: AVAssetExportPresetHighestQuality)
                try await export(session: session, to: dest, fileType: .mp4, progress: progress)
                return dest
            } catch {
                guard FFmpegExporter.locate() != nil else { throw error }
            }
        }

        // ffmpeg filter_complex 重编码；音轨混杂时按纯视频拼（最后手段）。
        let hasAudio = try await allInputsHaveAudio(sources: sources)
        return try await runFFmpeg(arguments: MediaEditCore.appendingProgressArgs(
            MediaEditCore.ffmpegConcatFilterArgs(inputs: sources.map { $0.path },
                                                 output: dest.path, hasAudio: hasAudio)),
            durationHint: nil, progress: progress)
    }

    static func concatAudio(sources: [URL],
                            progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard sources.count >= 2 else { throw MediaEditError.noInputs }
        let dest = resolveDestination(source: sources[0], suffix: "merged", ext: "m4a")
        let composition = try await buildComposition(sources: sources, audioOnly: true)
        do {
            let session = try makeSession(asset: composition, preset: AVAssetExportPresetAppleM4A)
            try await export(session: session, to: dest, fileType: .m4a, progress: progress)
            return dest
        } catch {
            guard FFmpegExporter.locate() != nil else { throw error }
        }
        // ffmpeg 兜底：concat demuxer 统一重编码 aac（异编码也能进同一清单）。
        let list = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("desire-concat-\(UUID().uuidString).txt")
        try MediaEditCore.buildConcatList(sources.map { $0.path })
            .write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        return try await runFFmpeg(arguments: MediaEditCore.appendingProgressArgs(
            MediaEditCore.ffmpegConcatAudioArgs(listFile: list.path, output: dest.path)),
            durationHint: nil, progress: progress)
    }

    // MARK: 提音轨

    static func extractAudio(source: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = resolveDestination(source: source, suffix: "audio", ext: "m4a")
        do {
            let session = try makeSession(asset: AVURLAsset(url: source),
                                          preset: AVAssetExportPresetAppleM4A)
            try await export(session: session, to: dest, fileType: .m4a, progress: progress)
            return dest
        } catch {
            guard FFmpegExporter.locate() != nil else { throw error }
            return try await runFFmpeg(arguments: MediaEditCore.appendingProgressArgs(
                MediaEditCore.ffmpegExtractAudioArgs(input: source.path, output: dest.path)),
                durationHint: nil, progress: progress)
        }
    }

    // MARK: 探测

    /// 时长：AVFoundation 读不到（异形容器）且装了 ffmpeg 时用 ffprobe 兜底。
    static func probeDuration(_ url: URL) async -> Double? {
        if let duration = try? await AVURLAsset(url: url).load(.duration).seconds,
           duration.isFinite, duration > 0 {
            return duration
        }
        guard let probe = FFmpegExporter.locate()?.deletingLastPathComponent()
            .appendingPathComponent("ffprobe"),
            FileManager.default.isExecutableFile(atPath: probe.path) else { return nil }
        let process = Process()
        process.executableURL = probe
        process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "json", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = obj["format"] as? [String: Any],
              let text = format["duration"] as? String,
              let seconds = Double(text), seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// 是否都有音轨（filter_complex 的 [i:a] 全在或全无，混了就解析失败）。
    private static func allInputsHaveAudio(sources: [URL]) async throws -> Bool {
        for url in sources {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
            if tracks.isEmpty { return false }
        }
        return true
    }

    private struct StreamConcatProbe {
        var canStream = false
        var totalDuration: Double?
    }

    /// 流复制拼接的可行性：同编码、同尺寸、音轨状况一致；顺带算总时长。
    /// （编码经 formatDescriptions 的 media subtype 读——AVAssetTrack 没有
    /// codecType 的 async 属性。）
    private static func streamConcatProbe(sources: [URL]) async -> StreamConcatProbe {
        var codec: String?
        var size: CGSize?
        var uniformAudio: Bool?
        var total: Double = 0
        for url in sources {
            let asset = AVURLAsset(url: url)
            guard let video = try? await asset.loadTracks(withMediaType: .video).first,
                  let trackCodec = try? await trackCodecKey(video),
                  let trackSize = try? await video.load(.naturalSize),
                  let duration = try? await asset.load(.duration).seconds,
                  duration.isFinite, duration >= 0 else { return StreamConcatProbe() }
            total += duration
            if let codec, codec != trackCodec { return StreamConcatProbe() }
            if let size, abs(size.width - trackSize.width) > 0.5
                || abs(size.height - trackSize.height) > 0.5 { return StreamConcatProbe() }
            let hasAudio = ((try? await asset.loadTracks(withMediaType: .audio).count) ?? 0) > 0
            if let uniformAudio, uniformAudio != hasAudio { return StreamConcatProbe() }
            codec = trackCodec
            size = trackSize
            uniformAudio = hasAudio
        }
        return StreamConcatProbe(canStream: true, totalDuration: total)
    }

    private static func trackCodecKey(_ track: AVAssetTrack) async throws -> String {
        let descriptions = try await track.load(.formatDescriptions)
        guard let first = descriptions.first else { return "" }
        return fourCCString(CMFormatDescriptionGetMediaSubType(first))
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    /// 顺序合成（视频 + 音轨各一条，按时间线依次插入）。
    private static func buildComposition(sources: [URL], audioOnly: Bool = false) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let videoTrack = audioOnly
            ? nil
            : composition.addMutableTrack(withMediaType: .video,
                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        for url in sources {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let videoTrack, let track = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: track, at: cursor)
            }
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let target: AVMutableCompositionTrack
                if let existing = audioTrack {
                    target = existing
                } else if let created = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    audioTrack = created
                    target = created
                } else {
                    throw MediaEditError.engineUnavailable
                }
                try target.insertTimeRange(range, of: track, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        if videoTrack == nil && audioTrack == nil {
            throw MediaEditError.engineUnavailable
        }
        return composition
    }

    // MARK: AVFoundation 导出

    private static func makeSession(asset: AVAsset, preset: String) throws -> AVAssetExportSession {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaEditError.engineUnavailable
        }
        return session
    }

    /// 导出 + 进度流（states 与 export 并发消费；Task.cancel 会取消导出）。
    private static func export(session: AVAssetExportSession, to dest: URL, fileType: AVFileType,
                               timeRange: CMTimeRange? = nil,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: dest)
        if let timeRange { session.timeRange = timeRange }
        let stream = session.states(updateInterval: 0.25)
        let watcher = Task {
            for try await state in stream {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: dest, as: fileType)
    }

    // MARK: ffmpeg 执行

    @discardableResult
    static func runFFmpeg(arguments: [String], durationHint: Double?,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let ffmpeg = FFmpegExporter.locate() else { throw MediaEditError.ffmpegMissing }
        guard let last = arguments.last else { throw MediaEditError.noInputs }
        let output = URL(fileURLWithPath: last)
        try? FileManager.default.removeItem(at: output)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let errTask = Task { errPipe.fileHandleForReading.readDataToEndOfFile() }
        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled {
                    process.terminate()
                    throw CancellationError()
                }
                if line.hasPrefix("out_time_us="),
                   let microseconds = Double(line.dropFirst("out_time_us=".count)),
                   let hint = durationHint, hint > 0 {
                    progress(min(0.99, (microseconds / 1_000_000) / hint))
                }
            }
        } catch is CancellationError {
            process.terminate()
            throw CancellationError()
        }
        process.waitUntilExit()
        _ = await errTask.value
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw MediaEditError.ffmpegFailed("exit code \(process.terminationStatus)")
        }
        return output
    }

    // MARK: 落点

    /// 与源文件同目录（不可写则退 Downloads）；重名追加 -2、-3…
    static func resolveDestination(source: URL, suffix: String, ext: String) -> URL {
        let sourceDir = source.deletingLastPathComponent()
        let directory = FileManager.default.isWritableFile(atPath: sourceDir.path)
            ? sourceDir
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = MediaEditCore.derivedFileName(sourceName: source.lastPathComponent,
                                                 suffix: suffix, ext: ext)
        var destination = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (name as NSString).deletingPathExtension
            let extPart = (name as NSString).pathExtension
            destination = directory.appendingPathComponent("\(base)-\(counter).\(extPart)")
            counter += 1
        }
        return destination
    }
}
