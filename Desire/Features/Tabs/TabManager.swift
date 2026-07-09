import Combine
import SwiftUI
import WebKit

@MainActor
class Tab: ObservableObject {
    let id = UUID()
    let browser: BrowserState
    let isIncognito: Bool
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

    init(url: String? = nil, incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlocker? = nil, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction) {
        self.isIncognito = incognito
        browser = BrowserState(incognito: incognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: autoPlayPolicy)
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
    private var tabCancellables: [UUID: AnyCancellable] = [:]
    private var recentlyClosedURLs: [String] = []
    private var suspendTimer: Timer?
    private var sessionSaveTimer: Timer?

    init() {
        startSessionSaveTimer()
        startSuspendTimer()
    }

    deinit {
        suspendTimer?.invalidate()
        sessionSaveTimer?.invalidate()
    }

    private func startSessionSaveTimer() {
        sessionSaveTimer?.invalidate()
        sessionSaveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.persistSession()
            }
        }
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
        // Use AppStorage for user-configurable threshold
        let threshold: TimeInterval = UserDefaults.standard.double(forKey: "suspendAfterMinutes") * 60
        let defaultThreshold: TimeInterval = 30 * 60
        let actualThreshold = threshold > 0 ? threshold : defaultThreshold

        for tab in tabs where tab.id != selectedTab?.id && !tab.isPinned && !tab.isOnNewTabPage && !tab.isIncognito {
            if -tab.lastAccessed.timeIntervalSinceNow > actualThreshold {
                // Only suspend if not already suspended
                if !tab.isSuspended {
                    tab.isSuspended = true
                    // Stop loading and clear content to save memory/battery
                    tab.browser.webView.stopLoading()
                    tab.browser.webView.loadHTMLString("", baseURL: nil)
                }
            }
        }
    }

    /// Immediately suspend all tabs except the selected one (for memory pressure)
    func suspendAllBackgroundTabs() {
        for tab in tabs where tab.id != selectedTab?.id && !tab.isPinned && !tab.isIncognito {
            if !tab.isSuspended {
                tab.isSuspended = true
                tab.browser.webView.stopLoading()
                tab.browser.webView.loadHTMLString("", baseURL: nil)
            }
        }
    }

    private func unsuspend(_ tab: Tab) {
        guard tab.isSuspended else { return }
        tab.isSuspended = false
        if let url = tab.browser.webView.url {
            tab.browser.webView.load(URLRequest(url: url))
        } else if let url = URL(string: tab.urlString) {
            tab.browser.webView.load(URLRequest(url: url))
        }
    }

    var selectedTab: Tab? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    func addTab(url: String? = nil, incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlocker? = nil, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction, newTabPosition: NewTabPosition = .end) {
        let tab = Tab(url: url, incognito: incognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: autoPlayPolicy)
        tabCancellables[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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

    func duplicateTab(at index: Int, javaScriptEnabled: Bool, contentBlocker: ContentBlocker?, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction) {
        guard tabs.indices.contains(index) else { return }
        let source = tabs[index]
        let url = source.browser.webView.url?.absoluteString ?? (source.isOnNewTabPage ? nil : source.urlString)
        let newTab = Tab(url: url, incognito: source.isIncognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: autoPlayPolicy)
        newTab.isPinned = source.isPinned
        tabCancellables[newTab.id] = newTab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tabs.insert(newTab, at: index + 1)
        selectedIndex = index + 1
        persistSession()
    }

    func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        if let url = tab.browser.webView.url?.absoluteString {
            recentlyClosedURLs.append(url)
            if recentlyClosedURLs.count > 20 { recentlyClosedURLs.removeFirst() }
        }
        tabCancellables[tab.id] = nil
        tabs.remove(at: index)
        if selectedIndex >= tabs.count {
            selectedIndex = tabs.count - 1
        }
        persistSession()
    }

    @discardableResult
    func reopenLastClosedTab(javaScriptEnabled: Bool, contentBlocker: ContentBlocker?, videoAdBlocker: VideoAdBlocker? = nil, autoPlayPolicy: AutoPlayPolicy = .requireUserAction) -> Bool {
        guard let url = recentlyClosedURLs.popLast() else { return false }
        addTab(url: url, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker, autoPlayPolicy: autoPlayPolicy)
        return true
    }

    func closeOthers(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let kept = tabs[index]
        for tab in tabs where tab.id != kept.id {
            tabCancellables[tab.id] = nil
        }
        tabs = [kept]
        selectedIndex = 0
        persistSession()
    }

    func closeToTheRight(of index: Int) {
        guard tabs.indices.contains(index) else { return }
        let toRemove = Array(tabs[(index + 1)...])
        for tab in toRemove {
            tabCancellables[tab.id] = nil
        }
        tabs = Array(tabs.prefix(index + 1))
        if selectedIndex > index { selectedIndex = index }
        persistSession()
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

    private let sessionKey = "desire.session"

    func persistSession() {
        var savedTabs: [SavedTab] = []
        for tab in tabs where !tab.isIncognito {
            let stateData = captureInteractionState(for: tab)
            if let url = tab.browser.webView.url?.absoluteString, !url.isEmpty {
                savedTabs.append(SavedTab(url: url, isOnNewTabPage: false, isPinned: tab.isPinned, sessionState: stateData))
            } else if tab.isOnNewTabPage {
                savedTabs.append(SavedTab(url: nil, isOnNewTabPage: true, isPinned: tab.isPinned, sessionState: nil))
            } else if tab.urlString.hasPrefix("http"), let u = URL(string: tab.urlString) {
                savedTabs.append(SavedTab(url: u.absoluteString, isOnNewTabPage: false, isPinned: tab.isPinned, sessionState: stateData))
            }
        }
        guard !savedTabs.isEmpty else {
            UserDefaults.standard.removeObject(forKey: sessionKey)
            return
        }
        let session = SavedSession(tabs: savedTabs, selectedIndex: selectedIndex)
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    private func captureInteractionState(for tab: Tab) -> Data? {
        guard let state = tab.browser.webView.interactionState else { return nil }
        // 使用 NSSecureCoding 编码，与解码保持一致
        return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
    }

    @discardableResult
    func restoreSession(javaScriptEnabled: Bool, contentBlocker: ContentBlocker?, videoAdBlocker: VideoAdBlocker? = nil) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              !session.tabs.isEmpty else {
            return false
        }

        tabs = []
        tabCancellables = [:]

        for saved in session.tabs {
            let url = saved.isOnNewTabPage ? nil : saved.url
            let tab = Tab(url: url, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker, videoAdBlocker: videoAdBlocker)
            tab.isPinned = saved.isPinned

            if let data = saved.sessionState {
                // 使用 NSSecureCoding 解码，允许 WebKit 框架的类
                // interactionState 是 WebKit 内部对象，具体类型未知
                // 使用 NSObject.self 是合理的，因为这是恢复应用自己的状态
                do {
                    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
                    unarchiver.requiresSecureCoding = true
                    let state = unarchiver.decodeObject(of: [NSObject.self], forKey: NSKeyedArchiveRootObjectKey)
                    if let state = state {
                        tab.browser.webView.interactionState = state
                    }
                } catch {
                    // 解码失败，忽略状态恢复
                }
            }

            tabCancellables[tab.id] = tab.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                }
            }
            tabs.append(tab)
            if !saved.isOnNewTabPage, let urlString = saved.url, let parsed = URL(string: urlString) {
                tab.suppressHistoryOnce = true
                tab.browser.webView.load(URLRequest(url: parsed))
            }
        }

        selectedIndex = min(session.selectedIndex, max(0, tabs.count - 1))
        return true
    }
}

private struct SavedTab: Codable {
    let url: String?
    let isOnNewTabPage: Bool
    var isPinned: Bool
    let sessionState: Data?
}

private struct SavedSession: Codable {
    let tabs: [SavedTab]
    let selectedIndex: Int
}
