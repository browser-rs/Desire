import AppKit
import Combine
import os
import SwiftUI
import WebKit

@MainActor
class Tab: ObservableObject {
    let id = UUID()
    let browser: BrowserState
    let isIncognito: Bool
    /// Container this tab belongs to (nil = default store). Fixed at tab
    /// creation — the data store is baked into the webview configuration.
    let containerID: UUID?
    @Published var urlString = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isOnNewTabPage = true
    @Published var displayTitle = "新标签页"
    @Published var isPinned = false
    @Published var isSuspended = false
    @Published var responsiveConfig = ResponsiveConfig()
    var lastAccessed = Date()
    var suppressHistoryOnce = false

    /// Snapshot captured *before* a tab is suspended. `loadHTMLString("")`
    /// destroys the live page (clears `webView.url`, DOM, scroll, form state),
    /// so we must save what's needed to restore it. `interactionState`
    /// preserves back/forward history + page state when available.
    var suspendedURL: URL?
    var suspendedTitle: String?
    var suspendedInteractionState: Data?

    /// Capture the current page state so it can survive suspension.
    /// Must be called *before* the page is blanked.
    func captureSuspendedState() {
        suspendedURL = browser.webView.url
        suspendedTitle = browser.webView.title
        if let state = browser.webView.interactionState {
            suspendedInteractionState = try? NSKeyedArchiver.archivedData(
                withRootObject: state,
                requiringSecureCoding: true
            )
        }
    }

    /// Restore the page after suspension. Prefers `interactionState` (keeps
    /// scroll position, form input, JS state, and back/forward history); falls
    /// back to a plain URL reload if no snapshot was captured.
    func restoreSuspendedState() {
        if let data = suspendedInteractionState {
            do {
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
                unarchiver.requiresSecureCoding = true
                let state = unarchiver.decodeObject(of: [NSData.self], forKey: NSKeyedArchiveRootObjectKey)
                if let state {
                    browser.webView.interactionState = state
                    suspendedURL = nil
                    suspendedTitle = nil
                    suspendedInteractionState = nil
                    return
                }
            } catch {
                // Decoding failed — fall through to URL reload below.
            }
        }
        if let url = suspendedURL ?? browser.webView.url {
            browser.webView.load(URLRequest(url: url))
        } else if let url = URL(string: urlString) {
            browser.webView.load(URLRequest(url: url))
        }
        suspendedURL = nil
        suspendedTitle = nil
        suspendedInteractionState = nil
    }

    private var cancellables = Set<AnyCancellable>()

