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
    var suppressHistoryOnce = false

    private var cancellables = Set<AnyCancellable>()

    init(url: String? = nil, incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlocker? = nil) {
        self.isIncognito = incognito
        browser = BrowserState(incognito: incognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker)
        browser.webView.allowsBackForwardNavigationGestures = true
        if let url {
            urlString = url
            isOnNewTabPage = false
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

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveOnTerminate),
            name: NSApplication.willTerminateNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func saveOnTerminate() {
        persistSession()
    }

    var selectedTab: Tab? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    func addTab(url: String? = nil, incognito: Bool = false, javaScriptEnabled: Bool = true, contentBlocker: ContentBlocker? = nil) {
        let tab = Tab(url: url, incognito: incognito, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker)
        tabCancellables[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tabs.append(tab)
        selectedIndex = tabs.count - 1
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
    func reopenLastClosedTab(javaScriptEnabled: Bool, contentBlocker: ContentBlocker?) -> Bool {
        guard let url = recentlyClosedURLs.popLast() else { return false }
        addTab(url: url, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker)
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
        return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
    }

    @discardableResult
    func restoreSession(javaScriptEnabled: Bool, contentBlocker: ContentBlocker?) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              !session.tabs.isEmpty else {
            return false
        }

        tabs = []
        tabCancellables = [:]

        for saved in session.tabs {
            let url = saved.isOnNewTabPage ? nil : saved.url
            let tab = Tab(url: url, javaScriptEnabled: javaScriptEnabled, contentBlocker: contentBlocker)
            tab.isPinned = saved.isPinned

            if let data = saved.sessionState,
               let state = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSObject.self], from: data) {
                tab.browser.webView.interactionState = state
            }

            tabCancellables[tab.id] = tab.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
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
