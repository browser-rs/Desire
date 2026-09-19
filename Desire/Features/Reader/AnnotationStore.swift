import Combine
import CryptoKit
import Foundation

/// 页面批注（0.3.7）：划选高亮的持久化存储。每页一个桶（URL 归一化
/// 后哈希为 DiskStore key），高亮记录 {text, colorIndex, createdAt}——
/// 锚定用**文本**而非 XPath（动态页面 XPath 不可靠；恢复时按文本
/// 查找首次出现处包裹）。
@MainActor
final class AnnotationStore: ObservableObject {
    static let shared = AnnotationStore()

    /// 高亮色板（与 SelectionAIBar 的色点一一对应）。
    static let palette: [String] = ["yellow", "green", "blue", "pink"]

    @Published private(set) var pageHighlights: [String: [PageHighlight]] = [:]

    struct PageHighlight: Codable, Identifiable {
        let id: UUID
        let url: String
        let text: String
        var colorIndex: Int
        let createdAt: Date
    }

    private init() {}

    static func bucketKey(for url: String) -> String {
        let normalized = URL(string: url).map { "\($0.host ?? "")\($0.path)" } ?? url
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "annotations." + digest.map { String(format: "%02x", $0) }.prefix(16).joined()
    }

    func highlights(for url: String) -> [PageHighlight] {
        let key = Self.bucketKey(for: url)
        if let cached = pageHighlights[key] { return cached }
        let loaded = DiskStore.load([PageHighlight].self, key: key) ?? []
        pageHighlights[key] = loaded
        return loaded
    }

    func add(url: String, text: String, colorIndex: Int) -> PageHighlight {
        let highlight = PageHighlight(id: UUID(), url: url, text: text,
                                      colorIndex: max(0, min(colorIndex, Self.palette.count - 1)),
                                      createdAt: Date())
        let key = Self.bucketKey(for: url)
        var list = pageHighlights[key] ?? []
        // 同页同文本重复划选 → 更新颜色而不是追加。
        list.removeAll { $0.text == text }
        list.append(highlight)
        pageHighlights[key] = list
        DiskStore.save(list, key: key)
        return highlight
    }

    func remove(id: UUID, url: String) {
        let key = Self.bucketKey(for: url)
        var list = pageHighlights[key] ?? []
        list.removeAll { $0.id == id }
        pageHighlights[key] = list
        DiskStore.save(list, key: key)
    }

    /// Agent/导出用：当前页全部高亮的纯文本。
    func exportText(for url: String) -> String {
        let list = highlights(for: url)
        guard !list.isEmpty else { return "" }
        return list.enumerated().map { i, h in
            "[\(i + 1)] (color: \(Self.palette[min(h.colorIndex, Self.palette.count - 1)])) \(h.text)"
        }.joined(separator: "\n")
    }
}
