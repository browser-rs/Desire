# Session Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore full WKWebView state (back/forward history, scroll position, form state) across app restarts using `interactionState`.

**Architecture:** Add `sessionState: Data?` to `SavedTab`. Serialize `webView.interactionState` via `NSKeyedArchiver` on tab switch/close/navigate; deserialize on restore. Fall back to current URL-only behavior if state is unavailable.

**Tech Stack:** Swift, WKWebView (macOS 13+), UserDefaults, NSKeyedArchiver

---

### Task 1: Extend SavedTab with sessionState

**Files:**
- Modify: `Desire/Features/Browsing/TabManager.swift:187-191`

- [ ] **Step 1: Add `sessionState: Data?` to SavedTab**

```swift
private struct SavedTab: Codable {
    let url: String?
    let isOnNewTabPage: Bool
    var isPinned: Bool
    let sessionState: Data?
}
```

- [ ] **Step 2: Add sessionState parameter when constructing SavedTab in persistSession**

In `persistSession()`, capture `webView.interactionState` and archive it:

```swift
private func captureInteractionState(for tab: Tab) -> Data? {
    guard let state = tab.browser.webView.interactionState else { return nil }
    return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
}
```

Then in the loop:

```swift
let stateData = captureInteractionState(for: tab)
savedTabs.append(SavedTab(url: url, isOnNewTabPage: false, isPinned: tab.isPinned, sessionState: stateData))
```

- [ ] **Step 3: Restore interactionState in restoreSession**

After creating a tab but before loading the URL:

```swift
if let data = saved.sessionState,
   let state = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSObject.self], from: data) {
    tab.browser.webView.interactionState = state
}
```

- [ ] **Step 4: Build and commit**

Run `xcodebuild -project Desire.xcodeproj -scheme Desire build`.

```bash
git add -A && git commit -m "feat: session restore with interactionState

- Save WKWebView.interactionState (back/forward list, scroll, form state)
- Archive via NSKeyedArchiver, store in SavedTab.sessionState
- Restore on app launch before loading URL
- Fall back gracefully if state is nil/corrupt"
```

---

### Task 2: Auto-save on tab switch and navigation

**Files:**
- Modify: `Desire/Features/Browsing/TabManager.swift`
- Modify: `Desire/Features/Browsing/WebView.swift`

- [ ] **Step 1: Save on tab switch**

In `selectTab(at index:)`, save the outgoing tab's state before selecting the new one:

```swift
func selectTab(at index: Int) {
    guard tabs.indices.contains(index) else { return }
    // Save session when switching away from current tab
    persistSession()
    selectedIndex = index
}
```

- [ ] **Step 2: Save on navigation commit**

In `WebView.swift` Coordinator's `webView(_:didCommit:)`, trigger a session persist:

Call via the existing page finished callback or add a new callback. Since `WebView` already has an `onPageFinished` callback, we can add `onPageCommit` or simply trigger persistSession through the ContentView chain. 

Actually, the simplest approach: since TabManager is the owner of persistSession, we should expose a way to trigger it. ContentView holds TabManager, so:

In `WebView`, add a new callback `onNavigationChanged: (() -> Void)?` and call it in `didCommit`. Then in ContentView, pass `{ tabManager.persistSession() }` as the callback.

Wait, that's adding complexity. Let me think of a simpler approach.

Alternative: In WebView's Coordinator, when `didCommit` fires, we can save the tab's interactionState directly. But Coordinator doesn't have access to TabManager.

Simplest approach: just call `persistSession()` in `selectTab` and `closeTab` (already called there). For navigation commits, we can use a periodic timer or just rely on tab switch/close saves. The most critical state to save is when the user switches tabs or closes the app — both already handled.

Actually, the navigation commit save is nice-to-have but not critical. The tab switch save covers the common case. Let me add a simple callback for didCommit.

Actually, let me just keep it simple:

1. Tab switch → persistSession (already handled by adding it to selectTab)
2. Tab close → persistSession (already handled)
3. App termination → persistSession (add notification observer in TabManager)

For navigation commit, I'll skip it for now — the tab switch save is the critical one.

Actually, we might lose state if the user navigates and then the app crashes before they switch tabs. But that's an edge case. Let's keep it simple with just tab switch + app quit.

- [ ] **Step 3: Save on app termination**

In `TabManager`, add observation of `NSApplication.willTerminateNotification`:

```swift
func observeAppTermination() {
    NotificationCenter.default.addObserver(
        self, selector: #selector(saveOnTerminate),
        name: NSApplication.willTerminateNotification, object: nil
    )
}

@objc private func saveOnTerminate() {
    persistSession()
}
```

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: auto-save session on tab switch and app quit"
```