    /// 音频静音状态（通过 BrowserState 控制）
    var audioMuted: Bool {
        get { browser.isMuted }
        set {
            browser.isMuted = newValue
            let js = newValue
                ? "document.querySelectorAll('audio, video').forEach(e => e.muted = true)"
                : "document.querySelectorAll('audio, video').forEach(e => e.muted = false)"
            browser.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// 是否正在播放音频
    var isPlayingAudio: Bool {
        browser.isPlayingAudio
    }

    init(url: String? = nil, incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlockerStore? = nil, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction, containerID: UUID? = nil) {
        self.isIncognito = incognito
        self.containerID = containerID
        browser = BrowserState(incognito: incognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: autoPlayPolicy, containerDataStore: containerID.flatMap { ContainerStore.shared.dataStore(for: $0) })
        browser.webView.allowsBackForwardNavigationGestures = true
        if let url {
            urlString = url
            isOnNewTabPage = false
            // 立即加载 URL，确保新标签页能够正确显示内容
            if let validURL = URL(string: url) {
                browser.webView.load(URLRequest(url: validURL))
            }
        }
        browser.$pageTitle
            .sink { [weak self] title in
                self?.displayTitle = title
            }
            .store(in: &cancellables)
        browser.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}

@MainActor
class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedIndex = 0
    /// Called when the user closes the last tab — the owning window should
    /// close itself rather than leaving an empty tab bar.
    var onRequestWindowClose: (() -> Void)?
    /// A closed tab's identity for reopen. URL alone loses incognito and
    /// container context — a private tab resurrected as a normal one would
    /// leak its navigation into the persistent cookie store and disk history.
    struct RecentlyClosedTab {
        let url: String
        let isIncognito: Bool
        let containerID: UUID?
    }

    private var recentlyClosed: [RecentlyClosedTab] = []

    /// Records a tab for ⌘⇧T before teardown. webView.url is nil for
    /// suspended tabs (the live page was blanked) — fall back to the tab's
    /// stored URL so every close path records.
    private func recordClosed(_ tab: Tab) {
        let url = tab.browser.webView.url?.absoluteString ?? tab.urlString
        guard !url.isEmpty else { return }
        recentlyClosed.append(RecentlyClosedTab(
            url: url, isIncognito: tab.isIncognito, containerID: tab.containerID
        ))
        if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
    }
    private var suspendTimer: Timer?
    /// Set by a DispatchSourceMemoryPressure event; consumed by the next
    /// suspendIdleTabs sweep to suspend additional LRU background tabs.
    var memoryPressureActive = false
    /// Per-window session storage key (set by ContentView once the window's
    /// value-based session UUID is known). Nil until then: persistence and
    /// restore are no-ops for unkeyed windows.
    var sessionKey: String?

    init() {
        // Session persistence is process-wide (one shared storage key): each
        // window's TabManager registers with the coordinator instead of
        // running its own timer — the per-window timers used to overwrite
        // the shared key and destroy every other window's tabs.
        TabSessionCoordinator.shared.register(self)
        startSuspendTimer()
        startMemoryPressureMonitor()
    }

    /// System memory pressure events set `memoryPressureActive` so the next
    /// suspend sweep suspends LRU background tabs beyond the time threshold.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: .warning, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.memoryPressureActive = true
                Log.tabs.info("memory pressure event received")
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    deinit {
        suspendTimer?.invalidate()
    }

    func startSuspendTimer() {
        suspendTimer?.invalidate()
        suspendTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.suspendIdleTabs()
            }
        }
    }

    func stopSuspendTimer() {
        suspendTimer?.invalidate()
        suspendTimer = nil
    }

    /// Suspend idle tabs to save battery and memory.
    /// When a tab is suspended, its WKWebView content is unloaded but
    /// the view is kept so it can be restored quickly.
    private func suspendIdleTabs() {
        let configured = UserDefaults.standard.double(forKey: "suspendAfterMinutes")
        guard configured >= 0 else { return }
        let actualThreshold = configured > 0 ? configured * 60 : 30 * 60

        for tab in tabs where tab.id != selectedTab?.id && !tab.isPinned && !tab.isOnNewTabPage && !tab.isIncognito {
            if -tab.lastAccessed.timeIntervalSinceNow > actualThreshold {
                if !tab.isSuspended {
                    tab.captureSuspendedState()
                    tab.isSuspended = true
                    tab.browser.webView.stopLoading()
                    tab.browser.webView.loadHTMLString("", baseURL: nil)
                }
            }
        }

        // Memory watermark: suspend LRU background tabs when the system
        // reports memory pressure. Exemptions: selected, pinned, incognito,
        // playing audio.
        if memoryPressureActive {
            let candidates = tabs
                .filter { $0.id != selectedTab?.id && !$0.isPinned && !$0.isOnNewTabPage
                    && !$0.isIncognito && !$0.isSuspended && !$0.isPlayingAudio }
                .sorted { $0.lastAccessed < $1.lastAccessed }
            for tab in candidates {
                tab.captureSuspendedState()
                tab.isSuspended = true
                tab.browser.webView.stopLoading()
                tab.browser.webView.loadHTMLString("", baseURL: nil)
                Log.tabs.info("memory watermark: suspended '\(tab.displayTitle, privacy: .public)'")
            }
        }
    }

