import Combine
import Foundation

/// 阅读高亮的本地库（v0.7.29）：UserDefaults JSON，按页面 URL 查询。
/// 上限 500 条（超出丢最旧）；备份导入支持 replace / merge。
@MainActor
final class ReaderHighlightStore: ObservableObject {
    static let shared = ReaderHighlightStore()

    @Published private(set) var highlights: [ReaderHighlight] = []

    private static let key = "desire.readerHighlights"
    private static let cap = 500

    private init() { load() }

    func list(for url: String) -> [ReaderHighlight] {
        highlights.filter { $0.url == url }.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func add(url: String, quote: String, prefix: String = "", suffix: String = "",
             color: ReaderHighlight.Color = .yellow, note: String? = nil) -> ReaderHighlight? {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = ReaderHighlight(url: url, quote: trimmed,
                                   prefix: String(prefix.suffix(ReaderHighlightAnchor.contextLimit)),
                                   suffix: String(suffix.prefix(ReaderHighlightAnchor.contextLimit)),
                                   color: color, note: note)
        highlights.append(item)
        trim()
        save()
        return item
    }

    func setNote(_ id: UUID, note: String?) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        highlights[index].note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    func setColor(_ id: UUID, _ color: ReaderHighlight.Color) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        highlights[index].color = color
        save()
    }

    func delete(_ id: UUID) {
        highlights.removeAll { $0.id == id }
        save()
    }

    func markdown(for url: String) -> String {
        ReaderHighlightAnchor.markdown(url: url, highlights: list(for: url))
    }

    // MARK: - 备份

    func replaceAll(_ items: [ReaderHighlight]) {
        highlights = Array(items.sorted { $0.createdAt < $1.createdAt }.suffix(Self.cap))
        save()
    }

    /// 按 id 或 (url, quote, prefix) 去重；返回新增条数。
    @discardableResult
    func merge(_ items: [ReaderHighlight]) -> Int {
        var keys = Set(highlights.map(Self.identity))
        var added = 0
        for item in items {
            let key = Self.identity(item)
            guard !keys.contains(key) else { continue }
            keys.insert(key)
            highlights.append(item)
            added += 1
        }
        if added > 0 {
            trim()
            save()
        }
        return added
    }

    private static func identity(_ item: ReaderHighlight) -> String {
        "\(item.id.uuidString)|\(item.url)|\(item.quote)|\(item.prefix)"
    }

    private func trim() {
        if highlights.count > Self.cap {
            highlights.removeFirst(highlights.count - Self.cap)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([ReaderHighlight].self, from: data) else { return }
        highlights = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(highlights) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
