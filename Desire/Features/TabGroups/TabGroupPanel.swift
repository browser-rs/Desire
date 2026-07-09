import SwiftUI

struct TabGroupPanel: View {
    @ObservedObject var store: TabGroupStore
    @ObservedObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    @State private var newGroupName = ""
    @State private var showCreateGroup = false

    private let colors: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow,
        .green, .mint, .teal, .cyan, .indigo, .brown
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Tab Groups").font(.headline)
                Spacer()
                Button("Create Group") {
                    showCreateGroup = true
                }
                Button("Close") { dismiss() }
            }
            .padding()

            Divider()

            if store.groups.isEmpty {
                EmptyState(message: "No Tab Groups Created")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.groups) { group in
                        groupRow(group)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            store.delete(store.groups[index].id)
                        }
                    }
                }
            }
        }
        .frame(width: 500, height: 500)
        .sheet(isPresented: $showCreateGroup) {
            createGroupSheet
        }
    }

    private func groupRow(_ group: TabGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(colors[group.colorIndex % colors.count])
                    .frame(width: 12, height: 12)

                Text(group.name)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Text("\(group.tabIds.count) tabs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Show tabs in group
            if !group.tabIds.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(group.tabIds), id: \.self) { tabId in
                            if let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
                                tabChip(tab, group: group)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                // Open all tabs in group
                for tabId in group.tabIds {
                    if let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.selectTab(at: index)
                        break
                    }
                }
            } label: {
                Label("Open Group", systemImage: "arrow.right.circle")
            }

            Button(role: .destructive) {
                store.delete(group.id)
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
    }

    private func tabChip(_ tab: Tab, group: TabGroup) -> some View {
        HStack(spacing: 6) {
            if let url = URL(string: tab.urlString) {
                FaviconView(urlString: url.absoluteString, size: 14)
            }

            Text(tab.displayTitle)
                .font(.caption2)
                .lineLimit(1)

            Button {
                store.removeTab(tab.id, from: group.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var createGroupSheet: some View {
        VStack(spacing: 16) {
            Text("Create Tab Group").font(.headline)

            TextField("Group Name", text: $newGroupName)
                .textFieldStyle(.roundedBorder)

            // Color selection
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30))], spacing: 8) {
                ForEach(0..<colors.count, id: \.self) { index in
                    Circle()
                        .fill(colors[index])
                        .frame(width: 24, height: 24)
                        .overlay {
                            if index == 0 {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .onTapGesture {
                            // Color selection would be implemented here
                        }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    newGroupName = ""
                    showCreateGroup = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Create") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        _ = store.create(name: name)
                        newGroupName = ""
                        showCreateGroup = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 350)
    }
}

#Preview {
    TabGroupPanel(store: TabGroupStore(), tabManager: TabManager())
}