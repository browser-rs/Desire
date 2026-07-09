import SwiftUI

struct SearchHistoryPanel: View {
    @ObservedObject var store: SearchHistoryStore
    var onSelect: (String) -> Void
    var onClose: () -> Void

    @State private var searchText = ""

    private var filteredEntries: [SearchHistory] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return store.entries
        }
        return store.entries.filter { $0.query.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            if filteredEntries.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .frame(width: 400, height: 500)
    }

    private var header: some View {
        HStack {
            Text("Search History")
                .font(.headline)
            Spacer()
            Button("Clear All") {
                store.clearAll()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.bar)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search in history...", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Search History")
                .font(.headline)
                .foregroundStyle(.secondary)
            if !searchText.isEmpty {
                Text("No results for \"\(searchText)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        List {
            ForEach(filteredEntries) { entry in
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.query)
                            .lineLimit(1)
                        Text(formatTimestamp(entry.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.engine.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(entry.query)
                }
                .contextMenu {
                    Button("Copy Query") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.query, forType: .string)
                    }
                    Button("Search Again") {
                        onSelect(entry.query)
                    }
                    Divider()
                    Button("Remove") {
                        store.remove(id: entry.id)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}