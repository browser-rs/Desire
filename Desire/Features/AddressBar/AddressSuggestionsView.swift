import SwiftUI

struct AddressSuggestionsView: View {
    /// 列表宽度上限：`nil` = 随容器（地址栏用，跟输入框一样接近整宽）；
    /// 新标签页那份用默认的 520（居中的搜索框下面）。
    var maxWidth: CGFloat? = 520
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var model: AddressSuggestionsModel
    var engineName: String
    var searchHistoryStore: SearchHistoryStore?
    var onSelect: (AddressSuggestion) -> Void
    var onSearchHistorySelect: ((String) -> Void)?

    @State private var showSearchHistory = false

    var body: some View {
        // 搜索历史的读取**整体挪进 SearchHistorySection**（它自己
        // `@ObservedObject` 持有 store）——此前在父视图直接读 `store.entries`
        // （发布字段），搜索历史新增时下拉不会重绘（ARCH-4 同型）。
        if !model.suggestions.isEmpty {
            suggestionCard
        } else if let store = searchHistoryStore {
            SearchHistorySection(
                store: store,
                onSelect: { query in onSearchHistorySelect?(query) })
        } else {
            // No rows at all (fresh focus before typing) — render nothing
            // instead of a stray stroked card.
            EmptyView()
        }
    }

    private var suggestionCard: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    row(for: suggestion, at: index)
                    if index < model.suggestions.count - 1 {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: .radiusPopover))
            .shadowElevated()
            .overlay(
                RoundedRectangle(cornerRadius: .radiusPopover)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .onChange(of: model.selectedIndex) { _, newIndex in
                // Keyboard selection drives the scroll so the highlighted
                // row is always visible.
                guard model.suggestions.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.suggestions[newIndex].id, anchor: .center)
                }
            }
        }
    }



    @ViewBuilder
    private func row(for suggestion: AddressSuggestion, at index: Int) -> some View {
        HStack(spacing: 10) {
            leadingIcon(for: suggestion)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle(for: suggestion))
                    .lineLimit(1)
                    .foregroundStyle(suggestion.kind == .navigate ? .primary : .primary)
                if showsSubtitle(suggestion) {
                    Text(suggestion.url)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            kindBadge(for: suggestion)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(index == model.selectedIndex ? appAccent.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(suggestion)
        }
        .onHover { hovering in
            if hovering { model.selectedIndex = index }
        }
    }

    @ViewBuilder
    private func leadingIcon(for suggestion: AddressSuggestion) -> some View {
        switch suggestion.kind {
        case .navigate:
            Image(systemName: "arrow.up.forward.square")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        case .searchDefault, .searchSuggestion:
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        case .bookmark:
            Image(systemName: "bookmark")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        case .history:
            FaviconView(urlString: suggestion.url, size: 16)
        }
    }

    private func displayTitle(for suggestion: AddressSuggestion) -> String {
        switch suggestion.kind {
        case .searchDefault:
            return String(localized: "Search in \(engineName) for '\(suggestion.title)'")
        default:
            return suggestion.title
        }
    }

    private func showsSubtitle(_ suggestion: AddressSuggestion) -> Bool {
        switch suggestion.kind {
        case .navigate, .bookmark, .history:
            return true
        case .searchDefault, .searchSuggestion:
            return false
        }
    }

    @ViewBuilder
    private func kindBadge(for suggestion: AddressSuggestion) -> some View {
        switch suggestion.kind {
        case .bookmark:
            Text("Bookmark")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(appAccent.opacity(0.12))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
        case .history:
            Text("History")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// 最近搜索段：**自己观察** SearchHistoryStore（父视图只持普通引用，
/// 不观察就不会因新增历史而重绘）。
private struct SearchHistorySection: View {
    @ObservedObject var store: SearchHistoryStore
    var onSelect: (String) -> Void

    var body: some View {
        let recent = store.entries.prefix(5).map { $0 }
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Recent Searches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Spacer()
                }
                Divider()
                ForEach(recent) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                        Text(entry.query)
                            .lineLimit(1)
                        Spacer()
                        Text(entry.engine)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(entry.query) }
                    if entry.id != recent.last?.id {
                        Divider()
                    }
                }
            }
        } else {
            EmptyView()
        }
    }
}
