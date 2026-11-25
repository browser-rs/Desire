import Foundation

/// **正片识别**（v0.8.77 批 1，Foundation-only 进 tests/run.sh）：把一个页面上采集到的
/// 全部媒体资源整理成"排除杂项后的准确正片集合"——可能一个，也可能多个。
///
/// 起因（2026-11-25 真实使用）：`downloadVideoList` 24 个页面排出 33 个任务、同一部
/// 出现 4 次、文件全是 7KB 的碎片。两处根因都在规划层：
/// - 嗅探到的 HLS 分片（`627800.ts`、`627801.ts`…）被判成 video，而族聚类按
///   "主机 + 文件名主干"——每个分片主干不同，各自成簇、各算一个视频；
/// - 解析后"其余全部"一律当兄弟项下载，**没有"杂项"这个概念**。
///
/// 三条纪律：
/// 1. **分片靠结构判断**，不是按扩展名或个数一刀切（`.ts` 也是合法的整片格式）；
/// 2. **每一次排除都有理由**，写进日志与工具回执，可复核；
/// 3. **绝不把页面清空**：按特征判为杂项的资源，只有在还有别的候选时才真的排除。
extension BatchMediaPlan {

    /// 一个正片候选（含证据）。
    struct ContentCandidate: Equatable {
        var resource: MediaResource
        /// 时长（秒）：流 = 播放列表 `#EXTINF` 之和；直链未知 = nil。
        var durationSeconds: Double?
        /// 保留它的依据（类型、大小、来源、时长……）。
        var evidence: [String]
    }

    struct Rejected: Equatable {
        var url: String
        var reason: String
    }

    struct ContentSelection: Equatable {
        var candidates: [ContentCandidate] = []
        var rejected: [Rejected] = []
        /// 分片归并：所属播放列表地址 → 归并进去的分片数（空串 = 没嗅探到播放列表，
        /// 靠"同目录多个连号分片"判定的）。
        var collapsedSegments: [String: Int] = [:]

        var candidateURLs: Set<String> { Set(candidates.map(\.resource.url)) }
    }

    /// 短于这个时长的候选在有别的候选时判为杂项（广告/预览片段）。
    static let minContentSeconds: Double = 90
    /// 没嗅探到播放列表时，同目录至少这么多个连号分片才判定为分片。
    static let numberedSegmentQuorum = 3

    static let segmentExtensions: Set<String> = ["ts", "m4s", "aac", "cmfv", "cmfa"]

    // MARK: - URL 零件

    /// 去掉协议相对前缀（`//cdn…` → `https://cdn…`）。
    static func normalizedURL(_ urlString: String) -> String {
        urlString.hasPrefix("//") ? "https:" + urlString : urlString
    }

    /// 路径扩展名（小写；查询串之前）。没有扩展名 = 空串。
    static func pathExtension(of urlString: String) -> String {
        var name = pathOnly(urlString)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// 文件名主干（去扩展名、去查询串），小写。
    static func fileStem(of urlString: String) -> String {
        var name = pathOnly(urlString)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex { name = String(name[..<dot]) }
        return name.lowercased()
    }

    /// 目录的**路径部分**（以 `/` 结尾，不含主机与查询串）——比较目录亲缘时忽略主机：
    /// 播放列表与分片可能落在不同的 CDN 主机上。
    static func directory(of urlString: String) -> String {
        var path = pathOnly(urlString)
        if let schemeEnd = path.range(of: "://") { path = String(path[schemeEnd.upperBound...]) }
        guard let slash = path.firstIndex(of: "/") else { return "/" }
        let pathPart = String(path[slash...])
        if let last = pathPart.lastIndex(of: "/") { return String(pathPart[...last]) }
        return "/"
    }

    private static func pathOnly(_ urlString: String) -> String {
        var s = normalizedURL(urlString)
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let f = s.firstIndex(of: "#") { s = String(s[..<f]) }
        return s
    }

    // MARK: - 分片

    /// 连号命名：纯数字（≥3 位），或 `seg/segment` + 编号。**不含** `part1` / `chunk2`
    /// 这类——它们更常是多部正片的名字。
    static func isSequentialStem(_ stem: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "^(?:\\d{3,}|(?:seg|segment)[-_]?\\d{2,})$") else { return false }
        let range = NSRange(stem.startIndex..., in: stem)
        return regex.firstMatch(in: stem, range: range) != nil
    }

