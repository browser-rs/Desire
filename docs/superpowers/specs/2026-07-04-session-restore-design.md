# Session Restore — Design Spec

## Summary

Use `WKWebView.interactionState` (macOS 13+ public API) to save and restore the full browsing session per tab, including back/forward list, scroll position, and form state.

## Current State

`TabManager` already persists tab URLs via `UserDefaults` (`SavedTab` with `urlString`, `title`, `displayTitle`, `isPinned`, `isIncognito`). Session saves on tab change and app quit, restores on launch. However, only the current URL is restored — back/forward history, scroll position, and form state are lost.

## Data Model Change

Add to `SavedTab`:

```swift
struct SavedTab: Codable {
    // existing fields…
    let sessionState: Data?  // NSKeyedArchiver-archived WKWebView.interactionState
}
```

`Data` is `Codable` natively. `nil` means "no saved state" (backward compatible).

## Save Path

**When to save `interactionState` → Data:**
1. **Tab switch**: `TabManager.selectTab()` — save the outgoing tab's state
2. **Navigation commit**: `webView:didCommit` — save on every successful navigation
3. **App termination**: `applicationWillTerminate` notification — final full save
4. **Tab close**: `TabManager.closeTab()` — save before removing

**Encoding:**
```swift
if let state = webView.interactionState {
    let data = try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
    savedTab.sessionState = data
}
```

## Restore Path

**On app launch** (`TabManager.restoreSession()`):

```
for each savedTab:
    tab = createTab()
    tab.browser.setupWebView()
if let data = savedTab.sessionState,
   let state = try? NSKeyedUnarchiver.unarchivedObject(
       ofClasses: [NSObject.self],
       from: data
   ) {
        tab.browser.webView.interactionState = state
    }
    tab.browser.navigate(to: savedTab.urlString)
```

WKWebView will restore the full session (back/forward list, scroll position, form state) when `interactionState` is set before the first load. The subsequent `load(URLRequest)` acts as the current page.

## Edge Cases

| Case | Handling |
|------|---------|
| **Corrupt Data** | `nil` sessionState → fall back to current URL load. Saved tabs still restore with at least their URL. |
| **Older version** | `decodeIfPresent` on `sessionState`. `nil` = no state, single URL load. |
| **Large state** | State is typically 1-10 KB per tab. `UserDefaults` limit is ~1 MB total. At ~50 tabs (500 KB), we're safe. |
| **Incognito tabs** | Not persisted (current behavior unchanged). |
| **First load before interactionState** | WKWebView must have `interactionState` set before any load call. We call it before the navigation. |
| **State class changes across OS versions** | `NSKeyedUnarchiver` uses secure coding. If unarchiving fails, we fall back to nil state gracefully. |

## File Changes

| File | Change |
|------|--------|
| `Features/Browsing/TabManager.swift` | Add `sessionState: Data?` to `SavedTab`. Save state on tab switch/close/navigate. Restore state on session restore. |
| `Features/Browsing/WebView.swift` | Expose a method to get/set `interactionState` from `BrowserState`. |

## Non-Goals

- Scroll position restoration within a page (handled by `interactionState` automatically)
- Form state restoration (handled by `interactionState` automatically)
- Crash recovery / auto-save on crash (future enhancement)
