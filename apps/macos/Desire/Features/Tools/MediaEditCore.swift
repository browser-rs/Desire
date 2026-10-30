import Foundation

/// 媒体剪辑纯逻辑（v0.8.27 媒体批）：时间解析/剪切计划校验/输出命名/
/// ffmpeg 参数组装/引擎选择。执行引擎（AVFoundation 导出与 ffmpeg 进程）
/// 在 MediaEditStore——本文件只放可测的纯函数（进 tests/run.sh）。
nonisolated enum MediaEditCore {

    // MARK: - 时间

    /// 解析 "m:ss.d" / "h:mm:ss" / 纯秒数（"83.5"）→ 秒；非法输入 nil。
    static func parseTime(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count <= 3, !parts.isEmpty else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// 秒 → "h:mm:ss.d"（不足一小时为 "m:ss.d"）；仅用于展示。
    static func formatTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        var tenth = Int((clamped - Double(total)) * 10)
        if tenth > 9 { tenth = 9 }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d.%d", h, m, s, tenth) }
        return String(format: "%d:%02d.%d", m, s, tenth)
    }

    /// 秒 → "h:mm:ss"（不足一小时 "m:ss"）；播放器时间轴用（无小数，四舍五入）。
    static func formatClock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - 剪切计划

    struct TrimPlan: Equatable {
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }

    /// 校验剪切区间：0 ≤ start < end ≤ duration（10ms 容差，贴端点时钳回）。
    static func trimPlan(startRaw: String, endRaw: String, duration: Double) -> TrimPlan? {
        guard let start = parseTime(startRaw), let end = parseTime(endRaw),
              duration.isFinite, duration > 0 else { return nil }
        let epsilon = 0.01
        guard start >= -epsilon, end <= duration + epsilon, end - start > epsilon else { return nil }
        let s = min(max(0, start), duration)
        let e = min(max(s + epsilon, end), duration)
        return TrimPlan(start: s, end: e)
    }

    // MARK: - 输出命名

    /// "movie.mp4" + "trimmed" → "movie.trimmed.mp4"（ext 覆盖扩展名，如
    /// 提音轨强制 m4a）；同名冲突由调用方（引擎侧）追加序号解决。
    static func derivedFileName(sourceName: String, suffix: String, ext: String? = nil) -> String {
        let base = (sourceName as NSString).deletingPathExtension
        let finalExt = ext ?? (sourceName as NSString).pathExtension
        let extPart = finalExt.isEmpty ? "" : "." + finalExt
        return "\(base).\(suffix)\(extPart)"
    }

    // MARK: - 引擎选择

    /// AVFoundation 原生顺畅处理的容器；其余（mkv/webm/flac…）直接走
    /// ffmpeg（若装了），避免"先失败再回退"的等待。
    static func isAVFoundationFriendly(ext raw: String) -> Bool {
        ["mp4", "m4v", "mov", "m4a"].contains(raw.lowercased())
    }

    static func isAudioFile(_ url: URL) -> Bool {
        ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma", "caf"]
            .contains(url.pathExtension.lowercased())
    }

    static func isVideoFile(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "ts", "mpg", "mpeg", "m2ts"]
            .contains(url.pathExtension.lowercased())
    }

    /// 剪切/拼接的输出扩展名：AVFoundation 路线 mp4/m4a；ffmpeg 路线沿用
    /// 源扩展（异形容器进出同壳最稳，重编码也不改壳）。
    static func outputExtension(source: URL, audioOnly: Bool) -> String {
        if audioOnly { return "m4a" }
        if isAVFoundationFriendly(ext: source.pathExtension) { return "mp4" }
        return source.pathExtension.lowercased().isEmpty ? "mp4" : source.pathExtension.lowercased()
    }

    // MARK: - ffmpeg 参数组装

    /// 剪切。reencode=true 逐帧精确（重编码，慢）；false 流复制（快，
    /// 起点会吸附到最近关键帧）。-ss 放 -i 前做输入端快速定位。
    static func ffmpegTrimArgs(input: String, output: String, plan: TrimPlan, reencode: Bool) -> [String] {
        var args = ["-y",
                    "-ss", String(format: "%.3f", plan.start),
                    "-i", input,
                    "-t", String(format: "%.3f", plan.duration)]
        if reencode {
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                     "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        } else {
            args += ["-c", "copy"]
        }
        args.append(output)
        return args
    }

    /// concat demuxer 的清单文件内容（单引号路径转义）。
    static func buildConcatList(_ inputs: [String]) -> String {
        inputs
            .map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n")
    }

    /// 拼接（流复制）：要求全部输入同编码同参数，速度最快。
    static func ffmpegConcatCopyArgs(listFile: String, output: String) -> [String] {
        ["-y", "-f", "concat", "-safe", "0", "-i", listFile, "-c", "copy", output]
    }

    /// 拼接（filter_complex 重编码）：混合编码/分辨率也安全。hasAudio=false
    /// 表示任一输入没有音轨——这时按纯视频拼（[i:a] 解析不到会让整条滤镜失败）。
    static func ffmpegConcatFilterArgs(inputs: [String], output: String, hasAudio: Bool) -> [String] {
        var args: [String] = ["-y"]
        for input in inputs { args += ["-i", input] }
        let n = inputs.count
        let streams = (0..<n).map { index -> String in
            hasAudio ? "[\(index):v][\(index):a]" : "[\(index):v]"
        }.joined()
        let tail = hasAudio
            ? "concat=n=\(n):v=1:a=1[v][a]"
            : "concat=n=\(n):v=1:a=0[v]"
        args += ["-filter_complex", streams + tail, "-map", "[v]"]
        if hasAudio { args += ["-map", "[a]", "-c:a", "aac", "-b:a", "160k"] }
        args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                 "-movflags", "+faststart", output]
        return args
    }

    /// 音频剪切 → 重编码 aac（-vn 顺手剥掉可能存在的封面视频流）。
    static func ffmpegTrimAudioArgs(input: String, output: String, plan: TrimPlan) -> [String] {
        ["-y",
         "-ss", String(format: "%.3f", plan.start),
         "-i", input,
         "-t", String(format: "%.3f", plan.duration),
         "-vn", "-c:a", "aac", "-b:a", "160k", output]
    }

    /// 音频拼接（concat demuxer 重编码 aac：异编码音频也能进同一清单）。
    static func ffmpegConcatAudioArgs(listFile: String, output: String) -> [String] {
        ["-y", "-f", "concat", "-safe", "0", "-i", listFile, "-c:a", "aac", "-b:a", "160k", output]
    }

    /// 提取音轨 → m4a（统一重编码 aac：源是 mp3/opus 或容器不支持直拷也能出）。
    static func ffmpegExtractAudioArgs(input: String, output: String) -> [String] {
        ["-y", "-i", input, "-vn", "-c:a", "aac", "-b:a", "160k", output]
    }

    /// 追加进度输出（执行器统一加，核心参数保持纯净便于断言）。
    static func appendingProgressArgs(_ args: [String]) -> [String] {
        var result = args
        result.insert("-nostats", at: result.count - 1)
        result.insert("-progress", at: result.count - 1)
        return result
    }
}
