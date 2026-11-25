import Foundation
import os

/// **分片并发预取**（v0.8.77 批 3）。
///
/// 背景（2026-11-25 真实使用）：两条 HLS 引擎都是**串行**抓分片——ffmpeg 单进程读
/// 远端播放列表、内置下载器逐片 `for` 循环。CDN 对单连接限速（实测约 160KB/s），
/// 2 小时的片要 2 小时以上，而导出默认超时 30 分钟——长片在默认配置下必然失败。
/// 同一台机器上并发抓分片实测快 14 倍（32 连接约 6 分钟一部）。
///
/// 做法：先把分片**并发**抓到本地工作目录，再写一份"本地播放列表"（分片、密钥、
/// 初始化段都指向本地文件，其余标签原样保留），交给 ffmpeg 解密合成；没有 ffmpeg
/// 时内置下载器按序读本地分片、解密、拼接。
///
/// 三条可靠性设计：
/// - **自适应降速**：连续失败就把连接数减半（下限 2）——被限流时少开连接反而更快；
/// - **过期即停**：签名地址过期（401/403/410）在同一个地址上重试没有意义——累计到
///   阈值立刻停，抛 `addressExpired`，由批量引擎重新解析页面后续传；
/// - **分片级续传**：工作目录按 `resumeKey`（批量条目 id）稳定命名，重新解析后分片
///   地址全变，但顺序和条数不变——已有的分片直接复用，只补缺的。
extension MediaExporter {

    /// 每路连接数默认值；站点规则（适配器的 `download.connections`）可以覆盖。
    nonisolated static let defaultConnections = DPPDownloadRules.defaultConnections
    /// 每路连接数下限。
    nonisolated static let minConnections = DPPDownloadRules.minConnections
    /// 批内所有下载合计的连接预算（调用方按并发路数折算每路上限）。
    nonisolated static let connectionBudget = 32
    /// 签名地址过期：累计这么多个分片返回 401/403/410 就判定过期。
    nonisolated static let expiredThreshold = 3
    /// 两轮之后仍缺的分片多于这个数（或超过总数的 2%）才算失败；否则跳过它们。
    nonisolated static let maxSkippedSegments = 5

    struct PrefetchedHLS {
        let playlist: HLSMediaPlaylist
        /// 媒体播放列表地址（原始是 master 时为选中的变体）。
        let mediaURL: URL
        let workDirectory: URL
        let localPlaylistURL: URL
        /// 这一轮新抓到的分片数（续传时小于总数）。
        let fetched: Int
        let connectionsUsed: Int
        /// 两轮之后仍抓不到、被跳过的分片序号（本地播放列表里没有它们）。
        let skipped: [Int]
        /// 媒体播放列表原文（内置下载器回退路径要自己再解析一遍）。
        let mediaText: String

        func segmentFile(_ index: Int) -> URL {
            workDirectory.appendingPathComponent(MediaExporter.localSegmentName(playlist, index))
        }
    }

    enum SegmentOutcome: Sendable {
        case ok, expired, failed
    }

    /// 本地分片文件名：保留原扩展名（ffmpeg 按扩展名/format 探测；fMP4 分片不能叫 `.ts`）。
    nonisolated static func localSegmentName(_ playlist: HLSMediaPlaylist, _ index: Int) -> String {
        let ext = playlist.segments.first(where: { $0.index == index })?.url.pathExtension.lowercased() ?? ""
        return "\(index)." + (ext.isEmpty ? "ts" : ext)
    }