    /// 分片 → 所属播放列表。判定（结构性的）：
    /// - **同页有播放列表且目录有亲缘**（分片目录在播放列表目录之下或相同）：
    ///   连号命名的分片、`.ts/.m4s/.aac` 一律归并；`.mp4` 只有连号命名才算
    ///   （`video-720p.mp4` 是正片）；
    /// - **没有播放列表**：同目录 ≥ 3 个连号命名的同扩展名资源 → 仍是分片
    ///   （播放列表没被嗅探到），归属记为空串。
    /// 返回 分片地址 → 播放列表地址。
    static func segmentOwners(in resources: [MediaResource]) -> [String: String] {
        let streamDirs: [(url: String, dir: String)] = resources
            .filter { $0.kind == .stream }
            .map { (normalizedURL($0.url), directory(of: normalizedURL($0.url))) }
        // 目录最深的优先：变体在子目录时，分片归给变体而不是 master。
        .sorted { $0.dir.count > $1.dir.count }

        var byDirectory: [String: [(url: String, ext: String, sequential: Bool)]] = [:]
        for resource in resources where resource.kind != .stream && !resource.isBlob {
            let url = normalizedURL(resource.url)
            let ext = pathExtension(of: url)
            let sequential = isSequentialStem(fileStem(of: url))
            let segmentLike = segmentExtensions.contains(ext)
            guard segmentLike || (ext == "mp4" && sequential) else { continue }
            byDirectory[directory(of: url), default: []].append((url, ext, sequential))
        }

        var owners: [String: String] = [:]
        for (dir, items) in byDirectory {
            if let stream = streamDirs.first(where: { dir.hasPrefix($0.dir) }) {
                // 进得了 items 的只可能是连号分片或分片类扩展名（见上面的收录条件）。
                for item in items { owners[item.url] = stream.url }
                continue
            }
            var byExtension: [String: Int] = [:]
            for item in items where item.sequential { byExtension[item.ext, default: 0] += 1 }
            for item in items where item.sequential && (byExtension[item.ext] ?? 0) >= numberedSegmentQuorum {
                owners[item.url] = ""
            }
        }
        return owners
    }

    // MARK: - 杂项

    /// 广告投放/投放相关的域名特征。
    static let adHostTokens = ["doubleclick", "googlesyndication", "googleadservices", "adnxs",
                               "adsrvr", "rubiconproject", "pubmatic", "openx", "criteo",
                               "taboola", "outbrain", "smartadserver", "freewheel", "fwmrm",
                               "adform", "tremorhub", "spotx", "aniview", "brid.tv", "omnitag"]

    /// 按**整词**匹配的广告标记：主机标签、路径段、文件名记号。
    /// `download` / `read` / `header` / `gradient` 这类含 `ad` 的词不在其中——
    /// 按子串匹配会把它们全误杀。
    static let adTokens: Set<String> = ["ad", "ads", "advert", "adverts", "advertising",
                                        "adserv", "adserver", "preroll", "pre-roll", "midroll",
                                        "postroll", "vast", "vpaid", "vmap", "commercial", "commercials"]

    /// 预览/缩略图特征（文件名记号，整词）。
    static let previewTokens: Set<String> = ["preview", "previews", "thumb", "thumbs",
                                             "thumbnail", "thumbnails", "poster", "teaser"]