    func suspendAllBackgroundTabs() {
        for tab in tabs where tab.id != selectedTab?.id && !tab.isPinned && !tab.isIncognito {
            if !tab.isSuspended {
                tab.captureSuspendedState()
                tab.isSuspended = true
                tab.browser.webView.stopLoading()
                tab.browser.webView.loadHTMLString("", baseURL: nil)
            }
        }
    }

    private func unsuspend(_ tab: Tab) {
        guard tab.isSuspended else { return }
        tab.isSuspended = false
        tab.restoreSuspendedState()
    }

    var selectedTab: Tab? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    func addTab(url: String? = nil, incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlockerStore? = nil, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction, newTabPosition: NewTabPosition = .end, containerID: UUID? = nil) {
        let tab = Tab(url: url, incognito: incognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: autoPlayPolicy, containerID: containerID)
        defer { BridgeEventBus.shared.publish("tabOpened", ["index": tabs.firstIndex(where: { $0.id == tab.id }) ?? -1, "count": tabs.count]) }
        switch newTabPosition {
        case .end:
            tabs.append(tab)
            selectedIndex = tabs.count - 1
        case .afterCurrent:
            let insertIndex = min(selectedIndex + 1, tabs.count)
            tabs.insert(tab, at: insertIndex)
            selectedIndex = insertIndex
        }
        persistSession()
    }

    func duplicateTab(at index: Int, javaScriptEnabled: Bool, contentBlocker: ContentBlockerStore?, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction) {
        guard tabs.indices.contains(index) else { return }
        let source = tabs[index]
        let url = source.browser.webView.url?.absoluteString ?? (source.isOnNewTabPage ? nil : source.urlString)
        let newTab = Tab(url: url, incognito: source.isIncognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: autoPlayPolicy, containerID: source.containerID)
        newTab.isPinned = source.isPinned
        tabs.insert(newTab, at: index + 1)
        selectedIndex = index + 1
        persistSession()
    }

    // MARK: - 跨窗口迁移（拖出/拖回）

    /// Removes a tab WITHOUT tearing it down — the Tab (and its live
    /// BrowserState/webview) is transferred to another window's manager.
    /// Not recorded in recentlyClosed (it isn't a close).
    func moveOut(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if selectedIndex >= tabs.count {
            selectedIndex = max(0, tabs.count - 1)
        }
        persistSession()
    }

    /// Adopts a tab transferred from another window (appended + selected).
    func absorb(_ tab: Tab) {
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        persistSession()
    }

    /// Adopts a transferred tab at a specific index.
    func insert(_ tab: Tab, at index: Int) {
        let idx = min(max(0, index), tabs.count)
        tabs.insert(tab, at: idx)
        persistSession()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Closing the last tab closes the window instead of leaving an
        // empty tab strip (matches expected macOS browser UX).
        if tabs.count <= 1 {
            onRequestWindowClose?()
            return
        }
        let tab = tabs[index]
        recordClosed(tab)
        tearDown(tab)
        tabs.remove(at: index)
        defer { BridgeEventBus.shared.publish("tabClosed", ["closedId": tab.id.uuidString, "count": tabs.count]) }
        if selectedIndex >= tabs.count {
            selectedIndex = tabs.count - 1
        }
        persistSession()
    }

    @discardableResult
    func reopenLastClosedTab(javaScriptEnabled: Bool, contentBlocker: ContentBlockerStore?, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction) -> Bool {
        guard let record = recentlyClosed.popLast() else { return false }
        addTab(url: record.url, incognito: record.isIncognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: autoPlayPolicy, containerID: record.containerID)
        return true
    }

    func closeOthers(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let kept = tabs[index]
        for tab in tabs where tab.id != kept.id {
            recordClosed(tab)
            tearDown(tab)
        }
        tabs = [kept]
        selectedIndex = 0
        persistSession()
    }

