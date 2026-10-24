import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
class BookmarkStore: ObservableObject {
    @Published var bookmarks: [Bookmark] = []
    private let saveKey = "bookmarks"
    /// Profile 作用域（0.3.5）：nil = 默认桶；切换时保存当前 → 加载新桶
    /// （种子/legacy 迁移只属于默认桶，作用域桶为空即空）。
    private var scopeID: UUID?
    private var scopedKey: String {
        guard let scopeID else { return saveKey }
        return saveKey + "." + scopeID.uuidString
    }
    /// Legacy UserDefaults key — read once during migration, then deleted.
    private let legacySaveKey = "desire.bookmarks"

    /// 云同步待删清单（tombstone）：本地 remove 时记录，push 成功后被服务端
    /// 持久化即清除。删除必须显式推 tombstone——否则全量 push 不含该节点，
    /// 其他设备 pull 不到删除痕迹，会把本地已删的节点"救活"。
    @Published private(set) var pendingDeletions: [UUID: Date] = [:]
    private let deletionsKey = "bookmarks.deletions"
    private var scopedDeletionsKey: String {
        guard let scopeID else { return deletionsKey }
        return deletionsKey + "." + scopeID.uuidString
    }

    /// URL index of all leaf bookmarks, maintained incrementally so
    /// `contains(url:)` is O(1) instead of flattening the whole tree on every
    /// call (it ran 3× per Toolbar render, per keystroke in the address bar).
    private var leafURLs: Set<String> = []

    /// Flattened, pre-lowercased leaf entries for cheap address-bar matching.
    /// Rebuilt alongside `leafURLs`. Lets `AddressSuggestionsModel.build` scan
    /// bookmarks per keystroke without flattening the tree or calling
    /// `.lowercased()` on each item each time.
    private(set) var leafEntries: [LeafEntry] = []

    /// A lowercase-indexed bookmark leaf for suggestion matching.
    struct LeafEntry {
        let title: String
        let url: String
        let titleLower: String
        let urlLower: String
    }

    init() {
        load()
        if bookmarks.isEmpty { seedDefaults() }
    }

    var allBookmarks: [Bookmark] {
        bookmarks.flatMap { $0.flattened() }.filter { $0.0.isLeaf }.map(\.0)
    }

    func add(title: String, url: String, parentID: UUID? = nil) {
        let bookmark = Bookmark.leaf(title: title, url: url)
        if let parentID {
            _ = bookmarks.update(id: parentID) { $0.children.append(bookmark) }
        } else {
            bookmarks.append(bookmark)
        }
        _ = bookmarks.update(id: bookmark.id) { $0.updatedAt = Date() }
        // Rebuild (not just leafURLs.insert): leafEntries feeds address-bar
        // suggestion matching — without this, a freshly added bookmark only
        // started suggesting after a relaunch.
        rebuildURLIndex()
        save()
    }

    func addFolder(title: String, parentID: UUID? = nil) {
        let folder = Bookmark.folder(title: title)
        if let parentID {
            _ = bookmarks.update(id: parentID) { $0.children.append(folder) }
        } else {
            bookmarks.append(folder)
        }
        _ = bookmarks.update(id: folder.id) { $0.updatedAt = Date() }
        save()
    }

    func remove(_ bookmark: Bookmark) {
        // **子树墓碑**：删文件夹若只记文件夹一条墓碑，子项 id 从不上报——
        // 其他设备收不到子项删除，会用自己的子项把文件夹"救活"（跨设备
        // 删除竞态、根部复活）。删除前先取**树上当前节点**（含最新子树），
        // 整棵子树的 id 全部记墓碑。
        let node = bookmarks.find { $0.id == bookmark.id } ?? bookmark
        for id in Self.subtreeIDs(node) { pendingDeletions[id] = Date() }
        _ = bookmarks.remove(id: bookmark.id)
        saveDeletions()
        rebuildURLIndex()
        save()
    }

