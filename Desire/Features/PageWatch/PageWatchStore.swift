import Combine
import Foundation
import os
@preconcurrency import UserNotifications
import WebKit

/// Store + engine for page watches (0.1.10). A 20 s clock fires due
/// watches; each check loads the URL in an offscreen webview, extracts
/// normalized text, and diffs it against the previous snapshot. Changes
/// update the watch, post a system notification, and publish a
/// `pageWatchChanged` bridge event.
@MainActor
final class PageWatchStore: ObservableObject {
    static let shared = PageWatchStore()

    @Published private(set) var watches: [PageWatch] = []
    @Published private(set) var isChecking = false

    private var clock: Timer?
    private var offscreenWebView: WKWebView?
    private static let log = Log.agent
    private static let storageKey = "page-watches"
    private static let maxTextLength = 20_000

    private init() {
        watches = DiskStore.load([PageWatch].self, key: Self.storageKey) ?? []
        startClock()
    }

    private func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
    }

    // MARK: - Management

    @discardableResult
    func add(name: String, url: String, selector: String?, minutes: Int) -> PageWatch? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty, let parsed = URL(string: trimmedURL) else { return nil }
        let watch = PageWatch(
            id: UUID(), name: trimmedName, url: parsed.absoluteString,
            selector: selector?.isEmpty == true ? nil : selector,
            intervalMinutes: max(5, minutes), isEnabled: true, createdAt: Date(),
            lastCheckedAt: nil, lastChangedAt: nil, previousText: nil,
            changeCount: 0, lastError: nil
        )
        watches.append(watch)
        save()
        return watch
    }

    func remove(named name: String) -> Bool {
        let before = watches.count
        watches.removeAll { $0.name.lowercased() == name.lowercased() }
        let removed = watches.count < before
        if removed { save() }
        return removed
    }

    func setEnabled(_ enabled: Bool, for name: String) {
        guard let idx = watches.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        watches[idx].isEnabled = enabled
        save()
    }

    func find(named name: String) -> PageWatch? {
        watches.first { $0.name.lowercased() == name.lowercased() }
    }

    private func save() {
        DiskStore.save(watches, key: Self.storageKey)
    }

    // MARK: - Checks

    /// Fires every due, enabled watch — serialized (the offscreen webview
    /// is shared).
    private func evaluate() {
        guard !isChecking else { return }
        for idx in watches.indices where watches[idx].isEnabled {
            let watch = watches[idx]
            let last = watch.lastCheckedAt ?? watch.createdAt
            let due = Date().timeIntervalSince(last) >= Double(watch.intervalMinutes) * 60
            if due {
                Task { [weak self] in
                    _ = await self?.check(named: watch.name)
                }
                return // one check per clock tick; the rest run next tick
            }
        }
    }

    /// Forces a check now. Returns whether the content CHANGED relative to
    /// the previous snapshot (first check establishes the baseline).
    @discardableResult
    func check(named name: String) async -> Bool {
        guard let idx = watches.firstIndex(where: { $0.name.lowercased() == name.lowercased() }),
              watches[idx].isEnabled else { return false }
        guard !isChecking else {
            Self.log.info("page watch: check skipped, another check is running")
            return false
        }
        isChecking = true
        defer { isChecking = false }

        let watch = watches[idx]
        do {
            let text = try await fetchText(url: URL(string: watch.url)!, selector: watch.selector)
            let normalized = normalize(text)
            watches[idx].lastCheckedAt = Date()
            watches[idx].lastError = nil

            let baseline = watch.previousText
            let changed = baseline != nil && baseline != normalized
            if changed {
                watches[idx].changeCount += 1
                watches[idx].lastChangedAt = Date()
                watches[idx].previousText = String(normalized.prefix(Self.maxTextLength))
                let diff = "chars \(baseline?.count ?? 0) → \(normalized.count)"
                save()
                notifyChange(watch: watches[idx], diff: diff)
                BridgeEventBus.shared.publish("pageWatchChanged", [
                    "name": watches[idx].name,
                    "url": watches[idx].url,
                    "changeCount": watches[idx].changeCount,
                    "diff": diff,
                ])
            } else if baseline == nil {
                watches[idx].previousText = String(normalized.prefix(Self.maxTextLength))
                save()
            } else {
                save()
            }
            return changed
        } catch {
            watches[idx].lastCheckedAt = Date()
            watches[idx].lastError = error.localizedDescription
            save()
            Self.log.error("page watch '\(watch.name, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Whitespace-collapsed comparison key.
    private func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: "\n")
            .replacingOccurrences(of: "\r", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Offscreen fetch

    private func offscreenWebview() -> WKWebView {
        if let offscreenWebView { return offscreenWebView }
        let webview = WKWebView(frame: .zero)
        self.offscreenWebView = webview
        return webview
    }

    private func fetchText(url: URL, selector: String?) async throws -> String {
        let webview = offscreenWebview()
        webview.load(URLRequest(url: url))
        // Poll isLoading: up to 12 s.
        for _ in 0..<120 {
            if !webview.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300)) // let late JS render
        let js: String
        if let selector, !selector.isEmpty {
            let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            js = """
            (function(){
              var el = document.querySelector('\(escaped)');
              return el ? (el.innerText || el.textContent || '') : '__NO_MATCH__';
            })()
            """
        } else {
            js = "document.body ? document.body.innerText : ''"
        }
        let result: Any = await withCheckedContinuation { continuation in
            webview.evaluateJavaScript(js) { value, _ in
                continuation.resume(returning: value ?? "")
            }
        }
        let text = result as? String ?? ""
        if text == "__NO_MATCH__" {
            throw WatchError.selectorNotFound(selector ?? "")
        }
        return text
    }

    enum WatchError: LocalizedError {
        case selectorNotFound(String)
        var errorDescription: String? {
            switch self {
            case .selectorNotFound(let selector): return "selector not found: \(selector)"
            }
        }
    }

    // MARK: - Notification

    private func notifyChange(watch: PageWatch, diff: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Page changed")
            content.body = "\(watch.name) (\(diff))"
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
