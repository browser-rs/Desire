import Foundation

extension AgentWriteUndoRecorder {
    /// 执行还原（按 revertPlan 逆序回放；存储动作注入）并移除该组。
    func revert(groupID: UUID,
                bookmarks: BookmarkStore, readingList: ReadingListStore) -> Int? {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return nil }
        let group = groups[idx]
        for step in AgentWriteUndo.revertPlan(for: group).reversed() {
            switch step {
            case .remove(let id, .bookmark):
                if let bm = bookmarks.find(id: id) { bookmarks.remove(bm) }
            case .remove(let id, .readingItem):
                readingList.remove(id)
            case .restore(_, .bookmark, let json):
                if let data = Data(base64Encoded: json),
                   let bm = try? JSONDecoder().decode(Bookmark.self, from: data) {
                    bookmarks.restoreForUndo(bm)
                }
            case .restore(_, .readingItem, let json):
                if let data = Data(base64Encoded: json),
                   let item = try? JSONDecoder().decode(ReadingListItem.self, from: data) {
                    readingList.restoreForUndo(item)
                }
            }
        }
        removeGroup(id: groupID)
        return group.changes.count
    }
}
