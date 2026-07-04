import SwiftUI

struct ReadingListPanel: View {
    @ObservedObject var store: ReadingListStore
    let onSelect: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("阅读列表")
                    .font(.headline)
                Spacer()
                if !store.items.isEmpty {
                    Button("全部清除") { store.clearAll() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                Button("关闭") { onClose() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape)
            }
            .padding()

            if store.items.isEmpty {
                EmptyState(message: "阅读列表为空\n在浏览器菜单中选择「添加到阅读列表」来保存文章稍后阅读")
            } else {
                List {
                    ForEach(store.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.isRead ? "circle.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(item.isRead ? .secondary : Color.accentColor)

                            Button {
                                let url = item.url
                                onSelect(url)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .lineLimit(1)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(item.isRead ? .secondary : .primary)
                                    Text(item.url)
                                        .lineLimit(1)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(item.savedDate, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(item.isRead ? "标记为未读" : "标记为已读") { store.toggleRead(item.id) }
                                Button("删除") { store.remove(item.id) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { store.remove(at: $0) }
                }
            }
        }
        .frame(width: 420, height: 400)
    }
}

#Preview {
    ReadingListPanel(store: ReadingListStore(), onSelect: { _ in }, onClose: {})
        .frame(width: 420, height: 400)
}
