import Combine
import Foundation

/// 历史正文索引（v0.8.0）：opt-in 抓取页面正文前 3000 字，本地检索。
///
/// 隐私取舍：默认关闭；只存正文片段（不存 DOM/表单/密码），不随云同步；
/// 清除按钮一次性删掉全部记录。每页最多一条（同 URL 更新）。
@MainActor
final class HistoryContentStore: ObservableObject {
    static let shared = HistoryContentStore()

    @Published private(set) var records: [HistoryContentRecord] = []
    @Published private(set) var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    private let defaults = UserDefaults.standard
    private static let enabledKey = "history.contentIndex.enabled"
    private let storageKey = "history.contentIndex"
    private let maxRecords = 800
    private let maxTextLength = 3000

    private init() {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        records = DiskStore.load([HistoryContentRecord].self, key: storageKey) ?? []
    }

    var count: Int { records.count }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
    }

    /// 页面加载完成后调用；未开启/无痕/非网页直接忽略。
    func capture(url: String, title: String, text: String, isPrivate: Bool) {
        guard isEnabled, !isPrivate else { return }
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return }
        let clipped = String(collapsed.prefix(maxTextLength))
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = HistoryContentRecord(
            url: url,
            title: trimmedTitle.isEmpty ? url : trimmedTitle,
            text: clipped,
            updatedAt: Date())
        records.removeAll { $0.url == url }
        records.insert(record, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        save()
    }

    func search(query: String, limit: Int = 20) -> [HistoryContentHit] {
        HistoryContentSearch.search(query: query, records: records, limit: limit)
    }

    func clear() {
        guard !records.isEmpty else { return }
        records.removeAll()
        save()
    }

    private func save() {
        DiskStore.save(records, key: storageKey)
    }
}
