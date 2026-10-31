import Combine
import Foundation

/// MEI-lite 媒体参与度（v0.8.32 重写，Chrome 模型站点无关化）：
/// 按 host 记录媒体播放行为（播放次数 + 累计有声播放秒数），过阈值即
/// 允许有声自动播——替代 yt 白名单硬编码。YouTube/bilibili 等头部站
/// **预置分数**（对齐 Chrome 的 MEI pre-seeding）。
///
/// 语义（对齐 Chrome 文档）：
/// - 计数：单次播放 ≥7 秒才记一次（短预览/刷过不算）
/// - 阈值：score = min(1, seconds / 3600)（1 小时封顶）；≥0.5 视为高参与
///   （Chrome 实测阈值近似）；预置种子直接给 1.0
/// - 站点显式覆写永远优先于参与度
/// 纯逻辑（评分/预置/阈值）在 MediaEngagementCore，本 store 只管持久化
/// 与播放计秒。
@MainActor
final class MediaEngagementStore: ObservableObject {
    static let shared = MediaEngagementStore()

    @Published private(set) var hosts: [String: MediaEngagementCore.Record] = [:]

    private let defaultsKey = "media.engagement.hosts"
    private var playStartedAt: [String: Date] = [:]
    private var saveTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: MediaEngagementCore.Record].self, from: data) {
            hosts = decoded
        }
        // 预置种子（Chrome pre-seeding 对齐）：头部视频站直接视为高参与。
        for host in MediaEngagementCore.preSeededHosts where hosts[host] == nil {
            hosts[host] = MediaEngagementCore.Record(playCount: 0, playSeconds: 3600)
        }
    }

    /// 该 host 是否达到高参与（参与度过线或预置种子）。
    func isHighEngagement(_ host: String) -> Bool {
        MediaEngagementCore.isHighEngagement(host: host, record: hosts[host.lowercased()])
    }

    /// 播放开始（有声；静音预播不计）。
    func playStarted(host: String) {
        let key = host.lowercased()
        guard playStartedAt[key] == nil else { return }
        playStartedAt[key] = Date()
    }

    /// 播放结束/暂停：累计 ≥7 秒记一次（Chrome 口径）。
    func playEnded(host: String) {
        let key = host.lowercased()
        guard let started = playStartedAt.removeValue(forKey: key) else { return }
        let seconds = Date().timeIntervalSince(started)
        guard seconds >= 7 else { return }
        var record = hosts[key] ?? MediaEngagementCore.Record(playCount: 0, playSeconds: 0)
        record.playCount += 1
        record.playSeconds += seconds
        hosts[key] = record
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(self.hosts) {
                UserDefaults.standard.set(data, forKey: self.defaultsKey)
            }
        }
    }
}