    /// 按特征判定的杂项理由；nil = 没有杂项特征。
    static func junkReason(for urlString: String) -> String? {
        let original = urlString
        if isAdSlotResource(original) { return "ad slot size in URL" }
        let lowered = normalizedURL(original).lowercased()
        guard let url = URL(string: lowered), let host = url.host else { return nil }
        if adHostTokens.contains(where: { host.contains($0) }) { return "ad-serving host (\(host))" }
        let hostLabels = host.split(separator: ".").map(String.init)
        if hostLabels.contains(where: { adTokens.contains($0) }) { return "ad host label (\(host))" }

        let pathParts = url.path.split(separator: "/").map(String.init)
        // 最后一段是文件名本身，单独按记号判；前面的段是目录。
        if let dirToken = pathParts.dropLast().first(where: { adTokens.contains($0) }) {
            return "ad path segment (\(dirToken))"
        }
        let stemTokens = fileStem(of: lowered).split(whereSeparator: { "-_.".contains($0) }).map(String.init)
        if let token = stemTokens.first(where: { adTokens.contains($0) }) {
            return "ad token in file name (\(token))"
        }
        if let regex = try? NSRegularExpression(pattern: "^ad[-_](?:\\d|clip|video|roll|slot|banner|break)") {
            let stem = fileStem(of: lowered)
            if regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) != nil {
                return "ad clip name (\(stem))"
            }
        }
        if let token = stemTokens.first(where: { previewTokens.contains($0) }) {
            return "preview/thumbnail (\(token))"
        }
        return nil
    }

    // MARK: - 候选表

    /// 把采集到的地址补成绝对的：`//host/…` 补协议；没有协议的（`/path`、`path/x`）
    /// 按页面地址解析。补不了（没有页面地址、或解析不出带协议的地址）= 原样返回。
    static func absoluteURL(_ urlString: String, baseURL: URL?) -> String {
        let normalized = normalizedURL(urlString)
        if let url = URL(string: normalized), url.scheme != nil { return normalized }
        guard let baseURL,
              let resolved = URL(string: normalized, relativeTo: baseURL),
              let absolute = URL(string: resolved.absoluteString), absolute.scheme != nil else {
            return urlString
        }
        return absolute.absoluteString
    }

    /// 一个页面采集到的资源 → 正片候选 + 被拒清单。`extraExclusions` = 站点规则里的
    /// 排除特征（正则；v0.8.77 批 2 由适配器传入）。`baseURL` = 页面地址：采集到的
    /// 相对地址按它补全（懒加载播放器常写 `video.src = '/hls/…'`——不补的话下载时是
    /// 不支持的地址，还会和同一个视频的绝对地址各算一条）。时长证据这一步还没有——
    /// 流需要再取一次播放列表，见 `applyingDuration`。
    static func contentCandidates(_ resources: [MediaResource],
                                  extraExclusions: [String] = [],
                                  baseURL: URL? = nil) -> ContentSelection {
        var selection = ContentSelection()
        func reject(_ resource: MediaResource, _ reason: String) {
            selection.rejected.append(Rejected(url: resource.url, reason: reason))
        }

        // ⓪ 地址规范化 + 去重：同一个媒体的几种写法并成一条（保留已知的较大体积）。
        var unique: [MediaResource] = []
        var firstIndex: [String: Int] = [:]
        for resource in resources {
            let url = absoluteURL(resource.url, baseURL: baseURL)
            if let at = firstIndex[url] {
                let keptSoFar = unique[at]
                if resource.sizeBytes > keptSoFar.sizeBytes {
                    unique[at] = MediaResource(url: url, kind: keptSoFar.kind, mime: keptSoFar.mime,
                                               sizeBytes: resource.sizeBytes, source: keptSoFar.source,
                                               detectedAt: keptSoFar.detectedAt)
                }
                continue
            }
            firstIndex[url] = unique.count
            unique.append(url == resource.url ? resource : MediaResource(
                url: url, kind: resource.kind, mime: resource.mime, sizeBytes: resource.sizeBytes,
                source: resource.source, detectedAt: resource.detectedAt))
        }

        // ① 基本过滤（与 pickBestResource 同口径）+ 站点排除规则。
        var kept: [MediaResource] = []
        for resource in unique {
            if resource.isBlob {
                reject(resource, "blob: URL only works inside the page")
            } else if isDASH(urlString: resource.url, mime: resource.mime) {
                reject(resource, "DASH (.mpd) is not supported — HLS/direct files only")
            } else if resource.kind == .audio {
                reject(resource, "audio-only resource")
            } else if let pattern = extraExclusions.first(where: {
                resource.url.range(of: $0, options: .regularExpression) != nil
            }) {
                reject(resource, "site rule excludes /\(pattern)/")
            } else {
                kept.append(resource)
            }
        }

        // ② 分片归并（结构性判断）。
        let owners = segmentOwners(in: kept)
        var collapsed: [String: Int] = [:]
        var survivors: [(resource: MediaResource, junk: String?)] = []
        for resource in kept {
            if let owner = owners[resource.url] {
                collapsed[owner, default: 0] += 1
                reject(resource, owner.isEmpty
                    ? "HLS segment (numbered run, playlist not captured)"
                    : "HLS segment of \(fileStem(of: owner))")
            } else {
                survivors.append((resource, junkReason(for: resource.url)))
            }
        }
        selection.collapsedSegments = collapsed

        // ③ 杂项：按特征判，但**只有在还有别的候选时才真的排除**。
        let clean = survivors.filter { $0.junk == nil }.map(\.resource)
        var flagged = survivors.filter { $0.junk != nil }
        var familiesSource = clean
        var keptDespiteFlag: String?
        if familiesSource.isEmpty, !flagged.isEmpty {
            // 全是"疑似杂项"：留最大的那个（没有大小信息就留先出现的），绝不把页面清空。
            let fallback = flagged.max { $0.resource.sizeBytes < $1.resource.sizeBytes } ?? flagged[0]
            familiesSource = [fallback.resource]
            keptDespiteFlag = fallback.resource.url
            flagged.removeAll { $0.resource.url == fallback.resource.url }
        }
        for entry in flagged { reject(entry.resource, entry.junk ?? "junk") }

        // ④ 族聚类：变体归并、同一条视频的多种形态归并；不同视频保持分立。
        selection.candidates = distinctMediaFamilies(familiesSource).map { resource in
            var evidence = evidence(for: resource)
            if resource.url == keptDespiteFlag {
                evidence.append("kept despite junk pattern — it is the only media on the page")
            }
            return ContentCandidate(resource: resource, durationSeconds: nil, evidence: evidence)
        }
        return selection
    }

    static func evidence(for resource: MediaResource) -> [String] {
        var out: [String] = []
        let urlString = normalizedURL(resource.url)
        switch resource.kind {
        case .stream:
            // 地址里没有画质记号 ≠ 一定是 master；取到播放列表正文（有时长）才谈得上确认，
            // 那时 `applyingDuration` 会把这句换成确定的说法。
            out.append(looksLikeMaster(urlString) ? "HLS playlist (may be a master)" : "HLS playlist")
        case .video:
            out.append("video file (\(pathExtension(of: urlString)))")
        case .audio:
            out.append("audio")
        }
        if resource.sizeBytes > 0, let size = resource.displaySize { out.append(size) }
        if !resource.source.isEmpty { out.append("via \(resource.source)") }
        return out
    }

    /// 补上时长证据并做最终筛选：短于 `minContentSeconds` 的候选在有别的候选时剔除
    /// （广告/预览片段）；页面上的候选全都这么短则全部保留（短正片也成立）。
    static func applyingDuration(_ selection: ContentSelection,
                                 durations: [String: Double],
                                 minContentSeconds: Double = minContentSeconds) -> ContentSelection {
        var out = selection
        for index in out.candidates.indices {
            guard let seconds = durations[out.candidates[index].resource.url] else { continue }
            out.candidates[index].durationSeconds = seconds
            // 有 #EXTINF 之和 = 一定不是 master（master 没有分片时长）。
            out.candidates[index].evidence = out.candidates[index].evidence.map {
                $0 == "HLS playlist (may be a master)" ? "HLS playlist" : $0
            }
            out.candidates[index].evidence.append("duration \(Int(seconds.rounded()))s")
        }
        let short = out.candidates.enumerated()
            .filter { ($0.element.durationSeconds ?? .infinity) < minContentSeconds }
            .map(\.offset)
        guard !short.isEmpty, short.count < out.candidates.count else { return out }
        for index in short.reversed() {
            let candidate = out.candidates[index]
            out.rejected.append(Rejected(
                url: candidate.resource.url,
                reason: "too short (\(Int((candidate.durationSeconds ?? 0).rounded()))s) — likely an ad or preview clip"))
            out.candidates.remove(at: index)
        }
        return out
    }

    /// 播放列表总时长（秒）：`#EXTINF` 之和。不是播放列表 / 没有 `#EXTINF` = nil。
    static func playlistDuration(_ text: String) -> Double? {
        var total = 0.0
        var found = false
        for rawLine in text.components(separatedBy: .newlines) {
            guard rawLine.hasPrefix("#EXTINF:") else { continue }
            let rest = rawLine.dropFirst("#EXTINF:".count)
            let value = rest.split(separator: ",", maxSplits: 1).first?
                .split(separator: "@", maxSplits: 1).first ?? ""
            if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) {
                total += seconds
                found = true
            }
        }
        return found ? total : nil
    }

    /// 被拒清单的一行摘要（日志/回执用）："13 × HLS segment of x、1 × preview/thumbnail (preview)"。
    static func rejectionSummary(_ rejected: [Rejected], limit: Int = 4) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in rejected.map(\.reason) {
            if counts[entry] == nil { order.append(entry) }
            counts[entry, default: 0] += 1
        }
        let parts = order.prefix(limit).map { "\(counts[$0] ?? 0) × \($0)" }
        var summary = parts.joined(separator: "、")
        if order.count > limit { summary += "、…(\(order.count - limit) more kinds)" }
        return summary
    }
}
