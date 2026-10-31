import Combine
import Foundation
import os

/// 自动播放诊断（v0.8.32 专项的可观测落位）：暂停 oracle / consent 拦截 /
/// 策略重烙事件的**进程内环形缓冲**（cap 100，新→旧）+ os_log 全量落
/// 统一日志。设置 ▸ 自动播放诊断页与统一日志同源读这里。
@MainActor
final class AutoplayDiagnosticsStore: ObservableObject {
    static let shared = AutoplayDiagnosticsStore()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        /// pause / consent-blocked / policy-baked / reopen / kick
        let kind: String
        /// 分类后的动作来源：youtube-player / page-js / our-script:<名> /
        /// webkit-internal / unknown
        let actor: String
        let detail: String

        var timeText: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: time)
        }
    }

    @Published private(set) var entries: [Entry] = []
    private let cap = 100

    func record(kind: String, actor: String, detail: String) {
        let entry = Entry(time: Date(), kind: kind, actor: actor, detail: detail)
        entries.insert(entry, at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        Log.autoplay.info("autoplay[\(kind, privacy: .public)] actor=\(actor, privacy: .public) \(detail, privacy: .public)")
    }

    func clear() {
        entries.removeAll()
    }
}

/// 暂停调用栈分类器（oracle 事件的 actor 归类）——纯 Foundation 可测。
nonisolated enum PauseStackClassifier {

    /// 从调用栈文本归类动作来源。命中自研脚本时给出脚本名。
    static func classify(stack: String) -> String {
        let knownScripts = [
            "yt-playback-guard": "our-script:yt-playback-guard",
            "yt-anti-detect": "our-script:yt-anti-detect",
            "sponsorblock": "our-script:sponsorblock",
            "media-visibility-resume": "our-script:media-visibility-resume",
            "media-pause-diag": "our-script:media-pause-diag(oracle)",
            "video-speed": "our-script:video-speed",
            "yt-json-prune": "our-script:yt-json-prune",
        ]
        for (marker, label) in knownScripts where stack.contains(marker) {
            return label
        }
        if stack.contains("user-script:") {
            return "our-script:unknown"
        }
        if stack.contains("base.js") || stack.contains("youtube") {
            return "youtube-player"
        }
        // 全部帧都是宿主/空栈 = WebKit 内部路径（如可见性恢复被 consent 拦）。
        return "webkit-internal"
    }
}
