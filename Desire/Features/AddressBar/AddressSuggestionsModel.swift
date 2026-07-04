import Combine
import Foundation

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
