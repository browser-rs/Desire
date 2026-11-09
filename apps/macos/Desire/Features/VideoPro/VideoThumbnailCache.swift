import AVFoundation
import CoreGraphics
import Foundation

/// 视频缩略图缓存（视频轨 lane 的画面预览）。按素材 URL 缓存一组等距帧；
/// 同一素材的并发请求共享一个生成任务（预览重建/多片段引用同一素材时
/// 不会重复抽帧）。
@MainActor
final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()

    private var images: [String: [CGImage]] = [:]
    private var tasks: [String: Task<[CGImage], Never>] = [:]
    private let frameCount = 12

    /// 已有缓存（未命中返回 nil，调用方可先画占位）。
    func cached(for url: URL) -> [CGImage]? {
        images[url.path]
    }

    func thumbnails(for url: URL) async -> [CGImage] {
        let key = url.path
        if let hit = images[key] { return hit }
        if let running = tasks[key] { return await running.value }
        let task = Task<[CGImage], Never> {
            await Self.generate(url: url, count: frameCount)
        }
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        if !result.isEmpty { images[key] = result }
        return result
    }

    private nonisolated static func generate(url: URL, count: Int) async -> [CGImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0.05 else {
            return []
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        var out: [CGImage] = []
        for index in 0..<count {
            let seconds = duration * (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                out.append(image)
            }
        }
        return out
    }
}