    func closeToTheRight(of index: Int) {
        guard tabs.indices.contains(index) else { return }
        let toRemove = Array(tabs[(index + 1)...])
        for tab in toRemove {
            recordClosed(tab)
            tearDown(tab)
        }
        tabs = Array(tabs.prefix(index + 1))
        if selectedIndex > index { selectedIndex = index }
        persistSession()
    }

    /// Releases the tab's WKWebView resources so it can be deallocated
    /// promptly under tab churn. Without this the webview is only freed
    /// when the `Tab` itself deinits, which can lag behind close.
    private func tearDown(_ tab: Tab) {
        tab.browser.webView.stopLoading()
        tab.browser.webView.uiDelegate = nil
        tab.browser.webView.navigationDelegate = nil
    }

    func moveTab(from source: Int, to target: Int) {
        guard tabs.indices.contains(source),
              tabs.indices.contains(target),
              source != target else { return }
        let movedTab = tabs.remove(at: source)
        let insertIndex = source < target ? target - 1 : target
        tabs.insert(movedTab, at: min(insertIndex, tabs.count))

        if selectedIndex == source {
            selectedIndex = insertIndex
        } else {
            var sel = selectedIndex
            if source < sel { sel -= 1 }
            if insertIndex <= sel { sel += 1 }
            selectedIndex = sel
        }
        persistSession()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        persistSession()
        selectedIndex = index
        tabs[index].lastAccessed = Date()
        if tabs[index].isSuspended {
            unsuspend(tabs[index])
        }
    }

    // MARK: - Session persistence

    /// Legacy UserDefaults key — read once during migration, then deleted.
    /// The live key lives on `TabSessionCoordinator.storageKey`.
    private let legacySessionKey = "desire.session"

    /// Cached per-tab session archives. Archiving `interactionState` runs
    /// on the main thread; without the fingerprint check the 15s session
    /// timer re-archived EVERY tab on EVERY tick even when nothing changed
    /// (a heavy page costs tens of ms per archive).
    private struct SessionArchive {
        let url: String?
        let title: String?
        let historyCount: Int
        let data: Data?
    }
    private var sessionArchives: [UUID: SessionArchive] = [:]

    // MARK: - Session persistence

    /// Persists THIS window's tabs under its own session key via
    /// `TabSessionCoordinator`. No-op until the window is keyed.
    func persistSession(force: Bool = false) {
        guard let sessionKey else { return }
        TabSessionCoordinator.shared.persistWindow(self, key: sessionKey, force: force)
    }

    /// Appends this window's non-incognito tabs to the merged session blob.
    /// Called by the coordinator for every registered window. `fileprivate`
    /// because `SavedTab` is a private type co-located with the coordinator.
    fileprivate func appendSessionTabs(into savedTabs: inout [SavedTab], force: Bool) {
        for tab in tabs where !tab.isIncognito {
            // For a suspended tab the live webview has been blanked, so use
            // the snapshot captured at suspend time. Otherwise `webView.url`
            // is nil and `interactionState` encodes an empty page, which
            // corrupted sessions and produced blank tabs on app restart.
            if tab.isSuspended {
                if let url = tab.suspendedURL?.absoluteString, !url.isEmpty {
                    savedTabs.append(SavedTab(tabID: tab.id, url: url, isOnNewTabPage: false, isPinned: tab.isPinned, sessionState: tab.suspendedInteractionState, containerID: tab.containerID))
                } else if tab.isOnNewTabPage {
                    savedTabs.append(SavedTab(tabID: tab.id, url: nil, isOnNewTabPage: true, isPinned: tab.isPinned, sessionState: nil, containerID: tab.containerID))
                } else if tab.urlString.hasPrefix("http") {
                    savedTabs.append(SavedTab(tabID: tab.id, url: tab.urlString, isOnNewTabPage: false, isPinned: tab.isPinned, sessionState: tab.suspendedInteractionState, containerID: tab.containerID))
                }
                continue
            }

            let stateData = force
                ? captureInteractionState(for: tab)
                : cachedOrCapturedInteractionState(for: tab)
            if let url = tab.browser.webView.url?.absoluteString, !url.isEmpty {
                savedTabs.append(SavedTab(tabID: tab.id, url: url, isOnNewTabPage: false, isPinned: tab.isPinned, sessionState: stateData, containerID: tab.containerID))
            } else if tab.isOnNewTabPage {
                savedTabs.append(SavedTab(tabID: tab.id, url: nil, isOnNewTabPage: true, isPinned: tab.isPinned, sessionState: nil, containerID: tab.containerID))
            } else if tab.urlString.hasPrefix("http"), let u = URL(string: tab.urlString) {
                savedTabs.append(SavedTab(tabID: tab.id, url: u.absoluteString, isOnNewTabPage: false, isPinned: tab.isPinned, sessionState: stateData, containerID: tab.containerID))
            }
        }
        // Drop archive entries for closed tabs.
        let liveIds = Set(tabs.map(\.id))
        sessionArchives = sessionArchives.filter { liveIds.contains($0.key) }
    }

