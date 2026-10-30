import Foundation

/// 外挂字幕解析（v0.8.27 播放器批）：SRT / WebVTT / ASS·SSA 三格式，
/// 纯 Foundation、进 tests/run.sh。渲染在视图层（MediaViewerView 浮层），
/// 时间轴对齐由 MediaPlayerModel 的周期观察者驱动。
///
/// 口径：
/// - 统一秒（Double）；解析容忍 CRLF、缺序号行、行内标签（<i>、{\i1}）。
/// - ASS 取 Dialogue 的第 10 个字段（前 9 个按逗号切，文本里的逗号安全），
///   {\...} 覆写标签剥掉、\N 换行。
/// - 候选字幕：与视频同名的 srt/vtt/ass/ssa 优先，其次"视频名+任意后缀"
///   （movie.zh.srt 式），同名不同格式按 srt > ass > vtt 排序。
nonisolated enum SubtitleCore {

    struct Cue: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    // MARK: - 入口

    /// 按内容嗅探格式解析（不信任扩展名）；识别不了返回 nil。
    static func parse(_ data: Data) -> [Cue]? {
        guard var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("WEBVTT") { return parseVTT(text) }
        if trimmed.hasPrefix("[Script Info]") || trimmed.contains("[V4+ Styles]") {
            return parseASS(text)
        }
        let cues = parseSRT(text)
        // SRT 解析至少要真的吃到时间轴，否则就是识别不了。
        return cues.isEmpty ? nil : cues
    }

    // MARK: - SRT

    static func parseSRT(_ text: String) -> [Cue] {
        parseBlockFormat(text)
    }

    // MARK: - WebVTT

    static func parseVTT(_ text: String) -> [Cue] {
        parseBlockFormat(text)
    }

    /// SRT 与 VTT 同构：空行分块，块内"可选 id 行 + 时间行 + 文本行"。
    private static func parseBlockFormat(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard !lines.isEmpty else { continue }
            // 时间行可能带箭头两侧的设置项（VTT position/align），只取 --> 前后首段。
            guard let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeLine = lines[arrowIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces)
                      .components(separatedBy: " ").first ?? ""),
                  end > start else { continue }
            lines.removeSubrange(...arrowIndex)
            let body = lines
                .joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:00:01,000" / "01:02.500" / "0:00:01.00"（ASS）→ 秒。
    static func parseTimestamp(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let units = text.components(separatedBy: ":")
        guard (2...3).contains(units.count) else { return nil }
        var seconds = 0.0
        for unit in units {
            let normalized = unit.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized), value >= 0 else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    // MARK: - ASS / SSA

    static func parseASS(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for line in text.split(separator: "\n") {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Dialogue:") else { continue }
            let fields = line.dropFirst("Dialogue:".count)
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: ",").map { String($0) }
            // Dialogue: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            guard fields.count > 9,
                  let start = parseTimestamp(fields[1]),
                  let end = parseTimestamp(fields[2]),
                  end > start else { continue }
            let body = fields[9...].joined(separator: ",")
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - 查询与候选

    /// 命中该时刻的台词（多条叠加换行，少数字幕组会这么排）；cues 须已排序。
    static func texts(at seconds: Double, in cues: [Cue]) -> String {
        let hits = cues.filter { seconds >= $0.start && seconds < $0.end }
        return hits.map { $0.text }.joined(separator: "\n")
    }

    static let subtitleExtensions = ["srt", "ass", "ssa", "vtt"]

    /// 候选字幕文件名（目录内容作输入，纯函数可测）：
    /// 精确同名最优先，其次"视频名+任意后缀"；同级按 srt > ass > ssa > vtt。
    static func candidateSubtitleFiles(forVideoName videoName: String,
                                       directoryContents: [String]) -> [String] {
        let base = (videoName as NSString).deletingPathExtension
        func rank(_ name: String) -> Int? {
            let ext = (name as NSString).pathExtension.lowercased()
            guard subtitleExtensions.contains(ext), !name.hasPrefix(".") else { return nil }
            let stem = (name as NSString).deletingPathExtension
            if stem == base { return 0 }
            if stem.hasPrefix(base + ".") { return 1 }
            return nil
        }
        return directoryContents
            .compactMap { name -> (String, Int)? in
                rank(name).map { (name, $0) }
            }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            .map { $0.0 }
    }
}
