import AppKit
import SwiftUI

/// 剪贴板历史面板（v0.8.19 旗舰）：⌘⇧V 唤起——搜索过滤、点击回灌、
/// 逐条删除、一键清空。数据源 ClipboardHistoryStore（轮询采集）。
struct ClipboardHistoryPanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var store = ClipboardHistoryStore.shared

    @State private var query = ""
    @State private var copiedID: UUID?

    private var items: [ClipboardHistoryStore.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text(store.entries.isEmpty
                         ? String(localized: "No clipboard history yet — copy something and it lands here (24h, passwords excluded)")
                         : String(localized: "No matches"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { entry in
                            row(entry)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            footer
        }
        .frame(width: 520, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appAccent)
            Text("Clipboard History")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(String(localized: "Clear All"), role: .destructive) {
                store.clearAll()
            }
            .disabled(store.entries.isEmpty)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField(String(localized: "Search history"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func row(_ entry: ClipboardHistoryStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.text)
                .font(.system(size: 12, design: entry.kind == .text ? .default : .monospaced))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: kindIcon(entry.kind))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(kindLabel(entry.kind))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(appAccent)
                Text(entry.capturedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                if copiedID == entry.id {
                    Text(String(localized: "Copied"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(appAccent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button(String(localized: "Copy Again")) { copyBack(entry) }
            Button(String(localized: "Remove"), role: .destructive) {
                store.remove(id: entry.id)
            }
        }
        .onTapGesture { copyBack(entry) }
    }

    private func copyBack(_ entry: ClipboardHistoryStore.Entry) {
        store.copyBack(entry)
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedID == entry.id { copiedID = nil }
        }
    }

    private func kindIcon(_ kind: ClipboardHistoryStore.Entry.Kind) -> String {
        switch kind {
        case .url: return "safari"
        case .path: return "folder"
        case .text: return "text.alignleft"
        }
    }

    private func kindLabel(_ kind: ClipboardHistoryStore.Entry.Kind) -> String {
        switch kind {
        case .url: return String(localized: "URL")
        case .path: return String(localized: "File")
        case .text: return String(localized: "Text")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Click to copy back · passwords copied from the manager are never recorded"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
    }
}
