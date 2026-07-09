import SwiftUI

struct AddressSuggestionsView: View {
    @ObservedObject var model: AddressSuggestionsModel
    var engineName: String
    var searchHistoryStore: SearchHistoryStore?
    var onSelect: (AddressSuggestion) -> Void
    var onSearchHistorySelect: ((String) -> Void)?

    @State private var showSearchHistory = false

    private var recentSearches: [SearchHistory] {
        guard let store = searchHistoryStore else { return [] }
        return store.entries.prefix(5).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !recentSearches.isEmpty && model.suggestions.isEmpty {
                searchHistorySection
            } else {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    row(for: suggestion, at: index)
                    if index < model.suggestions.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: .radiusPopover))
        .shadowElevated()
        .overlay(
            RoundedRectangle(cornerRadius: .radiusPopover)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var searchHistorySection: some View {
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
            ForEach(recentSearches) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                    Text(entry.query)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.engine.rawValue)
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
                .onTapGesture {
                    onSearchHistorySelect?(entry.query)
                }
                if entry.id != recentSearches.last?.id {
                    Divider()
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
        .background(index == model.selectedIndex ? Color.accentColor.opacity(0.15) : .clear)
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
                .background(Color.accentColor.opacity(0.12))
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