    /// Returns the cached archive when the tab's fingerprint (url/title/
    /// history depth) is unchanged; otherwise archives and refreshes it.
    private func cachedOrCapturedInteractionState(for tab: Tab) -> Data? {
        let wv = tab.browser.webView
        let url = wv.url?.absoluteString
        let title = wv.title
        let historyCount = wv.backForwardList.backList.count + wv.backForwardList.forwardList.count
        if let cached = sessionArchives[tab.id],
           cached.url == url, cached.title == title, cached.historyCount == historyCount {
            return cached.data
        }
        let data = captureInteractionState(for: tab)
        sessionArchives[tab.id] = SessionArchive(url: url, title: title, historyCount: historyCount, data: data)
        return data
    }

    private func captureInteractionState(for tab: Tab) -> Data? {
        guard let state = tab.browser.webView.interactionState else { return nil }
        // 使用 NSSecureCoding 编码，与解码保持一致
        return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
    }

    /// Restores this window's tabs from its per-window session file.
    /// Returns false when the file is absent/corrupt — callers fall back to
    /// legacy adoption or a fresh tab.
    @discardableResult
    func restoreSession(forKey key: String, javaScriptEnabled: Bool, contentBlocker: ContentBlockerStore?, videoAdBlocker: VideoAdBlocker? = nil) -> Bool {
        guard let session = DiskStore.load(SavedSession.self, key: key) else { return false }
        apply(session: session, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker)
        return true
    }

    /// Rebuilds tabs from a decoded session (per-window restore and legacy
    /// adoption share this path).
    func apply(session: SavedSession, javaScriptEnabled: Bool, contentBlocker: ContentBlockerStore?, videoAdBlocker: VideoAdBlocker? = nil) {
        tabs = []

        for saved in session.tabs {
            let url = saved.isOnNewTabPage ? nil : saved.url
            let tab = Tab(url: url, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, containerID: saved.containerID)
            tab.isPinned = saved.isPinned

            var restoredInteractionState = false
            if let data = saved.sessionState {
                // NSSecureCoding 解码：根对象实证为 NSData（WebKit 把
                // interactionState 归档为数据块），允许列表据此收窄。
                do {
                    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
                    unarchiver.requiresSecureCoding = true
                    let state = unarchiver.decodeObject(of: [NSData.self], forKey: NSKeyedArchiveRootObjectKey)
                    if let state = state {
                        Log.storage.info("interactionState decoded type: \(String(describing: type(of: state)), privacy: .public)")
                        tab.browser.webView.interactionState = state
                        restoredInteractionState = true
                    }
                } catch {
                    // 解码失败，忽略状态恢复
                }
            }

            tabs.append(tab)
            // When interactionState restored, it already carries the page +
            // history: a fresh load here would CANCEL the restoration and
            // reduce the tab to a bare URL load (scroll/session state lost).
            if !restoredInteractionState, !saved.isOnNewTabPage, let urlString = saved.url, let parsed = URL(string: urlString) {
                tab.suppressHistoryOnce = true
                tab.browser.webView.load(URLRequest(url: parsed))
            }
        }

        selectedIndex = min(session.selectedIndex, max(0, tabs.count - 1))
    }
}