    /// 按 id 删除（含文件夹子树；桥的测试清理/导入回滚用）。
    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let node = bookmarks.find(where: { $0.id == id }) else { return false }
        remove(node)
        return true
    }

    private static func subtreeIDs(_ root: Bookmark) -> [UUID] {
        var ids = [root.id]
        for child in root.children { ids.append(contentsOf: subtreeIDs(child)) }
        return ids
    }

    /// 全部不重复标签（排序）。面板的标签过滤条用它。
    var allTags: [String] {
        var seen = Set<String>()
        for (node, _) in bookmarks.flatMap({ $0.flattened() }) {
            if let tags = node.tags { seen.formUnion(tags) }
        }
        return seen.sorted()
    }

    func update(_ bookmark: Bookmark) {
        _ = bookmarks.update(id: bookmark.id) {
            $0 = bookmark
            $0.updatedAt = Date()
        }
        rebuildURLIndex()
        save()
    }

    func contains(url: String) -> Bool {
        leafURLs.contains(url)
    }

    /// 现有叶子 URL 全集——导入去重向导/桥的判定输入（归一化在
    /// BookmarkImportDedupe 里做）。
    func importedURLSet() -> Set<String> {
        leafURLs
    }

    func find(url: String) -> Bookmark? {
        bookmarks.find { $0.url == url }
    }

    private func load() {
        // Primary: DiskStore (debounced, off-main).
        if let decoded = DiskStore.load([Bookmark].self, key: saveKey) {
            bookmarks = normalizeTimestamps(decoded)
            pendingDeletions = DiskStore.load([UUID: Date].self, key: deletionsKey) ?? [:]
            rebuildURLIndex()
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: legacySaveKey),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = normalizeTimestamps(decoded)
            pendingDeletions = [:]
            rebuildURLIndex()
            save()
            UserDefaults.standard.removeObject(forKey: legacySaveKey)
        }
    }

    func save() {
        DiskStore.save(bookmarks, key: scopedKey)
    }

    /// AppState.applyProfile 驱动（0.3.5）。
    func applyScope(profileID: UUID?) {
        guard scopeID != profileID else { return }
        save()
        scopeID = profileID
        bookmarks = normalizeTimestamps(DiskStore.load([Bookmark].self, key: scopedKey) ?? [])
        pendingDeletions = DiskStore.load([UUID: Date].self, key: scopedDeletionsKey) ?? [:]
        rebuildURLIndex()
    }

    func saveImported(_ newBookmarks: [Bookmark]) {
        bookmarks.append(contentsOf: normalizeTimestamps(newBookmarks))
        rebuildURLIndex()
        save()
    }

    // MARK: - 云同步（SyncStore 驱动）

    /// 同步合并结果整树替换（LWW 仲裁已在 BookmarkSync.merge 完成）。
    /// 合并进来的节点自带服务端认可的时间戳，不再二次盖戳。
    func replaceForSync(_ tree: [Bookmark]) {
        bookmarks = tree
        rebuildURLIndex()
        save()
    }

    /// 浏览器导入（v0.8.0）：保留来源的文件夹结构，按 URL 去重后整棵挂到
    /// 一个来源根目录下（非破坏式）。返回 (导入叶子数, 跳过重复数)。
    @discardableResult
    func mergeImportedTree(_ incoming: [Bookmark], rootTitle: String) -> (imported: Int, skipped: Int) {
        let plan = BookmarkImportDedupe.plan(incoming: incoming,
                                             existingURLs: importedURLSet())
        guard !plan.filtered.isEmpty else { return (0, plan.duplicateCount) }
        let now = Date()
        func stamp(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.map { node in
                Bookmark(id: UUID(), title: node.title, url: node.url,
                         children: stamp(node.children), updatedAt: now)
            }
        }
        let root = Bookmark(id: UUID(), title: rootTitle, url: nil,
                            children: stamp(plan.filtered), updatedAt: now)
        bookmarks.append(root)
        rebuildURLIndex()
        save()
        return (plan.fresh, plan.duplicateCount)
    }

    /// 备份合并（v0.7.28）：按 URL 去重，把缺失的书签放进一个 "Imported …"
    /// 文件夹（非破坏式；用户可自行整理/删除）。
    @discardableResult
    func mergeImported(_ incoming: [Bookmark], folderTitle: String) -> Int {
        var seen = Set(flatBookmarks(bookmarks).compactMap(\.url))
        let leaves = flatBookmarks(incoming).filter { node in
            guard let url = node.url, !seen.contains(url) else { return false }
            seen.insert(url)
            return true
        }
        guard !leaves.isEmpty else { return 0 }
        let now = Date()
        let folder = Bookmark(
            id: UUID(), title: folderTitle, url: nil,
            children: leaves.map {
                Bookmark(id: UUID(), title: $0.title, url: $0.url,
                         children: [], updatedAt: now)
            },
            updatedAt: now)
        bookmarks.append(folder)
        rebuildURLIndex()
        save()
        return leaves.count
    }

    private func flatBookmarks(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { [$0] + flatBookmarks($0.children) }
    }

    /// push 成功后从待删清单移除（clientIDs = 服务端已 applied 的条目）。
    func clearPendingDeletions(_ clientIDs: Set<String>) {        guard !clientIDs.isEmpty, !pendingDeletions.isEmpty else { return }
        let ids = Set(clientIDs.compactMap(UUID.init(uuidString:)))
        let hits = pendingDeletions.keys.filter { ids.contains($0) }
        guard !hits.isEmpty else { return }
        for id in hits { pendingDeletions.removeValue(forKey: id) }
        saveDeletions()
    }

    private func saveDeletions() {
        DiskStore.save(pendingDeletions, key: scopedDeletionsKey)
    }

    /// 旧数据/导入内容补盖同步戳（nil → now），维持"树内节点恒有时间戳"不变式。
    private func normalizeTimestamps(_ tree: [Bookmark]) -> [Bookmark] {
        let now = Date()
        func stamp(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.map { node in
                var out = node
                if out.updatedAt == nil { out.updatedAt = now }
                out.children = stamp(out.children)
                return out
            }
        }
        return stamp(tree)
    }

    /// Rebuilds `leafURLs` and `leafEntries` from the current tree. Called
    /// after load and after mutations that can change many URLs at once
    /// (remove, update, import).
    private func rebuildURLIndex() {
        let leaves = allBookmarks.compactMap { $0.url }
        leafURLs = Set(leaves)
        leafEntries = allBookmarks.map {
            LeafEntry(
                title: $0.title,
                url: $0.url ?? "",
                titleLower: $0.title.lowercased(),
                urlLower: ($0.url ?? "").lowercased()
            )
        }
    }

    private func seedDefaults() {
        bookmarks = normalizeTimestamps([
            .folder(title: String(localized: "Common Sites"), children: [
                .leaf(title: "GitHub", url: "https://github.com"),
                .leaf(title: "Stack Overflow", url: "https://stackoverflow.com"),
            ]),
            .leaf(title: "Hacker News", url: "https://news.ycombinator.com"),
        ])
        rebuildURLIndex()
        save()
    }

    // MARK: - Import / Export

    func exportToHTML() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Bookmarks")
        panel.nameFieldStringValue = "bookmarks.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let html = generateBookmarksHTML(bookmarks)
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    private func generateBookmarksHTML(_ items: [Bookmark], indent: Int = 0) -> String {
        let ind = String(repeating: "    ", count: indent)
        var html = "\(ind)<DL><p>\n"
        for item in items {
            if item.isLeaf, let url = item.url {
                let title = item.title.htmlEscaped
                let href = url.htmlEscaped
                html += "\(ind)    <DT><A HREF=\"\(href)\">\(title)</A>\n"
            } else {
                html += "\(ind)    <DT><H3>\(item.title.htmlEscaped)</H3>\n"
                html += generateBookmarksHTML(item.children, indent: indent + 1)
            }
        }
        html += "\(ind)</DL><p>\n"
        return html
    }

}

private extension String {
    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
