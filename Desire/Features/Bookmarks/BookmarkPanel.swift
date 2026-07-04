import SwiftUI

struct BookmarkPanel: View {
    @ObservedObject var store: BookmarkStore
    var onSelect: (String) -> Void
    var onDelete: (Bookmark) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("书签").font(.headline)
                Spacer()
                Button("关闭", action: onClose)
            }
            .padding()

            if store.bookmarks.isEmpty {
                emptyState("暂无书签")
            } else {
                List(store.bookmarks) { bookmark in
                    HStack {
                        EntryRow(title: bookmark.title, subtitle: bookmark.url, action: { onSelect(bookmark.url) })
                        Spacer()
                        Button("", systemImage: "trash", action: { onDelete(bookmark) })
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}