struct SavedTab: Codable {
    /// In-memory only: maps the ACTIVE window's selected tab to its position
    /// in the merged multi-window list. Deliberately excluded from Codable —
    /// the on-disk shape is unchanged (old session files still decode).
    let tabID: UUID
    let url: String?
    let isOnNewTabPage: Bool
    var isPinned: Bool
    let sessionState: Data?
    let containerID: UUID?

    init(tabID: UUID, url: String?, isOnNewTabPage: Bool, isPinned: Bool, sessionState: Data?, containerID: UUID? = nil) {
        self.tabID = tabID
        self.url = url
        self.isOnNewTabPage = isOnNewTabPage
        self.isPinned = isPinned
        self.sessionState = sessionState
        self.containerID = containerID
    }

    enum CodingKeys: String, CodingKey {
        case url, isOnNewTabPage, isPinned, sessionState, containerID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = UUID()
        url = try container.decodeIfPresent(String.self, forKey: .url)
        isOnNewTabPage = try container.decode(Bool.self, forKey: .isOnNewTabPage)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sessionState = try container.decodeIfPresent(Data.self, forKey: .sessionState)
        containerID = try container.decodeIfPresent(UUID.self, forKey: .containerID)
    }
}

/// Internal: `ContentView` triggers legacy adoption which hands a decoded
/// `SavedSession` back across files.
struct SavedSession: Codable {
    let tabs: [SavedTab]
    let selectedIndex: Int
}

/// Process-wide owner of tab-session persistence.
///
/// Sessions are stored PER WINDOW under `session-<uuid>.json`, where the
/// uuid rides the window itself via a value-based WindowGroup — so multiple
/// windows no longer overwrite each other's tabs, and each window restores
/// its own set after relaunch. A single coordinator owns the 15s timer and
/// the termination hook; `applicationShouldTerminate` force-persists every
/// live window and writes the session index, and the first window of the
/// next launch prunes sessions whose windows were closed since.
///
/// One-time legacy adoption: the pre-multiwindow merged session ("session"
/// key) is offered to the first window that has no own session file.
@MainActor
final class TabSessionCoordinator {
    static let shared = TabSessionCoordinator()
    static let legacyStorageKey = "session"
    static let indexKey = "session-index"
    static let archiveIndexKey = "session-archive-index"

    private struct WeakManager { weak var manager: TabManager? }
    private var managers: [WeakManager] = []
    private var activeManager: TabManager?
    private var timer: Timer?
    private var isTerminating = false

    func sessionKey(for id: UUID) -> String { "session-" + id.uuidString }

    /// 按窗口会话 UUID 查找 TabManager（跨窗口标签迁移用）。
    func manager(forSession sessionID: UUID) -> TabManager? {
        let key = sessionKey(for: sessionID)
        managers.removeAll { $0.manager == nil }
        return managers.first(where: { $0.manager?.sessionKey == key })?.manager
    }

    func register(_ manager: TabManager) {
        managers.removeAll { $0.manager == nil }
        guard !managers.contains(where: { $0.manager === manager }) else { return }
        managers.append(WeakManager(manager: manager))
        startTimerIfNeeded()
    }

    /// Called when a window becomes key so the recorded selection follows
    /// the window the user is actually looking at.
    func setActive(_ manager: TabManager) {
        activeManager = manager
    }

