import AppKit
import WebKit

/// Dispatches real (`isTrusted == true`) mouse events into a WKWebView.
///
/// Why this exists: `element.click()` and hand-built `MouseEvent`s are
/// synthesized *inside* the web process, so the page sees them with
/// `isTrusted == false`. Anti-automation systems — Cloudflare Turnstile in
/// particular — treat untrusted interaction as a bot signal and will
/// challenge or block the user's session. The only trusted input path into
/// WKWebView is a genuine NSEvent routed through the AppKit event pipeline
/// (`NSApp.sendEvent` → `NSWindow.sendEvent` → WKWebView → WebKit), which
/// is indistinguishable from a physical mouse.
///
/// In-process dispatch needs no Accessibility permission and works even when
/// the app is not frontmost. Agent tools call this with the center point of
/// a resolved element (see `BrowserToolProvider.clickablePoint`); the in-page
/// `__desireClick`/`__desireHover` JS remains the fallback for webviews with
/// no window (suspended/background tabs).
@MainActor
enum SyntheticInput {
    /// Posts a mouse-down/up pair at `point` (window-base coordinates,
    /// bottom-left origin — what `NSEvent.mouseEvent(location:)` expects).
    static func click(at point: CGPoint, in webView: WKWebView) async {
        guard let window = webView.window else { return }
        post(.leftMouseDown, at: point, windowNumber: window.windowNumber, clickCount: 1)
        // A short gap so WebKit sees down and up as separate user actions
        // (instant tap counts as a click, but some sites measure hold time).
        try? await Task.sleep(nanoseconds: 40_000_000)
        post(.leftMouseUp, at: point, windowNumber: window.windowNumber, clickCount: 1)
    }

    /// Posts a short stream of mouse-moved events approaching and ending at
    /// `point`, so the page sees a cursor entering the element — that is
    /// what makes `:hover` CSS and mouseover/mouseenter fire.
    static func hover(at point: CGPoint, in webView: WKWebView) async {
        guard let window = webView.window else { return }
        // WebKit only forwards moved events when the window opts in.
        // Browsers leave this enabled; the default NSWindow opt-out exists
        // for document windows that never need hover.
        window.acceptsMouseMovedEvents = true
        let start = CGPoint(x: point.x - 24, y: point.y - 18)
        for step in 0...2 {
            let t = CGFloat(step) / 2
            let p = CGPoint(x: start.x + (point.x - start.x) * t,
                            y: start.y + (point.y - start.y) * t)
            post(.mouseMoved, at: p, windowNumber: window.windowNumber, clickCount: 0)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private static func post(_ type: NSEvent.EventType, at point: CGPoint, windowNumber: Int, clickCount: Int) {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1.0 : 0.0
        ) else { return }
        NSApp.sendEvent(event)
    }

    // MARK: - Keyboard (trusted)

    /// Hardware key codes for the named keys the agent may press, plus the
    /// characters WebKit expects on the keyDown for text-bearing keys.
    private static let keyMap: [String: (keyCode: UInt16, characters: String)] = [
        "enter": (36, "\r"), "return": (36, "\r"),
        "escape": (53, "\u{1B}"), "esc": (53, "\u{1B}"),
        "tab": (48, "\t"),
        "backspace": (51, "\u{7F}"), "delete": (51, "\u{7F}"),
        "forwarddelete": (117, ""),
        "space": (49, " "),
        "up": (126, ""), "down": (125, ""), "left": (123, ""), "right": (124, ""),
        "pageup": (116, ""), "pagedown": (121, ""),
        "home": (115, ""), "end": (119, ""),
        "a": (0, "a"), "b": (11, "b"), "c": (8, "c"), "d": (2, "d"), "e": (14, "e"),
        "f": (3, "f"), "g": (5, "g"), "h": (4, "h"), "i": (22, "i"), "j": (38, "j"),
        "k": (40, "k"), "l": (37, "l"), "m": (46, "m"), "n": (45, "n"), "o": (23, "o"),
        "p": (25, "p"), "q": (12, "q"), "r": (15, "r"), "s": (1, "s"), "t": (17, "t"),
        "u": (20, "u"), "v": (9, "v"), "w": (13, "w"), "x": (7, "x"), "y": (16, "y"),
        "z": (6, "z"),
        "0": (29, "0"), "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"),
        "5": (23, "5"), "6": (22, "6"), "7": (26, "7"), "8": (28, "8"), "9": (25, "9"),
    ]

    /// Human-readable list for error messages when a key isn't in the map.
    static var supportedKeys: String {
        keyMap.keys.sorted().joined(separator: ", ")
    }

    /// Posts a trusted key press (down+up, with modifier tap around it) to
    /// the webview. The webview is made first responder for the duration —
    /// keys go to the PAGE, not to whatever field in the AI panel happens
    /// to hold focus — and the previous responder is restored afterwards.
    static func key(_ name: String, modifiers: NSEvent.ModifierFlags = [], in webView: WKWebView) async -> String {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard let mapped = keyMap[normalized] else {
            return "Unsupported key: \(name). Supported: \(supportedKeys)"
        }
        guard let window = webView.window else {
            return "No window attached — keyboard input needs a visible webview"
        }

        let previousResponder = window.firstResponder
        window.makeFirstResponder(webView)
        defer { window.makeFirstResponder(previousResponder) }

        // 大写判定用原始 name——normalized 已 lowercased,isUppercase 恒 false。
        let flags: NSEvent.ModifierFlags = modifiers.isEmpty
            ? (normalized.count == 1 && name.trimmingCharacters(in: .whitespaces).first?.isUppercase == true ? .shift : [])
            : modifiers

        let characters = flags.contains(.shift) ? mapped.characters.uppercased() : mapped.characters
        postKey(.keyDown, keyCode: mapped.keyCode, characters: characters,
                modifiers: flags, windowNumber: window.windowNumber)
        try? await Task.sleep(nanoseconds: 20_000_000)
        postKey(.keyUp, keyCode: mapped.keyCode, characters: characters,
                modifiers: flags, windowNumber: window.windowNumber)
        return "Pressed \(normalized)"
    }

    /// Types `text` as a stream of trusted per-character key events into the
    /// focused element. Unlike `fill` (prototype-setter + input events), this
    /// triggers real keydown handling — autocomplete-as-you-type, search
    /// suggestion panels, and keydown-driven widgets all respond.
    static func type(_ text: String, in webView: WKWebView) async -> String {
        guard let window = webView.window else {
            return "No window attached — keyboard input needs a visible webview"
        }
        let previousResponder = window.firstResponder
        window.makeFirstResponder(webView)
        defer { window.makeFirstResponder(previousResponder) }

        for ch in text {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: String(ch),
                charactersIgnoringModifiers: String(ch),
                isARepeat: false,
                keyCode: 0
            ) else { continue }
            NSApp.sendEvent(event)
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
        return "Typed \(text.count) characters"
    }

    private static func postKey(
        _ type: NSEvent.EventType, keyCode: UInt16, characters: String,
        modifiers: NSEvent.ModifierFlags, windowNumber: Int
    ) {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { return }
        NSApp.sendEvent(event)
    }
}
