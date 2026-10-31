import AVFoundation
import Combine
import Foundation

/// 波形采样与缓存（v0.8.30 批次一）：AVAssetReader 流式读 PCM，边读边聚合
/// 成 400 桶 min/max（不落全量采样，长文件也稳）；按 WaveformCore.cacheKey
/// 缓存，同一文件多片段共享。
@MainActor
final class WaveformCache: ObservableObject {
    static let shared = WaveformCache()
    static let bucketCount = 400

    private var cache: [String: [WaveformCore.Column]] = [:]
    private var inflight: [String: Task<[WaveformCore.Column]?, Never>] = [:]

    /// 取波形（缓存命中即返；未命中现场采样）。失败返回 nil（视图退回色块）。
    func waveform(for url: URL) async -> [WaveformCore.Column]? {
        var modified = Date.distantPast
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            modified = date
        }
        let key = WaveformCore.cacheKey(for: url, modifiedAt: modified,
                                        buckets: Self.bucketCount)
        if let cached = cache[key] { return cached }
        if let running = inflight[key] {
            return await running.value
        }
        let task = Task {
            await WaveformSampler.sample(url: url, buckets: WaveformCache.bucketCount)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        if let result {
            cache[key] = result
            if cache.count > 60 {
                // 粗略淘汰：键序最早的 20 条（键含路径无时序，直接留容量即可）。
                for extra in cache.keys.prefix(20) where cache.count > 50 {
                    cache.removeValue(forKey: extra)
                }
            }
        }
        return result
    }
}

/// AVAssetReader PCM 采样（nonisolated：后台 Task 跑）。
nonisolated enum WaveformSampler {

    /// 读第一条音轨，流式聚合为 buckets 桶 min/max；无音轨/读失败返回 nil。
    static func sample(url: URL, buckets: Int) async -> [WaveformCore.Column]? {
        guard buckets > 0 else { return nil }
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }

        var mins = [Float](repeating: .greatestFiniteMagnitude, count: buckets)
        var maxs = [Float](repeating: -.greatestFiniteMagnitude, count: buckets)
        var sawAny = false
        // 总帧数未知（流式），先按"均匀灌桶"假设：读完一个 buffer 就把它的样本
        // 均摊到当前进度估算的桶区间。用 duration 估算进度。
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var samplesSeen = 0
        let estimatedTotalSamples = duration * 44_100 // 常见采样率估; 只用于分桶进度

        while let next = output.copyNextSampleBuffer() {
            guard CMSampleBufferDataIsReady(next),
                  let block = CMSampleBufferGetDataBuffer(next) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var int16 = [Int16](repeating: 0, count: length / 2)
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                                    dataLength: int16.count * 2,
                                                    destination: &int16)
            guard status == kCMBlockBufferNoErr else { continue }
            let frames = int16.count
            let base = samplesSeen
            samplesSeen += frames
            let total = max(1, estimatedTotalSamples)
            for (offset, raw) in int16.enumerated() where offset % 8 == 0 {
                // 每 8 帧抽 1（≈11k 点/s 聚合足够）；值归一化。
                let value = Float(raw) / Float(Int16.max)
                let global = base + offset
                let bucket = min(buckets - 1, Int(Double(global) / Double(total) * Double(buckets)))
                if value < mins[bucket] { mins[bucket] = value }
                if value > maxs[bucket] { maxs[bucket] = value }
                sawAny = true
            }
        }
        guard sawAny else { return nil }
        var columns: [WaveformCore.Column] = []
        columns.reserveCapacity(buckets)
        for index in 0..<buckets {
            let minV = mins[index] == .greatestFiniteMagnitude ? 0 : mins[index]
            let maxV = maxs[index] == -.greatestFiniteMagnitude ? 0 : maxs[index]
            columns.append(WaveformCore.Column(min: minV, max: maxV))
        }
        return columns
    }
}
