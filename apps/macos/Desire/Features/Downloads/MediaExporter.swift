import CommonCrypto
import os
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
        /// 分片全部下载完成后的合成（remux/concat）阶段——此前此阶段无任何
        /// 进度上报，UI 静止像假死（用户实测"分段都下完了导出一直 running"）。
        case merging
    }

    struct Result {
        let fileURL: URL
        /// 段数——只有手写下载器知道；ffmpeg 直连是流式转封装，没有"段"的概念。
        let segmentCount: Int?
        let bytes: Int64
        let warnings: [String]
        /// 完整性校验摘要（"4.0s, 1920x1080 h264+aac"）；nil = 本机没 ffprobe 或校验未通过。
        var verification: String?
        /// 产物实测分辨率（verification 的结构化部分），供与源上限比对。
        var downloadedResolution: String? = nil
        /// 源播放列表的变体清单摘要（"source: 4 variants, max 1920x1080"）——
        /// "确定下载的就是高质量"的另一半凭证：光知道下了什么不够，还得知道
        /// 源里最高有什么。直连文件（非 HLS）没有变体概念，保持 nil。
        var sourceSummary: String? = nil
        var sourceMaxResolution: String? = nil
        /// 调用方设了码率上限（挑低档是**有意**的，qualityNote 不对此报警）。
        var bandwidthCapped: Bool = false

        var displayBytes: String {
            let mb = Double(bytes) / 1_048_576
            return mb >= 1 ? String(format: "%.1f MB", mb) : "\(bytes / 1024) KB"
        }

        /// 摘要里那句"怎么来的"。
        var displayDetail: String {
            if let segmentCount { return "\(segmentCount) segment(s)" }
            return "MP4 via ffmpeg"
        }

        /// 下载档明显低于源上限时的人读警告（面积差 >1/3 才算"明显"——
        /// 同档不同标法 1280x720 vs 1280x714 这类不吭声）。设了码率上限不报。
        var qualityNote: String? {
            guard !bandwidthCapped,
                  let src = sourceMaxResolution.flatMap(Self.pixelArea),
                  let got = downloadedResolution.flatMap(Self.pixelArea),
                  Double(got) < Double(src) * 0.67 else { return nil }
            return "downloaded \(downloadedResolution ?? "?") but the source offered up to \(sourceMaxResolution ?? "?")"
        }

        static func pixelArea(_ wxh: String) -> Int? {
            let parts = wxh.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
            return w * h
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
            case .timedOut:
                BatchMediaPreferences.exportTimeoutMinutes > 0
                    ? "Export exceeded the \(BatchMediaPreferences.exportTimeoutMinutes)-minute time limit"
                    : "Export timed out"
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
        // 总时长上限可配置（默认 30 分钟，0 = 不限）——长视频/慢网络不再被
        // 写死的 30 分钟切掉（用户实测两个任务跑满 30 分钟失败）。
        let limitMinutes = BatchMediaPreferences.exportTimeoutMinutes
        let deadline = limitMinutes > 0
            ? started.addingTimeInterval(TimeInterval(limitMinutes * 60))
            : .distantFuture

        // 非 .m3u8 也要抓一次：没有该后缀的播放列表靠这一步发现（原逻辑）。
        // 顺带把文本喂给 ffmpeg 判定，省掉重复请求。
        var directFile: (data: Data, response: URLResponse)?
        var playlistText: String?
        var streamedLargeFile = false
        if url.pathExtension.lowercased() != "m3u8" {
            // 第十批：直连媒体先探内容类型——视频/大文件**绝不**整段读进内存
            //（2-4GB 视频原路径 = 数 GB 峰值内存，并发时 jetsam 风险），
            // 交由下方 downloadTask 流式落 .part。小型/未知类型仍走内存路径。
            var request = URLRequest(url: url)
            if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
            if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
            request.httpMethod = "HEAD"
            let mimeHint: String?
            if let (_, response) = try? await session.data(for: request) {
                mimeHint = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            } else {
                mimeHint = nil
            }
            let looksLikeMedia = mimeHint?.hasPrefix("video/") == true
                || mimeHint?.hasPrefix("audio/") == true
                || ["mp4", "webm", "mkv", "mov", "m4v", "avi", "ts", "flv"].contains(url.pathExtension.lowercased())

            if looksLikeMedia {
                let fileURL = try destinationURL(for: url, hint: fileNameHint, isMP4: true, folderName: folderName, baseDirectory: baseDirectory)
                let result = try await streamDownloadToPart(
                    url: url, referer: referer, userAgent: userAgent,
                    finalURL: fileURL, mimeMP4: mimeHint?.contains("mp4") == true)
                progress(1, 1, .segments)
                streamedLargeFile = true
                let probe = FFmpegExporter.probe(fileURL: fileURL)
                return Result(fileURL: fileURL, segmentCount: 1, bytes: result, warnings: [],
                              verification: probe.summary, downloadedResolution: probe.resolution)
            }

            let (data, response) = try await fetch(url: url, referer: referer, userAgent: userAgent)
            if let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") {
                playlistText = text
            } else {
                directFile = (data, response)
            }
        }

        if streamedLargeFile {
            // 不可达（上方已 return）——编译器满足用
        }

        if let directFile {
            let mime = (directFile.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let fileURL = try destinationURL(for: url, hint: fileNameHint, isMP4: mime.contains("mp4"), folderName: folderName, baseDirectory: baseDirectory)
            try Self.writePartAndFinalize(fileURL) { part in
                try directFile.data.write(to: part)
            }
            progress(1, 1, .segments)
            let probe = FFmpegExporter.probe(fileURL: fileURL)
            return Result(fileURL: fileURL, segmentCount: 1, bytes: Int64(directFile.data.count), warnings: [],
                          verification: probe.summary, downloadedResolution: probe.resolution)
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
                let probe = FFmpegExporter.probe(fileURL: destination)
                return Result(fileURL: destination, segmentCount: nil, bytes: outcome.bytes, warnings: warnings,
                              verification: probe.summary, downloadedResolution: probe.resolution,
                              sourceSummary: plan.sourceSummary, sourceMaxResolution: plan.sourceMaxResolution,
                              bandwidthCapped: (maxBandwidth ?? 0) > 0)
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
            // **重试复用完整 .ts**：remux 失败（超时/中断）保留的 .ts 是完整
            // 下载产物——重试同一 URL 时直接进 remux，不重新抓全部分片
            //（01 号 6.4GB 实测重复下载整片）。ffmpeg 可用才走这条捷径。
            if playlistText != nil || url.pathExtension.lowercased() == "m3u8",
               FFmpegExporter.locate() != nil {
                let reuseURL = try destinationURL(for: playlistURL, hint: fileNameHint, isMP4: false, folderName: folderName, baseDirectory: baseDirectory)
                // .ts（isMP4=false → ts 扩展名）存在且 >100MB 视为完整产物
                if reuseURL.pathExtension.lowercased() == "ts",
                   FileManager.default.fileExists(atPath: reuseURL.path),
                   let attrs = try? FileManager.default.attributesOfItem(atPath: reuseURL.path),
                   (attrs[.size] as? Int64 ?? 0) > 100_000_000 {
                    Log.downloads.info("reusing complete .ts for remux: \(reuseURL.lastPathComponent, privacy: .public)")
                    let reused = Result(fileURL: reuseURL, segmentCount: 0, bytes: attrs[.size] as? Int64 ?? 0, warnings: [], verification: nil)
                    let gb = max(1, Int(reused.bytes / 1_073_741_824))
                    let remuxDeadline = min(deadline, Date().addingTimeInterval(TimeInterval(15 * 60 + gb * 2 * 60)))
                    progress(0, 1, .merging)
                    let final = try await remuxToMP4IfNeeded(reused, extraWarnings: warnings, deadline: remuxDeadline, progress: progress)
                    progress(1, 1, .merging)
                    return final
                }
            }
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
            // 合成阶段单独上报进度（面板显示"合成中"），并给**独立短超时**：
            // 合成是本地文件操作，卡住时不再挂满整个总时长上限。
            progress(0, 1, .merging)
            // remux 超时按文件大小动态：15 分钟基线 + 每 GB 2 分钟
            //（6GB ≈ 27 分钟——此前固定 15 分钟误杀大文件转封装）。
            let gb = max(1, Int(result.bytes / 1_073_741_824))
            let remuxDeadline = min(deadline, Date().addingTimeInterval(TimeInterval(15 * 60 + gb * 2 * 60)))
            let final0 = try await remuxToMP4IfNeeded(
                result, extraWarnings: warnings, deadline: remuxDeadline, progress: progress)
            progress(1, 1, .merging)
            var final = final0
            final.bandwidthCapped = (maxBandwidth ?? 0) > 0
            return final
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !warnings.isEmpty else { throw error }
            throw ExportError.fallbackFailed(notes: warnings, underlying: error.localizedDescription)
        }
    }

    /// 批量下载在**开始下载前**登记 .ts 预期落点用：与下载完成 rename 的
    /// 路径同一套推导（下载完成 rename 到此；合成失败/中断后重试凭登记的
    /// 路径直接复用进 remux，不再重新下载整片）。
    static func candidateTSPath(for mediaURL: URL, hint: String?, folderName: String?,
                                baseDirectory: String?) throws -> URL {
        try destinationURL(for: mediaURL, hint: hint, isMP4: false,
                           folderName: folderName, baseDirectory: baseDirectory)
    }

    /// remux-only 任务入口：对**已下完整**的 .ts 直接合成（重试复用场景）。
    /// mp4 落在 .ts 旁边（`uniqueDestination(beside:)`），不重新推导卷。
    static func remuxExistingTS(_ ts: URL, deadline: Date,
                                progress: @MainActor @escaping (Int, Int, ProgressUnit) -> Void = { _, _, _ in }
    ) async throws -> Result {
        let size = ((try? FileManager.default.attributesOfItem(atPath: ts.path))?[.size] as? Int64) ?? 0
        let result = Result(fileURL: ts, segmentCount: 0, bytes: size, warnings: [], verification: nil)
        return try await remuxToMP4IfNeeded(result, extraWarnings: [], deadline: deadline, progress: progress)
    }

    /// 手写下载器产出 `.ts`（live、或 ffmpeg 直连失败）时，装了 ffmpeg 就顺手
    /// 转封装成 MP4——用户要的是能直接播的 mp4，不是 mpegts。
    private static func remuxToMP4IfNeeded(
        _ result: Result,
        extraWarnings: [String],
        deadline: Date,
        progress: @MainActor @escaping (Int, Int, ProgressUnit) -> Void = { _, _, _ in }
    ) async throws -> Result {
        var warnings = extraWarnings + result.warnings
        guard result.fileURL.pathExtension.lowercased() == "ts",
              let ffmpeg = FFmpegExporter.locate() else {
            return Result(fileURL: result.fileURL, segmentCount: result.segmentCount,
                          bytes: result.bytes, warnings: warnings, verification: result.verification,
                          downloadedResolution: result.downloadedResolution,
                          sourceSummary: result.sourceSummary,
                          sourceMaxResolution: result.sourceMaxResolution,
                          bandwidthCapped: result.bandwidthCapped)
        }
        // **重试复用同名 .ts**：remux 失败（超时/中断）后重试整个任务时，此前
        // uniqueDestination 会绕开已存在的 .ts 重新下载整片（01 号 6.4GB 实测
        // 重复下载）。已有同名 .ts = 上一次下载的完整产物，直接复用进 remux。
        let destination = try uniqueDestination(beside: result.fileURL, extension: "mp4")
        do {
            // **心跳进度**：remux 是长操作（6GB 可跑 >3 分钟），周期性发
            // merging 进度——批量槽位看门狗 3 分钟无进度就取消任务，没有
            // 心跳会被误杀（01 号 6.4GB 实测被杀进重试、重复下载整片）。
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    progress(0, 1, .merging)
                }
            }
            defer { heartbeat.cancel() }
            let outcome = try await Self.writePartAndFinalizeAsync(destination) { part in
                try await FFmpegExporter.remux(
                    executable: ffmpeg, source: result.fileURL,
                    destination: part, deadline: deadline
                )
            }
            try? FileManager.default.removeItem(at: result.fileURL)
            let probe = FFmpegExporter.probe(fileURL: destination)
            return Result(fileURL: destination, segmentCount: result.segmentCount,
                          bytes: outcome.bytes, warnings: warnings, verification: probe.summary,
                          downloadedResolution: probe.resolution,
                          sourceSummary: result.sourceSummary,
                          sourceMaxResolution: result.sourceMaxResolution,
                          bandwidthCapped: result.bandwidthCapped)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append("MP4 conversion failed, kept the .ts file: \(error.localizedDescription)")
            return Result(fileURL: result.fileURL, segmentCount: result.segmentCount,
                          bytes: result.bytes, warnings: warnings, verification: nil,
                          downloadedResolution: nil,
                          sourceSummary: result.sourceSummary,
                          sourceMaxResolution: result.sourceMaxResolution,
                          bandwidthCapped: result.bandwidthCapped)
        }
    }

    // MARK: - ffmpeg 直连的可行性判定

    private struct FFmpegPlan {
        /// 喂给 ffmpeg 的播放列表 URL：原始是 master 就用原始 URL（**保住音频组**），
        /// 否则用媒体播放列表自身。
        let url: URL
        /// 选中 variant 在 master 里的文件顺序下标（= ffmpeg 的 program 号）。
        /// **永远显式指定**：不靠 ffmpeg 自己挑——它的默认选择按文件顺序/实现细节
        /// 走，master 把低档排在前面时就翻车；我们要的最高档由自己算出来。
        let programIndex: Int?
        let totalSeconds: Double
        /// 源变体清单摘要（master 才有）："source: 4 variants, max 1920x1080"。
        let sourceSummary: String?
        let sourceMaxResolution: String?
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
        var sourceSummary: String?
        var sourceMaxResolution: String?
        if mediaText.contains("#EXT-X-STREAM-INF") {
            let variants = parseVariants(mediaText, baseURL: url).sorted {
                ($0["bandwidth"] as? Int ?? 0) > ($1["bandwidth"] as? Int ?? 0)
            }
            guard let chosen = selectVariantEntry(from: variants, maxBandwidth: maxBandwidth),
                  let chosenURL = URL(string: chosen["url"] as? String ?? "") else { return nil }
            // 显式钉住选中的 variant（文件顺序下标 = ffmpeg program 号），最高档
            // 不再依赖 ffmpeg 的默认选择。
            programIndex = chosen["index"] as? Int
            // 源清单回执：多少档、最高多少（RESOLUTION 缺失就用码率）。
            if !variants.isEmpty {
                let best = variants[0]
                let maxRes = best["resolution"] as? String
                let maxBW = best["bandwidth"] as? Int ?? 0
                if let maxRes, !maxRes.isEmpty {
                    sourceMaxResolution = maxRes
                    sourceSummary = "source: \(variants.count) variants, max \(maxRes)"
                } else {
                    sourceSummary = "source: \(variants.count) variants, max \(maxBW / 1000)kbps"
                }
            }
            let (data, _) = try await fetch(url: chosenURL, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8) else { return nil }
            mediaText = fetched
        }

        // live（无 ENDLIST）绝不能交给 ffmpeg：它会一直等新分片，`-t` 也拦不住。
        guard mediaText.contains("#EXT-X-ENDLIST") else { return nil }
        return FFmpegPlan(url: url, programIndex: programIndex, totalSeconds: extinfTotal(mediaText),
                          sourceSummary: sourceSummary, sourceMaxResolution: sourceMaxResolution)
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
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                      pendingBandwidth > 0 || !pendingResolution.isEmpty {
                // BANDWIDTH 缺失但写了 RESOLUTION 的 master 也收（旧手写循环接受
                // 它们；条件比它严会让这类源在内置下载器回退时整单丢弃）。
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
        var sourceSummary: String?
        var sourceMaxResolution: String?
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
            let variants = parseVariants(playlistText, baseURL: url).sorted {
                ($0["bandwidth"] as? Int ?? 0) > ($1["bandwidth"] as? Int ?? 0)
            }
            guard let chosen = variants.first,
                  let variant = chosen["url"] as? String,
                  let chosenURL = URL(string: variant) else { throw ExportError.notAPlaylist }
            // 源清单回执（与 ffmpeg 直连路径同口径）：多少档、最高多少。
            if !variants.isEmpty {
                let maxRes = chosen["resolution"] as? String
                let maxBW = chosen["bandwidth"] as? Int ?? 0
                if let maxRes, !maxRes.isEmpty {
                    sourceMaxResolution = maxRes
                    sourceSummary = "source: \(variants.count) variants, max \(maxRes)"
                } else {
                    sourceSummary = "source: \(variants.count) variants, max \(maxBW / 1000)kbps"
                }
            }
            let (data, _) = try await fetch(url: chosenURL, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8) else { throw ExportError.notAPlaylist }
            text = fetched
            playlistURL = chosenURL
            warnings.append("master playlist → selected variant \(chosenURL.lastPathComponent)")
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
        // UUID .part：同 final 名并发导出不交叉写（第十批）
        let fileURL = finalURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "-" + finalURL.lastPathComponent + ".part")

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
                : warnings,
            sourceSummary: sourceSummary,
            sourceMaxResolution: sourceMaxResolution
        )
    }

    // MARK: - Plumbing

    // MARK: - 原子落盘（.part + 成功改名）

    /// 所有下载一律写 `<final>.part`、成功后改名——崩溃/取消只留一个
    /// `.part`（下次尝试原地覆盖），不再产生 "-1" 后缀的残件链。
    private static func writePartAndFinalize(_ finalURL: URL, _ body: (URL) throws -> Void) throws {
        // 第十批：.part 名掺 UUID——同名 final（两批同名文件夹并发）不再交叉
        // 写同一个 .part；同目录保证 finalize 仍是 rename。崩溃残留 = 独立的
        // UUID .part 文件（不覆盖他人），批量 cancel/finalize 扫 *.part 清理。
        let part = finalURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "-" + finalURL.lastPathComponent + ".part")
        do {
            try body(part)
            try finalizePart(part, final: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }
    }

    private static func writePartAndFinalizeAsync(_ finalURL: URL, _ body: (URL) async throws -> FFmpegExporter.Outcome) async throws -> FFmpegExporter.Outcome {
        let part = finalURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "-" + finalURL.lastPathComponent + ".part")
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
            // 批量下载按批次归档。folder 允许**分层**（分卷规则会拼
            // "folder/archived001"）——逐段消毒（防路径穿越），整串替换
            // 会把分层打成横杠、落点变成一层畸形长名。
            directory = parent
            for component in folderName.split(separator: "/") {
                var comp = component.replacingOccurrences(of: ":", with: "-")
                if comp == ".." { comp = "--" }
                guard !comp.isEmpty else { continue }
                directory = directory.appendingPathComponent(comp, isDirectory: true)
            }
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

    /// 第十批：直连媒体流式下载到 `.part`（downloadTask 走磁盘，不占内存），
    /// 成功后 finalize 改名。返回落盘字节数。
    private static func streamDownloadToPart(
        url: URL, referer: URL?, userAgent: String?,
        finalURL: URL, mimeMP4: Bool
    ) async throws -> Int64 {
        var request = URLRequest(url: url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (location, _) = try await session.download(for: request)
        // URLSession 已内部流式落盘（临时文件）；move 到 UUID .part 再走统一
        // finalize（同盘 rename 通常零拷贝）。
        let part = finalURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + "-" + finalURL.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: part)
        try FileManager.default.moveItem(at: location, to: part)
        try finalizePart(part, final: finalURL)
        let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
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
