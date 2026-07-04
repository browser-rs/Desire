import AppKit
import Combine
import SwiftUI

struct AddressSuggestion: Identifiable {
    enum Kind {
        case navigate
        case searchDefault
        case searchSuggestion
        case bookmark
        case history
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let url: String
    let domain: String?
}

@MainActor
class AddressSuggestionsModel: ObservableObject {
    @Published var suggestions: [AddressSuggestion] = []
    @Published var selectedIndex = 0

    private var searchTask: Task<Void, Never>?
    private let maxResults = 8

    var isEmpty: Bool { suggestions.isEmpty }

    func selected() -> AddressSuggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + suggestions.count) % suggestions.count
    }

    func reset() {
        searchTask?.cancel()
        suggestions = []
        selectedIndex = 0
    }

    func build(query: String,
               settings: Settings,
               bookmarks: BookmarkStore,
               history: HistoryStore) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }

        let q = trimmed.lowercased()
        var results: [AddressSuggestion] = []

        let resolved = Self.resolveDestination(input: trimmed, settings: settings)
        let looksLikeURL = resolved.hasPrefix("http")
        if looksLikeURL {
            results.append(AddressSuggestion(
                kind: .navigate,
                title: resolved,
                url: resolved,
                domain: FaviconStore.domainKey(from: resolved)
            ))
        } else {
            results.append(AddressSuggestion(
                kind: .searchDefault,
                title: trimmed,
                url: resolved,
                domain: nil
            ))
        }

        for b in bookmarks.bookmarks {
            if results.count >= maxResults { break }
            if b.title.lowercased().contains(q) || b.url.lowercased().contains(q) {
                results.append(AddressSuggestion(
                    kind: .bookmark,
                    title: b.title,
                    url: b.url,
                    domain: FaviconStore.domainKey(from: b.url)
                ))
            }
        }

        var seen = Set(results.map { $0.url })
        for h in history.entries {
            if results.count >= maxResults { break }
            if seen.contains(h.url) { continue }
            if h.title.lowercased().contains(q) || h.url.lowercased().contains(q) {
                seen.insert(h.url)
                results.append(AddressSuggestion(
                    kind: .history,
                    title: h.title,
                    url: h.url,
                    domain: FaviconStore.domainKey(from: h.url)
                ))
            }
        }

        suggestions = results
        selectedIndex = 0

        if settings.showSearchSuggestions && !looksLikeURL {
            let engine = settings.searchEngine
            let snapshot = trimmed
            let snapSettings = settings
            searchTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let sugs = await SearchSuggestionService.shared.suggestions(for: snapshot, engine: engine)
                guard !Task.isCancelled, let self else { return }

                guard let first = self.suggestions.first, first.title == snapshot else { return }

                var updated = self.suggestions
                var insertAt = 1
                for sug in sugs {
                    if updated.count >= self.maxResults { break }
                    let url = snapSettings.searchURLTemplate
                        + (sug.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sug)
                    guard !seen.contains(url) else { continue }
                    seen.insert(url)
                    updated.insert(
                        AddressSuggestion(kind: .searchSuggestion, title: sug, url: url, domain: nil),
                        at: insertAt
                    )
                    insertAt += 1
                }
                self.suggestions = updated
            }
        }
    }

    static func resolveDestination(input: String, settings: Settings) -> String {
        var text = input.trimmingCharacters(in: .whitespaces)
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            if text.contains(".") && !text.contains(" ") {
                text = "https://" + text
            } else {
                text = settings.searchURLTemplate
                    + (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)
            }
        }
        return text
    }
}

struct AddressSuggestionsView: View {
    @ObservedObject var model: AddressSuggestionsModel
    var engineName: String
    var onSelect: (AddressSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                row(for: suggestion, at: index)
                if index < model.suggestions.count - 1 {
                    Divider()
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
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
            return "在\(engineName)中搜索「\(suggestion.title)」"
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
            Text("书签")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
        case .history:
            Text("历史")
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
