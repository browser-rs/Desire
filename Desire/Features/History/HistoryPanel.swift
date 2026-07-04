import SwiftUI

struct HistoryPanel: View {
    @ObservedObject var store: HistoryStore
    var onSelect: (String) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("浏览历史").font(.headline)
                Spacer()
                Button("关闭", action: onClose)
            }
            .padding()

            if store.entries.isEmpty {
                emptyState("暂无浏览记录")
            } else {
                List(store.entries) { entry in
                    EntryRow(title: entry.title, subtitle: entry.url, action: { onSelect(entry.url) })
                }
            }
        }
        .frame(width: 400, height: 500)
    }
}
