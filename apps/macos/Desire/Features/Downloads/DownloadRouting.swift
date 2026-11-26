import Foundation

/// **下载方式的研判**（v0.8.77 批 6，Foundation-only 进 tests/run.sh）。
///
/// 背景（2026-11-25 真实使用）：智能体用 `downloadMedia` 下 HLS，当时的引擎是 ffmpeg 直连
/// ——单进程串行读远端播放列表，2 小时的片要几个小时；它据此判断"内置的慢"，转而自己写
/// 并发脚本。并发预取加进来之后，"走哪条路"却仍然只看"机器上有没有 ffmpeg"，不看流的
/// 形态：音轨分离的流只抓了视频变体（丢声音）、没装 ffmpeg 的机器根本不并发、码率上限在
/// 并发路径上不生效。
///
/// 所以先把**事实**读出来（`HLSSourceProfile.read`），再按规则选引擎
/// （`DownloadRouting.decide`），每条规则留一条依据——批次日志与工具回执里能看到
/// "为什么是这条路"，智能体不必再靠猜和试。
nonisolated struct HLSSourceProfile: Equatable {
    enum Encryption: Equatable {
        case none, aes128, sampleAES, other(String)
    }

    /// master 里的一个变体。`index` 是文件顺序下标（= ffmpeg 的 program 号）。
    struct Variant: Equatable {
        var index: Int
        var bandwidth: Int
        var resolution: String
        var url: URL
    }

    var isMaster = false
    /// 按码率从高到低。
    var variants: [Variant] = []
    var isLive = false
    var encryption: Encryption = .none
    /// master 里有带地址的独立音轨 / 视频轨（`#EXT-X-MEDIA:TYPE=AUDIO|VIDEO…URI=`）：
    /// 只抓一个变体会丢轨——master 必须整体交给 ffmpeg。
    var hasSeparateRenditions = false
    var hasByteRanges = false
    var hasInitSegment = false
    var segmentCount = 0
    var durationSeconds: Double?
    /// 媒体播放列表内置解析器读不了（形态或加密不认）。
    var parseFailure: String?

    /// 从两段播放列表文本读事实。`masterText` / `masterURL` = 入口地址是 master 时的原文与
    /// 地址（变体的相对地址按它解析）；`mediaText` = 最终选中的媒体播放列表原文；
    /// `mediaURL` = 它的地址（分片的相对地址按它解析）。
    static func read(masterText: String? = nil, masterURL: URL? = nil,
                     mediaText: String?, mediaURL: URL) -> HLSSourceProfile {
        var profile = HLSSourceProfile()
        if let master = masterText, master.contains("#EXT-X-STREAM-INF") {
            profile.isMaster = true
            if let masterURL {
                profile.variants = variants(in: master, baseURL: masterURL)
            }
            profile.hasSeparateRenditions = master.components(separatedBy: .newlines).contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#EXT-X-MEDIA:"), trimmed.contains("URI=") else { return false }
                return trimmed.contains("TYPE=AUDIO") || trimmed.contains("TYPE=VIDEO")
            }
        }
        guard let text = mediaText else {
            if !isPlaylist(masterText) { profile.parseFailure = "not a playlist" }
            return profile
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#EXT-X-KEY:"),
                  let method = attribute("METHOD", in: trimmed), method != "NONE" else { continue }
            switch method {
            case "AES-128": profile.encryption = .aes128
            case "SAMPLE-AES", "SAMPLE-AES-CTR": profile.encryption = .sampleAES
            default: profile.encryption = .other(method)
            }
        }
        do {
            let playlist = try HLSMediaPlaylist.parse(text, baseURL: mediaURL)
            profile.isLive = !playlist.hasEndList
            profile.hasByteRanges = playlist.hasByteRanges
            profile.hasInitSegment = playlist.initSegmentURL != nil
            profile.segmentCount = playlist.segments.count
            profile.durationSeconds = playlist.duration
        } catch HLSMediaPlaylist.ParseError.notAMediaPlaylist {
            profile.parseFailure = isPlaylist(text) ? "not a media playlist" : "not a playlist"
        } catch HLSMediaPlaylist.ParseError.unsupportedEncryption(let method) {
            profile.parseFailure = "\(method) encryption"
        } catch {
            profile.parseFailure = "unreadable playlist"
        }
        return profile
    }

    private static func isPlaylist(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    /// master 文本 → 变体（码率从高到低；同码率保持文件顺序）。与 ffmpeg 直连路径挑的是同一档。
    static func variants(in masterText: String, baseURL: URL) -> [Variant] {
        var out: [Variant] = []
        var pendingBandwidth = 0
        var pendingResolution = ""
        for line in masterText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = Int(attribute("BANDWIDTH", in: trimmed) ?? "") ?? 0
                pendingResolution = attribute("RESOLUTION", in: trimmed) ?? ""
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                // BANDWIDTH 缺失但写了 RESOLUTION 的 master 也收（与既有路径同口径）。
                if let url = URL(string: trimmed, relativeTo: baseURL),
                   pendingBandwidth > 0 || !pendingResolution.isEmpty {
                    out.append(Variant(index: out.count, bandwidth: pendingBandwidth,
                                       resolution: pendingResolution, url: url))
                }
                pendingBandwidth = 0
                pendingResolution = ""
            }
        }
        return out.enumerated().sorted { lhs, rhs in
            lhs.element.bandwidth != rhs.element.bandwidth
                ? lhs.element.bandwidth > rhs.element.bandwidth
                : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 码率上限之内选最高档；全都超了就取最低档（与 `selectVariantEntry` 同语义）。
    static func choose(from variants: [Variant], maxBandwidth: Int?) -> Variant? {
        guard let cap = maxBandwidth, cap > 0 else { return variants.first }
        return variants.first { $0.bandwidth <= cap } ?? variants.last
    }

    var variantSummary: String? {
        guard !variants.isEmpty else { return nil }
        let best = variants[0]
        let top = best.resolution.isEmpty ? "\(best.bandwidth / 1000)kbps" : best.resolution
        return "\(variants.count) variant\(variants.count == 1 ? "" : "s"), best \(top)"
    }

    /// 时长的人读形式："2h 1m" / "12s"。
    var durationLabel: String? {
        guard let seconds = durationSeconds else { return nil }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=") else { return nil }
        var rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            if let end = rest.firstIndex(of: "\"") { rest = rest[..<end] }
        } else if let comma = rest.firstIndex(of: ",") {
            rest = rest[..<comma]
        }
        let value = String(rest).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

nonisolated enum DownloadRouting {

    /// 下载方式的**显式**偏好：智能体按实际情况指定，或由站点规则（DPP 适配器的 `download.engine`）
    /// 规定。`.auto` = 按流的事实研判出最优的一种。
    enum EnginePreference: String, Equatable, CaseIterable {
        case auto, parallel, ffmpeg, builtin

        static func parse(_ raw: String?) -> EnginePreference? {
            let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !value.isEmpty else { return nil }
            return EnginePreference(rawValue: value)
        }
    }

    enum Remux: Equatable {
        /// 本地 ffmpeg 读本地播放列表：解密 + 转封装成 MP4。
        case ffmpeg
        /// 内置下载器解密拼接（产出 .ts；有 ffmpeg 时随后转封装）。
        case builtin
    }

    enum Engine: Equatable {
        /// 直链文件：流式落盘 + 断点续传。
        case directFile
        /// HLS：分片并发预取到本地，再本地合成。
        case parallelPrefetch(remux: Remux)
        /// ffmpeg 直连远端播放列表（单进程串行）：能力最全，留给并发路径处理不了的形态。
        case ffmpegDirect
        /// 内置串行（并发预取之前的旧路径）。
        case builtinSerial
        case unsupported(String)
    }

    struct Decision: Equatable {
        var engine: Engine
        /// 事实：流是什么形态、本机有什么。
        var facts: [String]
        /// 选这条路的规则（只有一条）。
        var rule: String
        /// 引擎的一句话（含连接数）。
        var summary: String
        /// 日志用的一行：事实 → 引擎。
        var line: String { facts.joined(separator: " · ") + " → " + summary }
    }

    /// 直链文件（不是播放列表）：流式落盘；服务器支持 Range 才谈得上断点续传。
    static func directFile(ffmpegLabel: String?, contentType: String?, resumable: Bool) -> Decision {
        Decision(engine: .directFile,
                 facts: ["direct file" + (contentType.map { " (\($0))" } ?? ""),
                         resumable ? "range requests supported" : "no range support"]
                     + [ffmpegLabel != nil ? "ffmpeg" + (ffmpegLabel!.isEmpty ? "" : " " + ffmpegLabel!) : "no ffmpeg"],
                 rule: "a plain file — streamed to disk"
                     + (resumable ? ", resumed with range requests after an interruption" : ""),
                 summary: "direct file download")
    }

    /// 一条命令看起来像"自己在下载 HLS"：把 `.m3u8` 地址交给了 ffmpeg / 下载器 / 脚本解释器。
    /// `runCommand` 据此在结果后面附一句提示——**不拦**，只提醒内置下载已经能做这件事
    /// （2026-11-25 的真实使用里，智能体正是因为不知道才自己写了并发下载脚本）。
    static func looksLikeHandWrittenDownload(tool: String, arguments: [String]) -> Bool {
        // 只认带 http 的流地址：本地转封装（`ffmpeg -i local.m3u8`）不算。
        let handsOverAStream = arguments.contains { $0.lowercased().contains("http") && $0.contains(".m3u8") }
        guard handsOverAStream else { return false }
        let name = (tool as NSString).lastPathComponent.lowercased()
        return ["ffmpeg", "yt-dlp", "youtube-dl", "you-get", "streamlink", "curl", "wget", "aria2c",
                "python", "python3", "node", "bun", "ruby", "perl", "sh", "bash", "zsh"].contains(name)
    }

    /// - `ffmpegLabel`: nil = 本机没有 ffmpeg；非 nil = 有（值是一句简短说明）。
    /// - `connections`: 并发预取打算用的连接数（写进结论）。
    static func decide(_ profile: HLSSourceProfile, ffmpegLabel: String?,
                       connections: Int? = nil,
                       preference: EnginePreference = .auto) -> Decision {
        var facts: [String] = []
        if profile.isMaster {
            facts.append("master playlist" + (profile.variantSummary.map { " (\($0))" } ?? ""))
        }
        // 加密方式来自 `#EXT-X-KEY` 行——内置解析器读不了播放列表时它也已经读到了。
        switch profile.encryption {
        case .none: break
        case .aes128: facts.append("AES-128")
        case .sampleAES: facts.append("SAMPLE-AES")
        case .other(let method): facts.append(method)
        }
        let hasFFmpeg = ffmpegLabel != nil
        let ffmpegFact = hasFFmpeg
            ? "ffmpeg" + (ffmpegLabel!.isEmpty ? "" : " " + ffmpegLabel!)
            : "no ffmpeg"
        func make(_ engine: Engine, _ rule: String) -> Decision {
            let summary: String
            switch engine {
            case .parallelPrefetch(let remux):
                summary = "parallel segment prefetch"
                    + (connections.map { " (\($0) connection\($0 == 1 ? "" : "s"))" } ?? "")
                    + (remux == .ffmpeg ? " + local ffmpeg decrypt/remux" : " + built-in decrypt/concat")
            case .ffmpegDirect: summary = "ffmpeg direct (serial)"
            case .builtinSerial: summary = "built-in serial downloader"
            case .directFile: summary = "direct file download"
            case .unsupported: summary = "unsupported"
            }
            return Decision(engine: engine, facts: facts + [ffmpegFact], rule: rule, summary: summary)
        }

        // **显式选择优先**（2026-11-26 用户定调）：方式由智能体结合实际情况 / 站点规则决定，
        // 定下来就只走那一种——失败如实上报，不偷偷换引擎重下。
        switch preference {
        case .ffmpeg:
            return hasFFmpeg
                ? make(.ffmpegDirect, "requested explicitly (agent or site rule) — ffmpeg reads the playlist serially")
                : make(.unsupported("ffmpeg was requested but is not installed"),
                       "requested ffmpeg, which is not installed")
        case .builtin:
            guard profile.parseFailure == nil else {
                return make(.builtinSerial, "requested the built-in downloader (the built-in parser cannot read this playlist, so the legacy serial path)")
            }
            let rule = "requested the built-in downloader (agent or site rule) — segments in parallel, decrypted locally"
            return profile.encryption == .sampleAES || profile.hasByteRanges || profile.isLive
                ? make(.builtinSerial, rule + "; this shape keeps it serial")
                : make(.parallelPrefetch(remux: .builtin), rule)
        case .parallel:
            guard profile.parseFailure == nil else {
                return make(.unsupported("the parallel path cannot read this playlist"), "requested the parallel path, but the built-in parser cannot read this playlist")
            }
            if profile.hasSeparateRenditions {
                facts.append("forced parallel: separate audio will be missing")
            }
            return make(.parallelPrefetch(remux: hasFFmpeg ? .ffmpeg : .builtin),
                        "requested the parallel path (agent or site rule)")
        case .auto:
            break
        }
        switch profile.encryption {
        case .sampleAES, .other:
            return hasFFmpeg
                ? make(.ffmpegDirect, "this encryption is not handled by the built-in path")
                : make(.unsupported("encryption not supported without ffmpeg"),
                       "this encryption needs ffmpeg, which is not installed")
        case .none, .aes128:
            break
        }
        if let failure = profile.parseFailure {
            facts.append("built-in parser cannot read the playlist (\(failure))")
            return hasFFmpeg
                ? make(.ffmpegDirect, "leave the whole playlist to ffmpeg")
                : make(.builtinSerial, "no ffmpeg installed → legacy serial downloader")
        }
        facts.append(profile.isLive ? "HLS live" : "HLS VOD")
        if profile.hasSeparateRenditions { facts.append("separate audio/video renditions") }
        if profile.hasByteRanges { facts.append("byte-range segments") }
        if profile.hasInitSegment { facts.append("fMP4 segments") }
        if profile.segmentCount > 0 {
            facts.append("\(profile.segmentCount) segment\(profile.segmentCount == 1 ? "" : "s")"
                + (profile.durationLabel.map { " ≈ \($0)" } ?? ""))
        }
        if profile.hasSeparateRenditions {
            return hasFFmpeg
                ? make(.ffmpegDirect, "prefetching a single variant would drop the separate renditions")
                : make(.parallelPrefetch(remux: .builtin),
                       "no ffmpeg: only the video variant can be fetched — the separate audio will be missing")
        }
        if profile.hasByteRanges {
            // 内置下载器不认 `#EXT-X-BYTERANGE`：它会把同一文件当成分片重复拼接。没有 ffmpeg
            // 就诚实报"做不了"，不产出坏文件（0.8.79 形态矩阵核实）。
            return hasFFmpeg
                ? make(.ffmpegDirect, "byte-range segments are not standalone files")
                : make(.unsupported("byte-range streams need ffmpeg"),
                       "byte-range segments need ffmpeg, which is not installed")
        }
        if profile.isLive {
            return make(.parallelPrefetch(remux: .builtin),
                        "live stream: only the segments available now are exported")
        }
        return make(.parallelPrefetch(remux: hasFFmpeg ? .ffmpeg : .builtin),
                    "plain VOD: segments are independent files — fetch in parallel, finish locally")
    }
}

/// **给智能体看的探测回执**（v0.8.77 批 6）：`probeDownload` 工具的输出。把研判的事实、规则、
/// 引擎，加上开头分片的实测速度与预计耗时，写成一段模型读得懂的英文——它此前靠手写
/// 测速脚本才能得到这些。
nonisolated struct DownloadProbeReport: Equatable {
    struct DirectFileFacts: Equatable {
        var contentType: String?
        var bytes: Int64?
        var acceptsRanges: Bool
    }

    var decision: DownloadRouting.Decision
    var speed: ParallelTuning.Evidence?
    /// 按测到的分片平均大小估的总字节。
    var estimatedBytes: Int64?
    var directFile: DirectFileFacts?
    /// 媒体播放列表的分片数（没有测速时据此说明「没量」）。
    var segments: Int = 0
    /// 读不了源的时候的原因（有它就只有这一句）。
    var failure: String?

    init(decision: DownloadRouting.Decision, speed: ParallelTuning.Evidence? = nil,
         estimatedBytes: Int64? = nil, directFile: DirectFileFacts? = nil, segments: Int = 0, failure: String? = nil) {
        self.decision = decision
        self.speed = speed
        self.estimatedBytes = estimatedBytes
        self.directFile = directFile
        self.segments = segments
        self.failure = failure
    }

    static func failed(_ reason: String) -> DownloadProbeReport {
        DownloadProbeReport(decision: DownloadRouting.Decision(engine: .directFile, facts: [], rule: "", summary: ""),
                            failure: reason)
    }

    var text: String {
        if decision.facts.isEmpty, let failure {
            return "Download assessment\n- could not read the source: \(failure)\n— it may need the page's cookies or a browser context; resolve the page with resolveVideos instead."
        }
        var lines = ["Download assessment"]
        for fact in decision.facts { lines.append("- " + fact) }
        if let file = directFile {
            if let type = file.contentType { lines.append("- type: \(type)") }
            if let bytes = file.bytes { lines.append("- size: \(Self.sizeLabel(bytes))") }
            lines.append(file.acceptsRanges
                         ? "- range requests supported → resumable"
                         : "- no range support → a broken download restarts from zero")
        }
        if case .unsupported(let reason) = decision.engine {
            lines.append("→ cannot download: \(reason)")
            return lines.joined(separator: "\n")
        }
        lines.append("→ method: " + decision.summary)
        if !decision.rule.isEmpty { lines.append("  because: " + decision.rule) }
        if case .ffmpegDirect = decision.engine {
            lines.append("  note: this shape has to be read by ffmpeg from the remote playlist, one connection — slow on long videos")
        }
        if let speed {
            lines.append("- speed: " + speed.summary)
            lines.append(speed.gain >= ParallelTuning.meaningfulGain
                         ? "  → the source throttles each connection; parallel scales — more connections help"
                         : "  → parallel gives little gain here — more connections will not help")
            if let estimatedBytes, speed.parallelBytesPerSecond > 0 {
                let seconds = Double(estimatedBytes) / speed.parallelBytesPerSecond
                lines.append("- estimate: ≈ \(Self.sizeLabel(estimatedBytes)), ≈ \(Self.timeLabel(seconds)) at \(speed.connectionsTested) connection\(speed.connectionsTested == 1 ? "" : "s") (from the first \(speed.connectionsTested + 1) segments)")
            }
        } else if case .parallelPrefetch = decision.engine, segments > 0 {
            lines.append("- speed: not measured" + (failure.map { " (\($0))" } ?? " (the first segment did not load)"))
        }
        lines.append("Next: pass this stream to downloadMedia"
                     + (speed.map { " (connections: \($0.connectionsTested))" } ?? "")
                     + ", or detail pages to downloadVideoList. The built-in download fetches HLS segments in parallel and, in batches, re-resolves expired addresses and resumes — do NOT write a downloader script. If it is still too slow, raise `connections` (1–32; it only helps while parallel scales) or `maxConcurrent` for a batch.")
        return lines.joined(separator: "\n")
    }

    static func sizeLabel(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 90 { return "\(total)s" }
        if total < 5_400 { return "\(total / 60) min" }
        return String(format: "%.1f h", Double(total) / 3_600)
    }
}
