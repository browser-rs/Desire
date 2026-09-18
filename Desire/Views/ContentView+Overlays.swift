import AppKit
import SwiftUI
import WebKit

/// Overlay contents for `ContentView.body`. Each builder renders the INNER
/// content of one `.overlay(alignment:)` call site — the bodies moved here
/// verbatim from `body` (roadmap L1-1), no logic changed. The visibility
/// conditionals stay INSIDE each builder so an inactive overlay renders
/// nothing at all (an always-present empty bar would still paint its
/// background).
extension ContentView {
    /// Hidden buttons that own the app-wide keyboard shortcuts (⌘L focus+
    /// select-all, ⌘[ / ⌘] navigation, ⌘G find-next, Esc, ⌘' AI panel).
    /// Every binding reads the shared `KeyboardShortcutStore`, so re-recording
    /// one in Settings re-binds it here too. Esc handlers stay hardcoded
    /// (dismissal is contextual, not a customizable command).
    @ViewBuilder
    var shortcutOverlayButtons: some View {
        Button("") {
            isUrlFocused = true
            // Let the field win focus first, then ask it (by notification,
            // targeting the URL field itself rather than whatever NSTextField
            // is first responder) to select all its text.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NotificationCenter.default.post(name: URLBarField.selectAllNotification, object: nil)
            }
        }
            .keyboardShortcut(shortcutStore.keyboardShortcut(for: "focusAddressBar")
                              ?? KeyboardShortcut("l", modifiers: .command))
            .hidden()
        Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.goBack() } }
            .keyboardShortcut(shortcutStore.keyboardShortcut(for: "goBack")
                              ?? KeyboardShortcut("[", modifiers: .command))
            .hidden()
        Button("") { if let tab = tabManager.selectedTab { tab.browser.webView.goForward() } }
            .keyboardShortcut(shortcutStore.keyboardShortcut(for: "goForward")
                              ?? KeyboardShortcut("]", modifiers: .command))
            .hidden()
        Button("") { performFindNext() }
            .keyboardShortcut(shortcutStore.keyboardShortcut(for: "findNext")
                              ?? KeyboardShortcut("g", modifiers: .command))
            .hidden()
        Button("") { performFindPrevious() }
            .keyboardShortcut(shortcutStore.keyboardShortcut(for: "findPrevious")
                              ?? KeyboardShortcut("g", modifiers: [.command, .shift]))
            .hidden()
        Button("") { hideFindBar() }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()
        if let tab = tabManager.selectedTab {
            Button("") {
                tab.browser.isPickingElement = false
                tab.browser.webView.evaluateJavaScript(WebView.exitPickerJS, completionHandler: nil)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()
        }
        Button("") { showAgentPanel.toggle() }
            .keyboardShortcut(shortcutStore.keyboardShortcut(for: "toggleAgentPanel")
                              ?? KeyboardShortcut("'", modifiers: .command))
            .hidden()
        Button("") {
            withAnimation(.transitionNormal) { showCommandPalette = true }
        }
            .keyboardShortcut(shortcutStore.keyboardShortcut(for: "commandPalette")
                              ?? KeyboardShortcut("k", modifiers: .command))
            .hidden()
    }

    /// "Element blocked" toast with an undo button (element blocker).
    var undoToastOverlay: some View {
        Group {
            if showUndoToast {
                HStack(spacing: 8) {
                    Text("Element blocked").font(.caption)
                    Button("Undo") {
                        if let id = lastBlockedRuleId {
                            elementBlockStore.remove(id: id)
                            tabManager.selectedTab?.browser.webView.evaluateJavaScript(
                                WebView.undoBlockJS(ruleId: id, selector: lastBlockedSelector),
                                completionHandler: nil
                            )
                        }
                        showUndoToast = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// Brief action confirmation ("Bookmark Added", "Page Saved", …).
    /// Auto-dismisses after ~1.8 s; re-triggering replaces the payload and
    /// restarts the timer.
    var actionToastOverlay: some View {
        Group {
            if let toast = actionToast {
                HStack(spacing: 6) {
                    Image(systemName: toast.icon)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(toast.text).font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .milliseconds(1800))
                    guard !Task.isCancelled else { return }
                    withAnimation(.transitionNormal) {
                        if actionToast == toast { actionToast = nil }
                    }
                }
            }
        }
    }

    /// Non-blocking notice bars stacked under the toolbar: password save
    /// prompt and beforeunload leave-confirmation (same component family —
    /// replacing these sheets was 0.1.2: sheets steal focus mid-Agent-task).
    @ViewBuilder
    func noticeBars(for tab: Tab) -> some View {
        PasswordSaveBar(store: passwordStore)
        BeforeUnloadBar(browser: tab.browser)
    }

    /// Screenshot completion toast (message published by `BrowsingActions`).
    var screenshotToastOverlay: some View {
        Group {
            if let message = b.screenshotToast {
                HStack(spacing: 8) {
                    Text(message).font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// Video-ad-blocker toast ("已拦截 N 个 … 广告").
    var videoAdBlockerToastOverlay: some View {
        Group {
            if let message = videoAdBlockerToast {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(message)
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                .clipShape(Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Translation bar (toggle from the toolbar).
    var translateBarOverlay: some View {
        Group {
            if showTranslateBar, let tab = tabManager.selectedTab {
                TranslateBar(
                    service: translationService,
                    webView: tab.browser.webView,
                    onDismiss: { showTranslateBar = false }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}


// MARK: - Notice bars

private struct PasswordSaveBar: View {
    @ObservedObject var store: PasswordStore

    var body: some View {
        if let pending = store.pendingSave {
            NoticeBar(
                icon: "key.horizontal.fill",
                tint: .accentColor,
                title: String(localized: "Save Password for \(pending.domain)?"),
                subtitle: String(localized: "Username: \(pending.username)"),
                primaryTitle: String(localized: "Save"),
                secondaryTitle: String(localized: "Not Now"),
                tertiaryTitle: String(localized: "Never for This Site"),
                onPrimary: { store.resolvePendingSave(true) },
                onSecondary: { store.resolvePendingSave(false) },
                onTertiary: {
                    store.suppress(domain: pending.domain)
                    store.resolvePendingSave(false)
                }
            )
        }
    }
}

private struct BeforeUnloadBar: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        if let pending = browser.pendingBeforeUnload {
            NoticeBar(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: String(localized: "Leave This Page?"),
                subtitle: pending.message.isEmpty
                    ? String(localized: "Changes you made may not be saved.")
                    : pending.message,
                primaryTitle: String(localized: "Leave"),
                secondaryTitle: String(localized: "Stay"),
                onPrimary: { pending.respond(leave: true) },
                onSecondary: { pending.respond(leave: false) }
            )
        }
    }
}

/// Shared full-width notice bar under the toolbar: icon + title + subtitle
/// on the left, up to three actions on the right.
private struct NoticeBar: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let primaryTitle: String
    var secondaryTitle: String? = nil
    var tertiaryTitle: String? = nil
    let onPrimary: () -> Void
    var onSecondary: (() -> Void)? = nil
    var onTertiary: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                if let secondaryTitle, let onSecondary {
                    Button(secondaryTitle, action: onSecondary)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let tertiaryTitle, let onTertiary {
                    Button(tertiaryTitle, action: onTertiary)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
