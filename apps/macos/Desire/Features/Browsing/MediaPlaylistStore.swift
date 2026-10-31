import Combine
import Foundation

/// 播放器播放队列（v0.8.30 批次二）：多文件顺序播放的会话内队列。
/// 状态迁移经 `autoAdvanceTo` 发布——MediaViewerView 观察到非 nil 就把
/// 标签的 mediaViewerURL 换过去（视图/播放器随 .id 重建），自己不持有
/// Tab 引用（播放器模型只管当前文件）。
@MainActor
final class MediaPlaylistStore: ObservableObject {
    static let shared = MediaPlaylistStore()

    enum RepeatMode: String {
        case off, list, single
    }

    @Published private(set) var queue: [URL] = []
    @Published private(set) var index: Int = 0
    /// 循环模式（跨文件记住——放歌的场景每次都要）。
    @Published var repeatMode: RepeatMode {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "media.repeatMode") }
    }
    /// 播完自动切到的下一首（视图消费后置回 nil）。
    @Published var autoAdvanceTo: URL?

    init() {
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "media.repeatMode") ?? "") ?? .off
    }

    var current: URL? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var hasMultiple: Bool { queue.count > 1 }

    /// 打开文件时的队列基线：不在既有队列里 → 队列重置为单文件；
    /// 在队列里 → 定位到它（上一个队列继续有效）。
    func activate(_ url: URL) {
        if let existing = queue.firstIndex(of: url) {
            index = existing
        } else {
            queue = [url]
            index = 0
        }
    }

    func add(_ urls: [URL]) {
        for url in urls where !queue.contains(url) {
            queue.append(url)
        }
    }

    /// 队列浮层点选跳播：定位到该条目并返回它（不在队列 = 忽略）。
    @discardableResult
    func jump(to url: URL) -> URL? {
        guard let target = queue.firstIndex(of: url) else { return nil }
        index = target
        return current
    }

    /// 用户点上一/下一曲（忽略循环模式，到头即停/到头即回）。
    @discardableResult
    func skip(_ delta: Int) -> URL? {
        let target = index + delta
        guard queue.indices.contains(target) else { return nil }
        index = target
        return current
    }

    /// 播放自然结束：按循环模式决定去留（返回 nil = 停在原地）。
    @discardableResult
    func handleEnded() -> URL? {
        guard hasMultiple else {
            if repeatMode == .single, let now = current {
                return now
            }
            return nil
        }
        switch repeatMode {
        case .single:
            return current
        case .list:
            index = (index + 1) % queue.count
            return current
        case .off:
            if index + 1 < queue.count {
                index += 1
                return current
            }
            return nil
        }
    }

    func consumeAutoAdvance() {
        autoAdvanceTo = nil
    }
}
