@preconcurrency import CoreSpotlight
import Foundation
import UniformTypeIdentifiers
import os

/// Spotlight 索引（v0.8.22 批四）：把历史/书签/摘录送进系统搜索。
///
/// 口径：
/// - **标识 = "<来源>|<url>"**——点结果时 AppDelegate 解析出 URL 直接在本应用
///   打开；不依赖内存映射，冷启动也成立。
/// - 每次重建先删本域再整体重投（条数少、保证删除不残留）；重建由启动错峰
///   与数据源变更防抖触发。
/// - 内容是用户自己的浏览数据，只留在本机索引；开关默认开，关掉即清空。
@MainActor
enum SpotlightIndexer {
    private static let enabledKey = "spotlight.index.enabled"
    private static let domain = "me.siwi.Desire.local"
    private static var started = false
    private static var scheduled: Task<Void, Never>?
    /// 最近一次投递结果（桥 /spotlight/status 与排查用）。
    private(set) static var lastIndexedCount = 0
    private(set) static var lastError: String?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled {
            schedule(after: 1)
        } else {
            deleteAll()
        }
    }

    /// AppState.init 末尾调用：错峰首建，不占启动路径。
    static func start() {
        guard !started else { return }
        started = true
        guard isEnabled else { return }
        schedule(after: 40)
    }

    /// 数据源变更后的防抖重建（摘录/书签/历史写入方调用）。
    static func schedule(after seconds: TimeInterval) {
        guard isEnabled else { return }
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            rebuild()
        }
    }

    /// 全量重建（先清本域）。在主线程取快照、后台投递。
    static func rebuild() {
        guard isEnabled else { return }
        var items: [CSSearchableItem] = []

        if let app = AppState.live {
            for entry in app.historyStore.entries.prefix(2_000) {
                guard entry.url.hasPrefix("http") else { continue }
                items.append(makeItem(source: .history,
                                      url: entry.url,
                                      title: entry.title.isEmpty ? entry.url : entry.title,
                                      snippet: entry.url))
            }
            func walk(_ nodes: [Bookmark]) {
                for node in nodes {
                    if items.count >= 4_000 { return }
                    if let url = node.url, url.hasPrefix("http") || url.hasPrefix("file") {
                        let tags = (node.tags ?? []).joined(separator: " ")
                        items.append(makeItem(source: .bookmark, url: url, title: node.title,
                                              snippet: tags.isEmpty ? url : tags))
                    } else {
                        walk(node.children)
                    }
                }
            }
            walk(app.bookmarkStore.bookmarks)
        }
        for excerpt in ExcerptStore.shared.excerpts.prefix(1_000) {
            let source = excerpt.source.hasPrefix("http") ? excerpt.source : nil
            items.append(makeItem(source: .excerpt, url: source ?? "",
                                  title: excerpt.title.isEmpty ? excerpt.content : excerpt.title,
                                  snippet: SemanticText.snippet(excerpt.content, max: 200)))
        }

        guard !items.isEmpty else {
            deleteAll()
            return
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { error in
                // 完成回调在系统队列：状态是 @MainActor 的，跳回主 actor 再写。
                Task { @MainActor in
                    if let error {
                        lastError = error.localizedDescription
                        Log.app.error("spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        lastIndexedCount = items.count
                        lastError = nil
                        Log.app.info("spotlight indexed \(items.count, privacy: .public) item(s)")
                    }
                }
            }
        }
    }

    static func deleteAll() {
        lastIndexedCount = 0
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }

    /// 桥端点 `GET /spotlight/status` 的载荷。
    static func statusPayload() -> [String: Any] {
        [
            "enabled": isEnabled,
            "indexed": lastIndexedCount,
            "lastError": lastError ?? "",
        ]
    }

    /// 解析 Spotlight 结果标识 → URL（AppDelegate 的 continue 处理用）。
    static func url(fromIdentifier identifier: String) -> String? {
        guard let separator = identifier.firstIndex(of: "|") else { return nil }
        let url = String(identifier[identifier.index(after: separator)...])
        guard url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("file://") else {
            return nil
        }
        return url
    }

    private static func makeItem(source: SemanticSource, url: String,
                                 title: String, snippet: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = snippet
        attributes.keywords = ["Desire", "browser"]
        if let target = URL(string: url) {
            attributes.contentURL = target
        }
        let identifier = "\(source.rawValue)|\(url)"
        return CSSearchableItem(uniqueIdentifier: identifier,
                                domainIdentifier: domain,
                                attributeSet: attributes)
    }
}
