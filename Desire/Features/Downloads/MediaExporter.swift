import CommonCrypto
import Foundation
import WebKit

/// Downloads media to the user's Downloads folder: direct files (mp4/webm/…)
/// and HLS playlists (m3u8 → segments → single concatenated file).
///
/// HLS notes:
/// - Master playlists are followed once to the highest-bandwidth variant.
/// - Relative segment URLs resolve against the playlist URL.
/// - EXT-X-MAP (fMP4 init segment) is prepended to the output, so fMP4
///   streams export as playable .mp4; MPEG-TS streams concatenate as .ts.
/// - AES-128 encrypted segments (EXT-X-KEY) are decrypted with CommonCrypto;
///   the key is fetched with the same Referer/UA as the segments. SAMPLE-AES
///   is not supported.
/// - Live playlists (no EXT-X-ENDLIST) export the segments available now,
///   with a warning in the result.
///
/// Runs through its own URLSession (NOT WebKit's): the player's CDN usually
/// serves segments without cookies, and hotlink protection is handled by
/// sending the page URL as Referer plus the webview's Safari user agent.
@MainActor
enum MediaExporter {
    /// 进度计数的单位：ffmpeg 直连按秒、内置下载器按段。
    enum ProgressUnit: String {
        case segments, seconds
    }

    struct Result {
        let fileURL: URL
        /// 段数——只有手写下载器知道；ffmpeg 直连是流式转封装，没有"段"的概念。
        let segmentCount: Int?
        let bytes: Int64
        let warnings: [String]
        /// 完整性校验摘要（"4.0s, 1920x1080"）；nil = 本机没 ffprobe 或校验未通过。
        var verification: String?

        var displayBytes: String {
            let mb = Double(bytes) / 1_048_576
            return mb >= 1 ? String(format: "%.1f MB", mb) : "\(bytes / 1024) KB"
        }

        /// 摘要里那句"怎么来的"。
        var displayDetail: String {
            if let segmentCount { return "\(segmentCount) segment(s)" }
            return "MP4 via ffmpeg"
        }
    }

    enum ExportError: LocalizedError {
        case notAPlaylist
        case badStatus(Int)
        case unsupportedEncryption(String)
        case tooManySegmentFailures
        case noSegmentsDownloaded
        case timedOut
        /// 手写下载器也失败时，把之前 ffmpeg 的失败原因一并带上——否则用户只看到
        /// 第二条错误，第一条（真正的原因）没了。
        case fallbackFailed(notes: [String], underlying: String)

