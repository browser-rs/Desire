import CommonCrypto
import Foundation

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
    struct Result {
        let fileURL: URL
        /// 段数——只有手写下载器知道；ffmpeg 直连是流式转封装，没有"段"的概念。
        let segmentCount: Int?
        let bytes: Int64
        let warnings: [String]

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
        progress: @MainActor @escaping (Int, Int) -> Void
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
            let fileURL = try destinationURL(for: url, hint: fileNameHint, isMP4: mime.contains("mp4"))
            try directFile.data.write(to: fileURL)
            progress(1, 1)
            return Result(fileURL: fileURL, segmentCount: 1, bytes: Int64(directFile.data.count), warnings: [])
        }

        var warnings: [String] = []

        // ① ffmpeg 直连（仅 VOD：live 会让 ffmpeg 一直等新分片，见 FFmpegExporter 注释）。
        if let ffmpeg = FFmpegExporter.locate(),
           let plan = try? await ffmpegPlan(
                url: url, playlistText: playlistText,
                referer: referer, userAgent: userAgent, maxBandwidth: maxBandwidth
           ) {
            do {
                let destination = try destinationURL(for: url, hint: fileNameHint, isMP4: true)
                let outcome = try await FFmpegExporter.export(
                    executable: ffmpeg,
                    playlist: plan.url,
                    referer: referer,
                    userAgent: userAgent,
                    programIndex: plan.programIndex,
                    totalSeconds: plan.totalSeconds,
                    destination: destination,
                    deadline: deadline,
                    progress: progress
                )
                return Result(fileURL: destination, segmentCount: nil, bytes: outcome.bytes, warnings: warnings)
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
                          bytes: result.bytes, warnings: warnings)
        }
        let destination = try uniqueDestination(beside: result.fileURL, extension: "mp4")
        do {
            let outcome = try await FFmpegExporter.remux(
                executable: ffmpeg, source: result.fileURL,
                destination: destination, deadline: deadline
            )
            try? FileManager.default.removeItem(at: result.fileURL)
            return Result(fileURL: destination, segmentCount: result.segmentCount,
                          bytes: outcome.bytes, warnings: warnings)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append("MP4 conversion failed, kept the .ts file: \(error.localizedDescription)")
            return Result(fileURL: result.fileURL, segmentCount: result.segmentCount,
                          bytes: result.bytes, warnings: warnings)
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
        deadlineCheck: () throws -> Void,
        progress: @MainActor (Int, Int) -> Void
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
        let fileURL = try destinationURL(for: playlistURL, hint: fileNameHint, isMP4: isFMP4)

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
            progress(done, segments.count)
        }

        // 一个段都没下到（全 404 / 全被跳过）不能算成功——以前会留下一个 0 字节的
        // 文件并报"完成"，用户点开是空的。
        guard done > 0 else {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw ExportError.noSegmentsDownloaded
        }

        return Result(
            fileURL: fileURL,
            segmentCount: done,
            bytes: bytes,
            warnings: failures > 0
                ? warnings + ["\(failures) segment(s) failed and were skipped"]
                : warnings
        )
    }

    // MARK: - Plumbing

    private static func fetch(url: URL, referer: URL?, userAgent: String?) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ExportError.badStatus(http.statusCode)
        }
        return (data, response)
    }

    private static func destinationURL(for source: URL, hint: String?, isMP4: Bool) throws -> URL {
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let ext = isMP4 ? "mp4" : (source.pathExtension.lowercased() == "mp4" ? "mp4" : "ts")
        var base = hint ?? source.deletingPathExtension().lastPathComponent
        base = base.components(separatedBy: "?").first ?? base
        base = base.replacingOccurrences(of: "/", with: "-")
        if base.isEmpty { base = "export-\(Int(Date().timeIntervalSince1970))" }
        var candidate = downloads.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloads.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
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
        var bigEndianSequence = UInt64(sequence).bigEndian
        var iv = Data(count: 8)
        withUnsafeBytes(of: &bigEndianSequence) { iv.append(contentsOf: $0) }
        iv.insert(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0], at: 0)
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
