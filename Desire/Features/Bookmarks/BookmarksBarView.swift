import SwiftUI

/// 常驻书签栏（工具栏下方）：顶层叶子直接点击导航，文件夹下拉展开，
/// 数据与书签面板/星标同源（BookmarkStore）。空书签时整条隐藏。
struct BookmarksBarView: View {
    @ObservedObject var store: BookmarkStore
    /// 导航回调（当前选中标签页）。
    let onNavigate: (String) -> Void

    var body: some View {
        let items = store.bookmarks
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { _, bookmark in
                        if bookmark.isFolder {
                            folderMenu(bookmark)
                        } else if bookmark.url != nil {
                            leafButton(bookmark)
                        }
                    }
                    if items.count > 0 {
                        Spacer(minLength: 8)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func leafButton(_ bookmark: Bookmark) -> some View {
        Button {
            if let url = bookmark.url {
                onNavigate(url)
            }
        } label: {
            HStack(spacing: 4) {
                FaviconView(urlString: bookmark.url ?? "", size: 12)
                Text(bookmark.title)
                    .lineLimit(1)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(bookmark.url ?? "")
    }

    private func folderMenu(_ folder: Bookmark) -> some View {
        Menu {
            ForEach(folder.children) { child in
                if child.isLeaf, let url = child.url {
                    Button(child.title) { onNavigate(url) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(folder.title)
                    .lineLimit(1)
                    .font(.system(size: 11))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