        var errorDescription: String? {
            switch self {
            case .notAPlaylist: "URL did not return an m3u8 playlist or a media file"
            case .badStatus(let code): "Server returned HTTP \(code) (the signed URL may have expired — re-extract the address and retry)"
            case .unsupportedEncryption(let method): "Playlist uses unsupported encryption: \(method)"
            case .tooManySegmentFailures: "Too many segments failed to download"
            case .noSegmentsDownloaded: "Every segment failed to download — nothing was saved"
            case .timedOut: "Export exceeded the 30-minute time limit"
            case .fallbackFailed(let notes, let underlying):
                ([underlying] + notes).joined(separator: " — ")
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    // MARK: - Entry point

    /// Exports `url` (direct media file or HLS playlist) into ~/Downloads.
    /// `progress` reports (completed, total): segments for the built-in
    /// downloader, seconds for the ffmpeg path. Hard-capped at 30 minutes.
    ///
    /// **装了 ffmpeg 就优先用它**（Homebrew 的 `/opt/homebrew/bin/ffmpeg` 最常见）：
    /// 直接下载 HLS 并转封装成 MP4——音轨分离（`EXT-X-MEDIA`）的站点也能带上音频，
    /// `EXT-X-BYTERANGE` / `EXT-X-DISCONTINUITY` 这类手写下载器不处理的形态它也认。
    /// 没装、是 live、或 ffmpeg 失败 → 回退手写下载器，行为与以前一致。
    static func download(
        url: URL,
        referer: URL?,
        userAgent: String?,
        fileNameHint: String?,
        maxBandwidth: Int? = nil,
        folderName: String? = nil,
        baseDirectory: String? = nil,
        progress: @MainActor @escaping (Int, Int, ProgressUnit) -> Void
    ) async throws -> Result {
        let started = Date()
        let deadline = started.addingTimeInterval(30 * 60)

        // 非 .m3u8 也要抓一次：没有该后缀的播放列表靠这一步发现（原逻辑）。
        // 顺带把文本喂给 ffmpeg 判定，省掉重复请求。
        var directFile: (data: Data, response: URLResponse)?
        var playlistText: String?
        if url.pathExtension.lowercased() != "m3u8" {
            let (data, response) = try await fetch(url: url, referer: referer, userAgent: userAgent)
            if let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") {
                playlistText = text
            } else {
                directFile = (data, response)
            }
        }

        if let directFile {
            let mime = (directFile.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let fileURL = try destinationURL(for: url, hint: fileNameHint, isMP4: mime.contains("mp4"), folderName: folderName, baseDirectory: baseDirectory)
            try Self.writePartAndFinalize(fileURL) { part in
                try directFile.data.write(to: part)
            }
            progress(1, 1, .segments)
            let verification = FFmpegExporter.probeSummary(fileURL: fileURL)
            return Result(fileURL: fileURL, segmentCount: 1, bytes: Int64(directFile.data.count), warnings: [], verification: verification)
        }

        var warnings: [String] = []

        // ① ffmpeg 直连（仅 VOD：live 会让 ffmpeg 一直等新分片，见 FFmpegExporter 注释）。
        if let ffmpeg = FFmpegExporter.locate(),
           let plan = try? await ffmpegPlan(
                url: url, playlistText: playlistText,
                referer: referer, userAgent: userAgent, maxBandwidth: maxBandwidth
           ) {
            do {
                let destination = try destinationURL(for: url, hint: fileNameHint, isMP4: true, folderName: folderName, baseDirectory: baseDirectory)
                let outcome = try await Self.writePartAndFinalizeAsync(destination) { part in
                    try await FFmpegExporter.export(
                        executable: ffmpeg,
                        playlist: plan.url,
                        referer: referer,
                        userAgent: userAgent,
                        cookieHeader: await cookieHeader(for: url),
                        programIndex: plan.programIndex,
                        totalSeconds: plan.totalSeconds,
                        destination: part,
                        deadline: deadline,
                        progress: { done, total in progress(done, total, .seconds) }
                    )
                }
                let verification = FFmpegExporter.probeSummary(fileURL: destination)
                return Result(fileURL: destination, segmentCount: nil, bytes: outcome.bytes, warnings: warnings, verification: verification)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                warnings.append("ffmpeg direct export failed, fell back to the built-in downloader: \(error.localizedDescription)")
            }
        }

        // ② 手写下载器：先按码率上限把 master 收敛到具体 variant（原行为）。
        var playlistURL = url
        if let maxBW = maxBandwidth, maxBW > 0, url.pathExtension.lowercased() == "m3u8" {
            let variants = try await listVariants(url: url, referer: referer, userAgent: userAgent)
            if let selected = selectVariant(from: variants, maxBandwidth: maxBW) {
                playlistURL = selected
            }
        }

        do {
            let result = try await exportHLS(
                url: playlistURL,
                playlistText: playlistText,
                referer: referer,
                userAgent: userAgent,
                fileNameHint: fileNameHint,
                folderName: folderName,
                baseDirectory: baseDirectory,
                deadlineCheck: { guard Date() < deadline else { throw ExportError.timedOut } },
                progress: progress
            )
            return try await remuxToMP4IfNeeded(result, extraWarnings: warnings, deadline: deadline)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !warnings.isEmpty else { throw error }
            throw ExportError.fallbackFailed(notes: warnings, underlying: error.localizedDescription)
        }
    }

    /// 手写下载器产出 `.ts`（live、或 ffmpeg 直连失败）时，装了 ffmpeg 就顺手
    /// 转封装成 MP4——用户要的是能直接播的 mp4，不是 mpegts。
    private static func remuxToMP4IfNeeded(
        _ result: Result,
        extraWarnings: [String],
        deadline: Date
    ) async throws -> Result {
        var warnings = extraWarnings + result.warnings
        guard result.fileURL.pathExtension.lowercased() == "ts",
              let ffmpeg = FFmpegExporter.locate() else {
            return Result(fileURL: result.fileURL, segmentCount: result.segmentCount,
                          bytes: result.bytes, warnings: warnings, verification: result.verification)
        }
        let destination = try uniqueDestination(beside: result.fileURL, extension: "mp4")
        do {
            let outcome = try await Self.writePartAndFinalizeAsync(destination) { part in
                try await FFmpegExporter.remux(
                    executable: ffmpeg, source: result.fileURL,
                    destination: part, deadline: deadline
                )
            }
            try? FileManager.default.removeItem(at: result.fileURL)
            let verification = FFmpegExporter.probeSummary(fileURL: destination)
            return Result(fileURL: destination, segmentCount: result.segmentCount,
                          bytes: outcome.bytes, warnings: warnings, verification: verification)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append("MP4 conversion failed, kept the .ts file: \(error.localizedDescription)")
            return Result(fileURL: result.fileURL, segmentCount: result.segmentCount,
                          bytes: result.bytes, warnings: warnings, verification: nil)
        }
    }

    // MARK: - ffmpeg 直连的可行性判定

    private struct FFmpegPlan {
        /// 喂给 ffmpeg 的播放列表 URL：原始是 master 就用原始 URL（**保住音频组**），
        /// 否则用媒体播放列表自身。
        let url: URL
        /// 选中 variant 在 master 里的文件顺序下标（= ffmpeg 的 program 号）。
        let programIndex: Int?
        let totalSeconds: Double
    }

    /// 返回 nil 表示"这条不该交给 ffmpeg"（不是播放列表 / 是 live）。
    private static func ffmpegPlan(
        url: URL,
        playlistText: String?,
        referer: URL?,
        userAgent: String?,
        maxBandwidth: Int?
    ) async throws -> FFmpegPlan? {
        var text = playlistText
        if text == nil {
            let (data, _) = try await fetch(url: url, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8), fetched.contains("#EXTM3U") else { return nil }
            text = fetched
        }
        guard var mediaText = text else { return nil }

        var programIndex: Int?
        if mediaText.contains("#EXT-X-STREAM-INF") {
            let variants = parseVariants(mediaText, baseURL: url).sorted {
                ($0["bandwidth"] as? Int ?? 0) > ($1["bandwidth"] as? Int ?? 0)
            }
            guard let chosen = selectVariantEntry(from: variants, maxBandwidth: maxBandwidth),
                  let chosenURL = URL(string: chosen["url"] as? String ?? "") else { return nil }
            // 只有设了上限才显式指定 program；不限速时让 ffmpeg 自己挑最高码率。
            if let ceiling = maxBandwidth, ceiling > 0 {
                programIndex = chosen["index"] as? Int
            }
            let (data, _) = try await fetch(url: chosenURL, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8) else { return nil }
            mediaText = fetched
        }

        // live（无 ENDLIST）绝不能交给 ffmpeg：它会一直等新分片，`-t` 也拦不住。
        guard mediaText.contains("#EXT-X-ENDLIST") else { return nil }
        return FFmpegPlan(url: url, programIndex: programIndex, totalSeconds: extinfTotal(mediaText))
    }

    /// 播放列表里 `EXTINF` 之和——只用于把 ffmpeg 的 `out_time_us` 换算成进度。
    private static func extinfTotal(_ text: String) -> Double {
        var total = 0.0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXTINF:") else { continue }
            let value = trimmed.dropFirst("#EXTINF:".count).prefix { $0 != "," }
            total += Double(value) ?? 0
        }
        return total
    }

    // MARK: - HLS

    /// Parses a master m3u8 playlist and returns all available quality
    /// variants (bandwidth + resolution + absolute URL). Non-master
    /// playlists return an empty array (media playlist, single quality).
    static func listVariants(url: URL, referer: URL?, userAgent: String?) async throws -> [[String: Any]] {
        let (data, _) = try await fetch(url: url, referer: referer, userAgent: userAgent)
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U"),
              text.contains("#EXT-X-STREAM-INF") else { return [] }
        return parseVariants(text, baseURL: url).sorted { first, second in
            (first["bandwidth"] as? Int ?? 0) > (second["bandwidth"] as? Int ?? 0)
        }
    }

    /// master 播放列表文本 → variant 记录（**文件顺序**，未排序）。
    ///
    /// `index` 是文件顺序下标，等于 ffmpeg 的 program 号——`-map 0:p:N` 用它，
    /// 所以排序之后也不能丢（`listVariants` 会按码率再排一次）。
    private static func parseVariants(_ text: String, baseURL: URL) -> [[String: Any]] {
        let lines = text.components(separatedBy: .newlines)
        var variants: [[String: Any]] = []
        var pendingBandwidth = 0
        var pendingResolution = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = Int(attribute("BANDWIDTH", in: trimmed) ?? "") ?? 0
                pendingResolution = attribute("RESOLUTION", in: trimmed) ?? ""
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#"), pendingBandwidth > 0 {
                if let variant = URL(string: trimmed, relativeTo: baseURL) {
                    variants.append([
                        "bandwidth": pendingBandwidth,
                        "resolution": pendingResolution,
                        "index": variants.count,
                        "url": variant.absoluteString,
                    ])
                }
                pendingBandwidth = 0
                pendingResolution = ""
            }
        }
        return variants
    }

