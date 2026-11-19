import Combine
import Foundation

/// **术语表 Store**（v0.8.64 批 1）：`TranslationGlossary.Entry` 列表的
/// 内存态 + DiskStore 持久化（key `translation-glossary`，防抖异步写——
/// 断言落盘要留防抖窗口）。单例 `.shared`：翻译注入（BilingualReadingService）
/// 与设置页编辑器消费同一实例（读写分离规则：写必须走 UI 持有的实例）。
@MainActor
final class TranslationGlossaryStore: ObservableObject {
    static let shared = TranslationGlossaryStore()
    static let storeKey = "translation-glossary"

    @Published var entries: [TranslationGlossary.Entry] {
        didSet {
            let cleaned = TranslationGlossary.normalized(entries)
            if cleaned != entries { entries = cleaned; return }
            DiskStore.save(entries, key: Self.storeKey)
        }
    }

    private init() {
        entries = DiskStore.load([TranslationGlossary.Entry].self, key: Self.storeKey) ?? []
    }

    func add(_ entry: TranslationGlossary.Entry) {
        entries.append(entry)   // didSet 归一化去重
    }

    func remove(at offsets: IndexSet) {
        // `Array.remove(atOffsets:)` 定义在 SwiftUI——Store 层不 import
        // SwiftUI（三层规范），按倒序下标手删。
        for index in offsets.sorted(by: >) where index < entries.count {
            entries.remove(at: index)
        }
    }

    /// 翻译注入用：该 host 生效的 Glossary 行（专用表行 + 调用方自并记忆行）。
    func lines(for host: String?) -> [String] {
        TranslationGlossary.lines(entries, host: host)
    }
}
