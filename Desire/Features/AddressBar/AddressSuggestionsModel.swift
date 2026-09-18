import Combine
import Foundation

@MainActor
class AddressSuggestionsModel: ObservableObject {
    @Published var suggestions: [AddressSuggestion] = []
    @Published var selectedIndex = 0

    private var searchTask: Task<Void, Never>?
    private let maxResults = 8
    /// Query the currently published suggestion set was built for. Network
    /// suggestions compare against this on completion — if the user kept
    /// typing, the stale response is dropped (replaces the old brittle
    /// `first.title == snapshot` guard, which broke whenever the first row
    /// re-sorted).
    private var currentQuery: String?

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
        currentQuery = nil
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
        currentQuery = trimmed

        // Resolve through the SAME layer navigation uses, so what the first
        // row promises is exactly what Enter does.
        let destination = URLResolution.resolve(trimmed, settings: settings)

        var results: [AddressSuggestion] = []
        var isURL = false
        switch destination {
        case .url(let urlString):
            isURL = true
            results.append(AddressSuggestion(
                kind: .navigate,
                title: urlString,
                url: urlString,
                domain: FaviconStore.domainKey(from: urlString)
            ))
        case .search(let query, let target):
            if let urlString = URLResolution.searchURL(query: query, target: target)?.absoluteString {
                results.append(AddressSuggestion(
                    kind: .searchDefault,
                    title: query,
                    url: urlString,
                    domain: nil
                ))
            }
        case nil:
            suggestions = []
            selectedIndex = 0
            return
        }

        // Bookmarks and history, deduped across the whole list (the old
        // `seen` set only guarded the history loop, so duplicate bookmark
        // URLs could render twice — now also duplicate stable row ids).
        var seen = Set(results.map(\.url))
        for entry in bookmarks.leafEntries {
            if results.count >= maxResults { break }
            guard !entry.url.isEmpty, !seen.contains(entry.url) else { continue }
            if entry.titleLower.contains(trimmed.lowercased()) || entry.urlLower.contains(trimmed.lowercased()) {
                seen.insert(entry.url)
                results.append(AddressSuggestion(
                    kind: .bookmark,
                    title: entry.title,
                    url: entry.url,
                    domain: FaviconStore.domainKey(from: entry.url)
                ))
            }
        }

        for h in history.entries {
            if results.count >= maxResults { break }
            if seen.contains(h.url) { continue }
            if h.title.lowercased().contains(trimmed.lowercased()) || h.url.lowercased().contains(trimmed.lowercased()) {
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

        // Network suggestions only for search-shaped queries, only when the
        // user hasn't disabled suggestions, and only when the active engine
        // actually has a suggestion endpoint.
        guard !isURL, !results.isEmpty, settings.showSearchSuggestions,
              let suggestTemplate = settings.effectiveSuggestionURL else { return }

        let snapshotQuery = trimmed
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let sugs = await SearchSuggestionService.shared.suggestions(for: snapshotQuery, template: suggestTemplate)
            guard !Task.isCancelled, let self else { return }
            // The user kept typing while we were in flight — drop it.
            guard self.currentQuery == snapshotQuery else { return }

            var updated = self.suggestions
            var insertAt = 1
            for sug in sugs {
                if updated.count >= self.maxResults { break }
                let target = URLResolution.defaultTarget(settings)
                guard let url = URLResolution.searchURL(query: sug, target: target)?.absoluteString else { continue }
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
