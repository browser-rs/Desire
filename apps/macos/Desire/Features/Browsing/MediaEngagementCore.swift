import Foundation

/// 媒体参与度纯逻辑（v0.8.32 重写，Chrome MEI 模型）——评分/阈值/预置种子，
/// 进 tests/run.sh。持久化在 MediaEngagementStore。
nonisolated enum MediaEngagementCore {

    struct Record: Codable, Equatable {
        /// ≥7 秒的有声播放次数。
        var playCount: Int
        /// 累计有声播放秒数。
        var playSeconds: Double
    }

    /// 高参与阈值：score = min(1, seconds/3600)，≥0.5（≈30 分钟）即高参与
    /// （Chrome 实测阈值近似）。
    static let scoreThresholdSeconds: Double = 1800
    /// Chrome 口径：单次播放 ≥7 秒才计入参与度。
    static let minPlaySeconds: Double = 7

    /// 头部视频站预置种子（对齐 Chromium MEI pre-seeding：YouTube 等对
    /// 几乎所有用户都是高参与）。预置 = 视为已达阈值。
    static let preSeededHosts: [String] = [
        "youtube.com", "youtube-nocookie.com", "youtu.be",
        "bilibili.com", "b23.tv",
        "vimeo.com", "dailymotion.com",
        "twitch.tv",
        "music.163.com", "y.qq.com", "kugou.com", "kuwo.cn", "xiami.com",
        "iqiyi.com", "iq.com", "youku.com", "mgtv.com",
        "douyin.com", "tiktok.com",
    ]

    static func score(for record: Record?) -> Double {
        guard let record else { return 0 }
        return min(1, record.playSeconds / 3600)
    }

    static func isHighEngagement(host: String, record: Record?) -> Bool {
        guard let host0 = normalizedHost(host) else { return false }
        if preSeededHosts.contains(where: { host0 == $0 || host0.hasSuffix("." + $0) }) {
            return true
        }
        return score(for: record) >= (scoreThresholdSeconds / 3600)
    }

    static func normalizedHost(_ host: String) -> String? {
        let trimmed = host.lowercased().trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
