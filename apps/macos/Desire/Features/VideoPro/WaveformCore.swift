import Foundation

/// 波形纯逻辑（v0.8.30 批次一）：采样降采样 / 片段区间切片 / 缓存键。
/// 采样（AVAssetReader PCM）在 app 侧 WaveformSampler；渲染在视图层 Canvas。
nonisolated enum WaveformCore {

    /// 一列的振幅范围（-1…1 归一化）。
    struct Column: Equatable {
        var min: Float
        var max: Float
    }

    // MARK: - 降采样

    /// 把采样列降到 targetColumns 桶（每桶取 min/max）；不足一桶的尾样并入
    /// 末桶。空输入返回空。
    static func downsample(_ samples: [Column], to targetColumns: Int) -> [Column] {
        guard targetColumns > 0, !samples.isEmpty else { return [] }
        guard targetColumns < samples.count else {
            // 放大情形：最近邻扩列（波形放大画不补细节）。
            var expanded: [Column] = []
            expanded.reserveCapacity(targetColumns)
            for index in 0..<targetColumns {
                let source = min(samples.count - 1, index * samples.count / targetColumns)
                expanded.append(samples[source])
            }
            return expanded
        }
        var buckets: [Column] = []
        buckets.reserveCapacity(targetColumns)
        let stride = Double(samples.count) / Double(targetColumns)
        for bucket in 0..<targetColumns {
            let start = Int(Double(bucket) * stride)
            let end = min(samples.count, Int(Double(bucket + 1) * stride))
            var minV = samples[start].min
            var maxV = samples[start].max
            for index in max(start, start + 1)..<max(start + 1, end) {
                minV = Swift.min(minV, samples[index].min)
                maxV = Swift.max(maxV, samples[index].max)
            }
            buckets.append(Column(min: minV, max: maxV))
        }
        return buckets
    }

    /// 从整段波形里切出片段区间（sourceStart/sourceEnd 为源内秒）再降采样
    /// 到 targetColumns——片段块只画自己用到的那段源。
    static func slice(fullWaveform: [Column], sourceDuration: Double,
                      sourceStart: Double, sourceEnd: Double,
                      targetColumns: Int) -> [Column] {
        guard sourceDuration > 0, !fullWaveform.isEmpty, sourceEnd > sourceStart else { return [] }
        let lower = min(1, max(0, sourceStart / sourceDuration))
        let upper = min(1, max(0, sourceEnd / sourceDuration))
        guard upper > lower else { return [] }
        let first = Int(Double(fullWaveform.count) * lower)
        let last = min(fullWaveform.count, Int(Double(fullWaveform.count) * upper) + 1)
        let clipped = Array(fullWaveform[first..<max(first + 1, last)])
        return downsample(clipped, to: targetColumns)
    }

    // MARK: - 缓存

    /// 缓存键（文件路径 + 修改时间 + 桶数）——文件被替换后自动失效。
    static func cacheKey(for url: URL, modifiedAt: Date, buckets: Int) -> String {
        "\(url.path)|\(Int(modifiedAt.timeIntervalSince1970))|\(buckets)"
    }
}