    /// 工作目录的稳定键：批量条目 id；单文件下载用地址（去查询串）的稳定散列。
    static func workDirectoryKey(url: URL, resumeKey: String?) -> String {
        if let resumeKey, !resumeKey.isEmpty { return resumeKey }
        let bare = url.absoluteString.split(separator: "?").first.map(String.init) ?? url.absoluteString
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for scalar in bare.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// 解析出媒体播放列表（master → 最高码率变体）。
    static func resolveMediaPlaylist(
        url: URL, playlistText: String?, referer: URL?, userAgent: String?
    ) async throws -> (playlist: HLSMediaPlaylist, mediaURL: URL, text: String) {
        var text = playlistText
        var mediaURL = url
        if text == nil {
            let (data, _) = try await fetch(url: url, referer: referer, userAgent: userAgent)
            text = String(data: data, encoding: .utf8)
        }
        guard let raw = text, raw.contains("#EXTM3U") else { throw ExportError.notAPlaylist }
        if raw.contains("#EXT-X-STREAM-INF") {
            let variants = parseVariants(raw, baseURL: url).sorted {
                ($0["bandwidth"] as? Int ?? 0) > ($1["bandwidth"] as? Int ?? 0)
            }
            guard let chosen = variants.first,
                  let chosenURL = URL(string: chosen["url"] as? String ?? "") else {
                throw ExportError.notAPlaylist
            }
            let (data, _) = try await fetch(url: chosenURL, referer: referer, userAgent: userAgent)
            guard let fetched = String(data: data, encoding: .utf8) else { throw ExportError.notAPlaylist }
            text = fetched
            mediaURL = chosenURL
        }
        guard let mediaText = text,
              let playlist = try? HLSMediaPlaylist.parse(mediaText, baseURL: mediaURL) else {
            throw ExportError.notAPlaylist
        }
        return (playlist, mediaURL, mediaText)
    }

    /// 预取全部缺失的分片（含密钥与初始化段），写出本地播放列表。
    /// 抓不全的分片最多再试一轮；仍缺的少量分片从本地播放列表里去掉（与内置下载器
    /// "失败的分片跳过"同一口径），缺得太多才算失败。
    static func prefetchHLS(
        url: URL,
        playlistText: String?,
        referer: URL?,
        userAgent: String?,
        connections: Int,
        resumeKey: String?,
        deadlineCheck: () throws -> Void,
        progress: @MainActor (Int, Int, ProgressUnit) -> Void
    ) async throws -> PrefetchedHLS {
        let resolved = try await resolveMediaPlaylist(
            url: url, playlistText: playlistText, referer: referer, userAgent: userAgent)
        let playlist = resolved.playlist
        let fm = FileManager.default
        let workDirectory = fm.temporaryDirectory.appendingPathComponent(
            "desire-hls-\(workDirectoryKey(url: url, resumeKey: resumeKey))", isDirectory: true)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        sweepStaleWorkDirectories()

        // 同一个工作目录只能属于同一份播放列表：条数或时长变了就是另一部片子。
        let fingerprintFile = workDirectory.appendingPathComponent("fingerprint.txt")
        if let existing = try? String(contentsOf: fingerprintFile, encoding: .utf8), existing != playlist.fingerprint {
            try? fm.removeItem(at: workDirectory)
            try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        }
        try playlist.fingerprint.write(to: fingerprintFile, atomically: true, encoding: .utf8)

        // 密钥与初始化段：各一个小文件，已有就复用。
        if let keyURL = playlist.keyURL {
            let keyFile = workDirectory.appendingPathComponent("key.bin")
            if !fm.fileExists(atPath: keyFile.path) {
                try deadlineCheck()
                let (data, _) = try await fetch(url: keyURL, referer: referer, userAgent: userAgent)
                guard data.count == 16 else {
                    throw ExportError.unsupportedEncryption("AES-128 key of \(data.count) bytes")
                }
                try data.write(to: keyFile, options: .atomic)
            }
        }
        if let initURL = playlist.initSegmentURL {
            let initFile = workDirectory.appendingPathComponent("init.mp4")
            if !fm.fileExists(atPath: initFile.path) {
                try deadlineCheck()
                let (data, _) = try await fetch(url: initURL, referer: referer, userAgent: userAgent)
                try data.write(to: initFile, options: .atomic)
            }
        }

        let total = playlist.segments.count
        func isPresent(_ segment: HLSMediaPlaylist.Segment) -> Bool {
            fm.fileExists(atPath: workDirectory.appendingPathComponent(localSegmentName(playlist, segment.index)).path)
        }
        var done = total - playlist.segments.filter { !isPresent($0) }.count
        let initiallyPresent = done
        progress(done, total, .segments)

        var workers = max(1, connections)
        let connectionsUsed = workers
        // 第一轮：按 connections 并发；第二轮：对仍缺的再试一次（并发更低）。
        for round in 0..<2 {
            let missing = playlist.segments.filter { !isPresent($0) }
            guard !missing.isEmpty else { break }
            let roundConnections = round == 0 ? workers : min(4, max(1, workers))
            let (_, expired) = try await fetchSegments(
                missing, playlist: playlist, workDirectory: workDirectory,
                connections: roundConnections, referer: referer, userAgent: userAgent,
                deadlineCheck: deadlineCheck,
                onProgress: { done += 1; progress(done, total, .segments) })
            if expired >= expiredThreshold { throw ExportError.addressExpired(segments: expired) }
            workers = roundConnections
        }

        let skipped = playlist.segments.filter { !isPresent($0) }.map(\.index)
        if skipped.count > maxSkippedSegments, Double(skipped.count) > Double(total) * 0.02 {
            throw ExportError.tooManySegmentFailures
        }

        let localPlaylistURL = workDirectory.appendingPathComponent("local.m3u8")
        try playlist.localText(
            segmentFile: { localSegmentName(playlist, $0) },
            keyFile: playlist.keyURL != nil ? "key.bin" : nil,
            initFile: playlist.initSegmentURL != nil ? "init.mp4" : nil,
            omitting: Set(skipped)
        ).write(to: localPlaylistURL, atomically: true, encoding: .utf8)
        return PrefetchedHLS(playlist: playlist, mediaURL: resolved.mediaURL, workDirectory: workDirectory,
                             localPlaylistURL: localPlaylistURL, fetched: done - initiallyPresent,
                             connectionsUsed: connectionsUsed, skipped: skipped, mediaText: resolved.text)
    }

    /// 并发抓一批分片。返回（成功数，过期数）。连续失败会把这一轮的并发减半（下限 2）。
    static func fetchSegments(
        _ segments: [HLSMediaPlaylist.Segment],
        playlist: HLSMediaPlaylist,
        workDirectory: URL,
        connections: Int,
        referer: URL?,
        userAgent: String?,
        deadlineCheck: () throws -> Void,
        onProgress: @MainActor () -> Void
    ) async throws -> (ok: Int, expired: Int) {
        var workers = max(1, min(connections, segments.count))
        var next = 0
        var inFlight = 0
        var ok = 0
        var expired = 0
        var consecutiveFailures = 0
        var stopped = false
        try await withThrowingTaskGroup(of: SegmentOutcome.self) { group in
            // 补位：让在途数始终等于 workers（workers 会随失败减半）。
            func refill() {
                while !stopped, inFlight < workers, next < segments.count {
                    let segment = segments[next]
                    let destination = workDirectory.appendingPathComponent(localSegmentName(playlist, segment.index))
                    next += 1
                    inFlight += 1
                    group.addTask {
                        await fetchSegment(segment, to: destination, referer: referer, userAgent: userAgent)
                    }
                }
            }
            refill()
            while let outcome = try await group.next() {
                inFlight -= 1
                switch outcome {
                case .ok:
                    ok += 1
                    consecutiveFailures = 0
                    onProgress()
                case .expired:
                    expired += 1
                    if expired >= expiredThreshold {
                        // 只是不再补位——**不取消在途的请求**：它们抓完的分片续传时直接
                        // 复用（取消掉就白抓了；过期的地址本来就是立刻返回 403，在途的
                        // 不会拖很久）。
                        stopped = true
                    }
                case .failed:
                    // 停机之后不再按失败降速（这一轮马上结束）。
                    if stopped || Task.isCancelled { break }
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3, workers > minConnections {
                        workers = max(minConnections, workers / 2)
                        consecutiveFailures = 0
                        Log.downloads.info("hls prefetch: backing off to \(workers) connection(s)")
                    }
                }
                try deadlineCheck()
                refill()
            }
        }
        return (ok, expired)
    }

    /// 单个分片：最多 4 次，带退避；签名过期（401/403/410）不重试直接上报。
    static func fetchSegment(_ segment: HLSMediaPlaylist.Segment, to file: URL,
                             referer: URL?, userAgent: String?) async -> SegmentOutcome {
        let fm = FileManager.default
        let temporary = file.deletingPathExtension().appendingPathExtension("part")
        for attempt in 0..<4 {
            if Task.isCancelled { return .failed }
            do {
                let (data, _) = try await fetch(url: segment.url, referer: referer, userAgent: userAgent)
                try data.write(to: temporary, options: .atomic)
                if fm.fileExists(atPath: file.path) { try? fm.removeItem(at: file) }
                try fm.moveItem(at: temporary, to: file)
                return .ok
            } catch let error as ExportError {
                if case .badStatus(let code) = error {
                    if [401, 403, 410].contains(code) { return .expired }
                    if [429, 500, 502, 503, 504].contains(code) {
                        if attempt == 3 { return .failed }
                        try? await Task.sleep(for: .milliseconds(400 << attempt))
                        continue
                    }
                }
                return .failed
            } catch is CancellationError {
                return .failed
            } catch let error as URLError where error.code == .cancelled {
                return .failed
            } catch {
                if attempt == 3 { return .failed }
                try? await Task.sleep(for: .milliseconds(300 * (attempt + 1)))
            }
        }
        return .failed
    }

    /// 清掉两天前的预取工作目录（强杀/取消留下的）。
    static func sweepStaleWorkDirectories(now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("desire-hls-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(modified) > 2 * 86_400 { try? fm.removeItem(at: entry) }
        }
    }
}
