import AppKit
import Combine
import Foundation

@MainActor
class AddressSuggestionsModel: ObservableObject {
    @Published var suggestions: [AddressSuggestion] = []
    @Published var selectedIndex = 0

    private var searchTask: Task<Void, Never>?

    /// Returns the pasteboard string as a URL when it looks like one.
    /// R2-12：pasteboard 读取是跨进程 IPC，此前**每个击键**一次。2s 缓存窗口
    /// （用户复制新链接后最多 2s 才进入候选，可接受）。
    private static var clipboardCache: (value: String?, at: Date)?
    private static func clipboardURL() -> String? {
        if let clipboardCache, Date().timeIntervalSince(clipboardCache.at) < 2 {
            return clipboardCache.value
        }
        let value = readClipboardURL()
        clipboardCache = (value, Date())
        return value
    }

    private static func readClipboardURL() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.contains("."),
              text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, options: .regularExpression) != nil
              || text.range(of: #"^www\."#, options: .regularExpression) != nil
              || text.range(of: #"^\d{1,3}\.\d{1,3}\."#, options: .regularExpression) != nil else {
            return nil
        }
        return text
    }
    private let maxResults = 8
    /// Query the currently published suggestion set was built for. Network
    /// suggestions compare against this on completion — if the user kept
    /// typing, the stale response is dropped (replaces the old brittle
    /// `first.title == snapshot` guard, which broke whenever the first row
    /// re-sorted).
    /// 当前建议列表对应的查询词（P1-7：提交侧校验候选归属用——100ms 防抖
    /// 窗口内回车，列表还是上一次击键的代次）。
    private(set) var currentQuery: String?

    /// P1-7：候选列表是否对应当前输入（防抖窗口内回车防旧代次提交）。
    func ownsCurrentInput(from text: String) -> Bool {
        currentQuery == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    /// R2-12：本地扫描防抖任务（此前每击键同步全量扫描 500 条历史 + 书签）。
    private var localDebounceTask: Task<Void, Never>?

    func build(query: String,
               settings: Settings,
               bookmarks: BookmarkStore,
               history: HistoryStore) {
        searchTask?.cancel()
        localDebounceTask?.cancel()
        localDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.buildImmediate(query: query, settings: settings, bookmarks: bookmarks, history: history)
        }
    }

    /// 100ms 防抖后的实际构建（原 build 体）。桥端点（无击键时序）直接调
    /// 这一个同步入口。
    func buildImmediate(query: String,
                                settings: Settings,
                                bookmarks: BookmarkStore,
                                history: HistoryStore) {
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

        // R2-12（功能性）：剪贴板候选的插入必须发生在 `suggestions = results`
        // **之前**——值类型赋值触发 COW 拷贝，此后改 `results` 不会出现在已发布
        // 的数组里（剪贴板候选只有等网络建议回填才"偶尔出现"的根因）。
        if !isURL, let clipboardURL = Self.clipboardURL(), clipboardURL != trimmed {
            results.insert(AddressSuggestion(
                kind: .navigate,
                title: String(localized: "Open clipboard link"),
                url: clipboardURL,
                domain: FaviconStore.domainKey(from: clipboardURL)
            ), at: 1)
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
