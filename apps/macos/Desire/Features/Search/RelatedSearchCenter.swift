import Combine
import Foundation

/// 划词 → 语义检索的交接中心（v0.8.25）：入口（就地卡 / 右键菜单）把选中的
/// 文字放进来，集中搜索面板（⌘⇧F）在下次展开时消费并切到"语义"档。
///
/// 一次性请求：`consume()` 取走即清空，避免每次打开搜索面板都重放旧选区。
@MainActor
final class RelatedSearchCenter: ObservableObject {
    static let shared = RelatedSearchCenter()

    struct Request: Equatable {
        var text: String
        var semantic: Bool
    }

    /// 变更计数器（面板用 `.onChange` 感知"面板已开着时又来了新请求"）。
    @Published private(set) var requestToken = 0
    private var pending: Request?

    private init() {}

    func request(_ text: String, semantic: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending = Request(text: String(trimmed.prefix(200)), semantic: semantic)
        requestToken += 1
    }

    func consume() -> Request? {
        defer { pending = nil }
        return pending
    }
}
