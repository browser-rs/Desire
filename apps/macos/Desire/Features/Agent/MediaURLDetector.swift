import Foundation

/// 下载智能建议（v0.8.6）的纯检测逻辑：输入文本里的媒体/文件 URL 识别与
/// 单个/批量建议决策。Foundation-only，进 tests/run.sh。
nonisolated enum MediaURLDetector {

    /// 建议形态。
    enum Suggestion: Equatable {
        /// 单个媒体/文件 URL。
        case single(url: String, host: String, kind: Kind)
        /// ≥2 个 URL：批量引擎建议。
        case batch(urls: [String], hosts: [String])
    }

    enum Kind: String, Equatable {
        case video, audio, document, archive, playlist, file

        var label: String {
            switch self {
            case .video: "视频"
            case .audio: "音频"
            case .document: "文档"
            case .archive: "压缩包"
            case .playlist: "播放列表"
            case .file: "文件"
            }
        }
    }

    /// 扩展名 → 类型。HLS/extension_picky 形态（无扩展、查询串）也算
    /// playlist/file——直接下载 .m3u8 没意义，但提示"交给引擎"成立。
    static let knownExtensions: [String: Kind] = {
        var map: [String: Kind] = [
            "mp4": .video, "mkv": .video, "mov": .video, "avi": .video, "webm": .video, "flv": .video, "ts": .video,
            "m3u8": .playlist, "mpd": .playlist,
            "mp3": .audio, "m4a": .audio, "flac": .audio, "wav": .audio, "aac": .audio, "opus": .audio,
            "pdf": .document, "doc": .document, "docx": .document, "epub": .document,
            "zip": .archive, "rar": .archive, "7z": .archive, "tar": .archive, "gz": .archive, "dmg": .archive,
        ]
        return map
    }()

    /// 从一段文本里抽出全部 http(s) URL（朴素空白/换行切分——输入框场景
    /// 够用，不做全文正则扫）。
    static func urls(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .compactMap { token -> String? in
                let s = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "(),.;"))
                guard s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://"),
                      URL(string: s)?.host != nil else { return nil }
                return s
            }
    }

    /// URL 的建议类型（扩展名匹配，去掉查询串后判定）。
    static func kind(of url: String) -> Kind? {
        guard let comps = URLComponents(string: url) else { return nil }
        let path = (comps.path as NSString).pathExtension.lowercased()
        if let kind = knownExtensions[path] { return kind }
        // 无扩展但路径含 m3u8/manifest 的流地址（常见 CDN 形态）。
        let lowered = (comps.path + "?" + (comps.query ?? "")).lowercased()
        if lowered.contains(".m3u8") || lowered.contains("m3u8") || lowered.contains("manifest") || lowered.contains(".mpd") {
            return .playlist
        }
        return nil
    }

    /// 文本 → 建议。规则：全部 URL 都可识别为媒体/文件才建议（混着普通
    /// 网页链接不打扰）；≥2 个 → batch。`disabledHosts` 里的站点静默跳过
    /// （任一命中即不建 single；batch 只过滤后计数）。
    static func suggest(for text: String, disabledHosts: Set<String> = []) -> Suggestion? {
        let found = urls(in: text)
        guard !found.isEmpty else { return nil }
        var media: [(url: String, host: String, kind: Kind)] = []
        for url in found {
            guard let kind = kind(of: url),
                  let host = URL(string: url)?.host else { continue }
            media.append((url, host, kind))
        }
        guard !media.isEmpty else { return nil }
        let active = media.filter { !disabledHosts.contains($0.host) }
        guard !active.isEmpty else { return nil }
        if active.count >= 2 {
            return .batch(urls: active.map(\.url), hosts: Array(Set(active.map(\.host))).sorted())
        }
        return .single(url: active[0].url, host: active[0].host, kind: active[0].kind)
    }
}
