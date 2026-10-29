import Foundation

/// 跨标签上下文的**纯逻辑**（v0.8.22 批三）：编号、拼装与封顶。
/// Foundation-only，进 tests/run.sh——取文（WebKit）与模型调用留在
/// `TabDigestStore`，这里只保证"送给模型的这块文本"是可测的。
nonisolated enum TabDigestCore {
    /// 送模型的总预算（与 TabDigestStore.totalCharCap 同值）。
    static let totalCharCap = 40_000

    struct Entry: Equatable, Sendable {
        var title: String
        var url: String
        var text: String
    }

    /// `[n] title\nurl\ntext` —— 编号从 1 起，与模型引用的 `[n]` 对齐。
    static func context(from entries: [Entry]) -> String {
        entries.enumerated().map { index, entry in
            "[\(index + 1)] \(entry.title)\n\(entry.url)\n\(entry.text)"
        }.joined(separator: "\n\n")
    }

    /// 超预算截断并标注；**按字符**截断（不会切坏多字节字符）。
    static func capped(_ block: String, cap: Int = totalCharCap) -> String {
        guard block.count > cap else { return block }
        return String(block.prefix(cap)) + "\n…[truncated]"
    }
}