    /// 与 `selectVariant` 同语义，但返回整条记录（要读 `index`）。
    private static func selectVariantEntry(from variants: [[String: Any]], maxBandwidth: Int?) -> [String: Any]? {
        guard let maxBW = maxBandwidth, maxBW > 0 else { return variants.first }
        let eligible = variants.filter { ($0["bandwidth"] as? Int ?? 0) <= maxBW }
        return eligible.first ?? variants.last
    }

    /// Selects the best variant URL under a bandwidth ceiling (or highest).
    static func selectVariant(from variants: [[String: Any]], maxBandwidth: Int?) -> URL? {
        guard let maxBW = maxBandwidth, maxBW > 0 else {
            guard let first = variants.first,
                  let urlString = first["url"] as? String else { return nil }
            return URL(string: urlString)
        }
        // Pick the highest variant that fits the ceiling; fall back to lowest.
        let eligible = variants.filter { ($0["bandwidth"] as? Int ?? 0) <= maxBW }
        let chosen = eligible.first ?? variants.last
        guard let urlString = chosen?["url"] as? String else { return nil }
        return URL(string: urlString)
    }

    // MARK: - HLS

    private static func exportHLS(
        url: URL,
        playlistText: String? = nil,
        referer: URL?,
        userAgent: String?,
        fileNameHint: String?,
        folderName: String? = nil,
        baseDirectory: String? = nil,
        deadlineCheck: () throws -> Void,
        progress: @MainActor (Int, Int, ProgressUnit) -> Void
    ) async throws -> Result {
        var warnings: [String] = []
        var text = playlistText
        var playlistURL = url
        if text == nil {
            let (data, _) = try await fetch(url: url, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8), fetched.contains("#EXTM3U") else {
                throw ExportError.notAPlaylist
            }
            text = fetched
        }
        guard let playlistText = text else { throw ExportError.notAPlaylist }

        // Master playlist → follow the highest-bandwidth variant once.
        if playlistText.contains("#EXT-X-STREAM-INF") {
            let lines = playlistText.components(separatedBy: .newlines)
            var best: (bandwidth: Int, url: URL)?
            var pendingBandwidth = 0
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                    pendingBandwidth = Int(attribute("BANDWIDTH", in: trimmed) ?? "") ?? 0
                } else if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    if let variant = URL(string: trimmed, relativeTo: url),
                       let abs = URL(string: variant.absoluteString),
                       pendingBandwidth > (best?.bandwidth ?? -1) {
                        best = (pendingBandwidth, abs)
                    }
                    pendingBandwidth = 0
                }
            }
            guard let variant = best?.url else { throw ExportError.notAPlaylist }
            let (data, _) = try await fetch(url: variant, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8) else { throw ExportError.notAPlaylist }
            text = fetched
            playlistURL = variant
            warnings.append("master playlist → selected variant \(variant.lastPathComponent)")
        }
        guard let finalText = text else { throw ExportError.notAPlaylist }

        // Parse the media playlist.
        let lines = finalText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var segments: [(url: URL, index: Int)] = []
        var initSegment: URL?
        var keyURI: String?
        var keyIV: Data?
        var mediaSequence = 0
        var hasEndList = false

        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attribute("METHOD", in: line)
                if method == "NONE" {
                    keyURI = nil
                } else if method == "AES-128" {
                    keyURI = attribute("URI", in: line)
                    if let ivHex = attribute("IV", in: line) {
                        keyIV = Self.data(fromHex: ivHex)
                    }
                } else if let method, !method.isEmpty {
                    throw ExportError.unsupportedEncryption(method)
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let uri = attribute("URI", in: line) {
                    initSegment = URL(string: uri, relativeTo: playlistURL).flatMap { URL(string: $0.absoluteString) }
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                hasEndList = true
            } else if line.hasPrefix("#") {
                continue
            } else if !line.isEmpty {
                if let seg = URL(string: line, relativeTo: playlistURL),
                   let abs = URL(string: seg.absoluteString) {
                    segments.append((abs, mediaSequence + segments.count))
                }
            }
        }
        guard !segments.isEmpty else { throw ExportError.notAPlaylist }
        if !hasEndList {
            warnings.append("live stream (no ENDLIST) — exporting the segments available now")
        }

        // Fetch the AES key once, if any.
        var keyData: Data?
        if let keyURI {
            guard let keyURL = URL(string: keyURI, relativeTo: playlistURL).flatMap({ URL(string: $0.absoluteString) }) else {
                throw ExportError.unsupportedEncryption("unreadable key URI")
            }
            let (data, _) = try await fetch(url: keyURL, referer: referer, userAgent: userAgent)
            keyData = data
        }

        // Destination: .mp4 when fMP4 (EXT-X-MAP), else .ts (MPEG-TS).
        let isFMP4 = initSegment != nil && (initSegment!.pathExtension.lowercased() == "mp4" || initSegment!.pathExtension.lowercased() == "m4s")
        let finalURL = try destinationURL(for: playlistURL, hint: fileNameHint, isMP4: isFMP4, folderName: folderName, baseDirectory: baseDirectory)
        let fileURL = finalURL.appendingPathExtension("part")

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        if let initSegment {
            let (data, _) = try await fetch(url: initSegment, referer: referer, userAgent: userAgent)
            try handle.write(contentsOf: data)
        }

        var bytes: Int64 = 0
        var done = 0
        var failures = 0
        for segment in segments {
            try deadlineCheck()
            // Stop co-operates with tool execution: user-initiated task
            // cancellation must abort the remaining segments (a cancelled
            // URLSession surfaces as URLError.cancelled — rethrow, never
            // count it as a segment failure).
            try Task.checkCancellation()
            var data: Data?
            for attempt in 0..<2 {
                do {
                    let (fetched, _) = try await fetch(url: segment.url, referer: referer, userAgent: userAgent)
                    data = fetched
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch {
                    if attempt == 1 { failures += 1 }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            guard var payload = data else {
                if failures >= 5 { throw ExportError.tooManySegmentFailures }
                continue
            }
            if let keyData {
                let iv = keyIV ?? Self.sequenceIV(mediaSequence + done)
                payload = try Self.decrypt(payload, key: keyData, iv: iv)
            }
            try handle.write(contentsOf: payload)
            bytes += Int64(payload.count)
            done += 1
            progress(done, segments.count, .segments)
        }

        // 一个段都没下到（全 404 / 全被跳过）不能算成功——以前会留下一个 0 字节的
        // 文件并报"完成"，用户点开是空的。
        guard done > 0 else {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw ExportError.noSegmentsDownloaded
        }
        try Self.finalizePart(fileURL, final: finalURL)

        return Result(
            fileURL: finalURL,
            segmentCount: done,
            bytes: bytes,
            warnings: failures > 0
                ? warnings + ["\(failures) segment(s) failed and were skipped"]
                : warnings
        )
    }

    // MARK: - Plumbing

    // MARK: - 原子落盘（.part + 成功改名）

    /// 所有下载一律写 `<final>.part`、成功后改名——崩溃/取消只留一个
    /// `.part`（下次尝试原地覆盖），不再产生 "-1" 后缀的残件链。
    private static func writePartAndFinalize(_ finalURL: URL, _ body: (URL) throws -> Void) throws {
        let part = finalURL.appendingPathExtension("part")
        do {
            try body(part)
            try finalizePart(part, final: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    private static func writePartAndFinalizeAsync(_ finalURL: URL, _ body: (URL) async throws -> FFmpegExporter.Outcome) async throws -> FFmpegExporter.Outcome {
        let part = finalURL.appendingPathExtension("part")
        do {
            let outcome = try await body(part)
            try finalizePart(part, final: finalURL)
            return outcome
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    private static func finalizePart(_ part: URL, final: URL) throws {
        if FileManager.default.fileExists(atPath: final.path) {
            _ = try FileManager.default.replaceItemAt(final, withItemAt: part)
        } else {
            try FileManager.default.moveItem(at: part, to: final)
        }
    }

    private static func fetch(url: URL, referer: URL?, userAgent: String?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let cookie = await cookieHeader(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExportError.badStatus(http.statusCode)
        }
        return (data, response)
    }

    private static func destinationURL(for source: URL, hint: String?, isMP4: Bool, folderName: String? = nil, baseDirectory: String? = nil) throws -> URL {
        // 自定义根目录（用户在低空间询问里选过"换位置"后记住的偏好）优先；
        // 没有就落 ~/Downloads。
        let parent: URL
        if let baseDirectory, !baseDirectory.isEmpty {
            parent = URL(fileURLWithPath: baseDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } else {
            parent = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        }
        var directory = parent
        if let folderName, !folderName.isEmpty {
            // 批量下载按批次归档；目录名同样做消毒（防路径穿越）。
            let folder = folderName.replacingOccurrences(of: "/", with: "-")
            directory = parent.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let ext = isMP4 ? "mp4" : (source.pathExtension.lowercased() == "mp4" ? "mp4" : "ts")
        var base = hint ?? source.deletingPathExtension().lastPathComponent
        base = base.components(separatedBy: "?").first ?? base
        base = base.replacingOccurrences(of: "/", with: "-")
        if base.isEmpty { base = "export-\(Int(Date().timeIntervalSince1970))" }
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - Cookie 透传

    /// 媒体 CDN 也可能挂在 Cloudflare 后面（分段请求被 bot management 拦下
    /// 返回 403）。这里把**同域**的 webview Cookie 附到 URLSession 请求上；
    /// `cf_clearance` 与 UA 绑定——调用方必须传同一个 Safari UA（下载路径
    /// 一直如此），否则 Cookie 反而暴露"UA 与获发时不一致"。
    ///
    /// 缓存 30s：一份 2000 段的 HLS 会打几千次 fetch，不能每次都读
    /// cookie store；Cookie 的变更频率远低于此。
    private static var cookieCache: (fetchedAt: Date, cookies: [HTTPCookie])?

    private static func cookieHeader(for url: URL) async -> String? {
        let cookies = await matchingCookies(for: url)
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func matchingCookies(for url: URL) async -> [HTTPCookie] {
        if cookieCache == nil || Date().timeIntervalSince(cookieCache!.fetchedAt) > 30 {
            let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            cookieCache = (Date(), all)
        }
        guard let host = url.host?.lowercased() else { return [] }
        let secure = url.scheme == "https"
        return cookieCache!.cookies.filter { cookie in
            if cookie.isSecure && !secure { return false }
            var domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
            return host == domain || host.hasSuffix(".\(domain)")
        }
    }

    /// 与 `source` 同目录、换扩展名的唯一路径（转 `.ts` → `.mp4` 时用）。
    private static func uniqueDestination(beside source: URL, extension ext: String) throws -> URL {
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// `KEY="value"` extractor for EXT attribute lines (double-quoted values).
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=\"") else {
            // Unquoted form (BANDWIDTH=1234)
            guard let eq = line.range(of: "\(name)=") else { return nil }
            let tail = line[eq.upperBound...]
            let value = tail.prefix { !$0.isWhitespace && $0 != "," }
            return value.isEmpty ? nil : String(value)
        }
        let tail = line[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }

    private static func data(fromHex hex: String) -> Data? {
        var string = hex.hasPrefix("0x") || hex.hasPrefix("0X") ? String(hex.dropFirst(2)) : hex
        guard string.count % 2 == 0 else { return nil }
        var data = Data()
        while !string.isEmpty {
            let pair = string.prefix(2)
            guard let byte = UInt8(pair, radix: 16) else { return nil }
            data.append(byte)
            string = String(string.dropFirst(2))
        }
        return data
    }

    /// Default IV when EXT-X-KEY omits one: the 128-bit big-endian media
    /// sequence number of the segment (per the HLS spec).
    private static func sequenceIV(_ sequence: Int) -> Data {
        // HLS 规范：无 IV 属性时 IV = 64 位大端媒体序号左补零到 128 位。
        // Data(count: 8) 的 8 个零即左填充——**不要再 insert**：曾多插 8 个零
        // 变成 24 字节，CCCrypt 只读前 16（全零 IV），坏 IV 每段损坏前 16 字节
        // 而 PKCS7 校验仍过 → 导出"成功"但花屏（P0-E，实证）。
        var bigEndianSequence = UInt64(sequence).bigEndian
        var iv = Data(count: 8)
        withUnsafeBytes(of: &bigEndianSequence) { iv.append(contentsOf: $0) }
        return iv
    }

    private static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16 else { throw ExportError.unsupportedEncryption("key is \(key.count) bytes") }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                iv.withUnsafeBytes { ivPtr in
                    key.withUnsafeBytes { keyPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, data.count,
                            outPtr.baseAddress, outPtr.count, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ExportError.unsupportedEncryption("CCCrypt status \(status)") }
        out.removeSubrange(moved..<out.count)
        return out
    }
}