    /// The active window's TabManager — read by the automation server.
    var activeTabManager: TabManager? { activeManager }

    /// Persists ONE window's tabs under its own key.
    func persistWindow(_ manager: TabManager, key: String, force: Bool) {
        var savedTabs: [SavedTab] = []
        manager.appendSessionTabs(into: &savedTabs, force: force)
        guard !savedTabs.isEmpty else {
            DiskStore.remove(key: key)
            return
        }
        let session = SavedSession(tabs: savedTabs, selectedIndex: manager.selectedIndex)
        DiskStore.save(session, key: key)
    }

    /// Persists every registered window (15s timer / willTerminate).
    func persistAll(force: Bool) {
        managers.removeAll { $0.manager == nil }
        for box in managers {
            guard let manager = box.manager, let key = manager.sessionKey else { continue }
            persistWindow(manager, key: key, force: force)
        }
    }

    /// Called from applicationShouldTerminate — windows are still open here.
    /// Force-persists every window, records the live session index, and
    /// flushes the DiskStore debounce queue synchronously.
    func prepareForTermination() {
        isTerminating = true
        persistAll(force: true)
        let keys = managers.compactMap { $0.manager?.sessionKey }
        DiskStore.save(keys, key: Self.indexKey)
        DiskStore.flushSync()
    }

    /// Moves session files whose windows were closed since the last
    /// termination into an archive (newest 5 kept) instead of deleting them
    /// — a wrongly-pruned session would be unrecoverable. No-op when the
    /// index is missing (crash before quit — keep everything rather than
    /// guess).
    func pruneOrphanSessions(keeping keep: Set<String>) {
        guard let index: [String] = DiskStore.load([String].self, key: Self.indexKey) else { return }
        var archived: [String] = DiskStore.load([String].self, key: Self.archiveIndexKey) ?? []
        let fm = FileManager.default
        for key in index where !keep.contains(key) {
            let source = DiskStore.directory.appendingPathComponent("\(key).json")
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.createDirectory(at: Self.archiveDirectory, withIntermediateDirectories: true)
            let name = "archived-\(key)-\(Int(Date().timeIntervalSince1970)).json"
            try? fm.moveItem(at: source, to: Self.archiveDirectory.appendingPathComponent(name))
            archived.append(name)
        }
        while archived.count > 5 {
            let oldest = archived.removeFirst()
            try? fm.removeItem(at: Self.archiveDirectory.appendingPathComponent(oldest))
        }
        DiskStore.save(archived, key: Self.archiveIndexKey)
        DiskStore.remove(key: Self.indexKey)
    }

    nonisolated static var archiveDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Desire", isDirectory: true)
            .appendingPathComponent("session-archives", isDirectory: true)
    }

    /// One-time adoption of the pre-multiwindow merged session; removes the
    /// legacy key so it can't be adopted twice.
    func takeLegacySession() -> SavedSession? {
        guard let session = DiskStore.load(SavedSession.self, key: Self.legacyStorageKey) else { return nil }
        DiskStore.remove(key: Self.legacyStorageKey)
        return session
    }

    /// The most recent session key from the last clean termination's index —
    /// the "continue where you left off" candidate for a freshly launched
    /// first window (whose own window-value restoration never happens on
    /// macOS 26; see ContentView's adoption path).
    func mostRecentSessionKey() -> String? {
        guard let index: [String] = DiskStore.load([String].self, key: Self.indexKey) else { return nil }
        return index.last
    }

    /// Loads a stored session without consuming it.
    func session(forKey key: String) -> SavedSession? {
        DiskStore.load(SavedSession.self, key: key)
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.persistAll(force: false)
            }
        }
        // Belt and suspenders: applicationShouldTerminate already prepared
        // termination; willTerminate re-persists (idempotent) and flushes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                TabSessionCoordinator.shared.prepareForTermination()
            }
        }
    }
}

