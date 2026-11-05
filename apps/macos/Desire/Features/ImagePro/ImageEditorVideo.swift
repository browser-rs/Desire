import AppKit
import CoreGraphics
import Foundation

/// 视频抓帧（迭代 10）：用系统里的 ffmpeg 抽一帧 → CGImage（供置入画布/做封面）。
nonisolated enum ImageEditorVideo {

    static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                          "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 抽取指定秒数的一帧（失败返回 nil 与原因）。
    static func extractFrame(from videoPath: String, time: Double) -> (image: CGImage?, error: String?) {
        guard let ffmpeg = ffmpegPath() else {
            return (nil, "ffmpeg not found (install with: brew install ffmpeg)")
        }
        let expanded = (videoPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return (nil, "video not found: \(videoPath)")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-ss", String(max(0, time)),
            "-i", expanded,
            "-frames:v", "1",
            "-y", out.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (nil, "ffmpeg failed: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: out) }
        guard process.terminationStatus == 0,
              let image = ImageTransforms.load(from: out) else {
            return (nil, "no frame at \(String(format: "%.2f", time))s")
        }
        return (image, nil)
    }
}
