import Foundation

/// Risk classification for browser tools the AI agent can invoke.
///
/// The agent loop (`AISessionStore.processLoop`) checks each tool call's
/// risk before executing it. This is the human-in-the-loop gate that lets
/// the agent run autonomously for safe operations while pausing for user
/// consent before anything that changes browser/page state.
///
/// See `docs/ARCHITECTURE.md` (roadmap L3 stage 2 — AgentRuntime v2).
enum ToolRisk: Int, Comparable {
    /// Read-only inspection. No observable change to the browser, page, or
    /// persisted data. Executed automatically without prompting the user.
    ///
    /// Examples: getPageText, screenshot, listTabs, extract.
    case readonly = 0

    /// Changes browser/page state but within the user's expected scope.
    /// Prompts the user once, with a "Always Allow" option that whitelists
    /// the tool for the rest of the session (persisted across launches).
    ///
    /// Examples: navigate, click, fill, addBookmark, toggleDarkMode.
    case sideEffect = 1

    /// Arbitrary code execution or other irreversibly destructive action.
    /// Prompts on EVERY call — "Always Allow" is never offered. This is the
    /// only tier that can bypass the whitelist.
    ///
    /// Currently only `executeJS` qualifies: it runs arbitrary JavaScript in
    /// the page and can do anything (exfiltrate data, modify the DOM in any
    /// way, trigger network requests as the user).
    case dangerous = 2

    static func < (lhs: ToolRisk, rhs: ToolRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Maps a tool name (matching `AIToolFunctionDef.name` /
    /// `BrowserToolProvider.toolDefs`) to its risk tier.
    ///
    /// Unknown tools default to `.sideEffect` — the conservative middle tier.
    /// We don't default to `.dangerous` (that would block legitimate new
    /// tools behind an un-whitelistable wall), and we don't default to
    /// `.readonly` (that would auto-run unknown side effects).
    static func classify(_ toolName: String) -> ToolRisk {
        if readonlyTools.contains(toolName) { return .readonly }
        if dangerousTools.contains(toolName) { return .dangerous }
        return .sideEffect
    }

    /// Read-only tools. Kept as a Set for O(1) lookup; the exhaustive list
    /// mirrors every `case` in `BrowserToolProvider.execute` that only reads
    /// state or produces output without mutating anything.
    private static let readonlyTools: Set<String> = [
        // Page reading
        "getPageSnapshot", "getPageText", "getPageHTML", "getPageTitle", "getSelectedText",
        "readTab",
        "screenshot",
        // Listing / inspection
        "listContainers", "listTabs", "listBookmarks", "getHistory", "listPlugins",
        "listBlockedElements", "listTabGroups", "listQuickDials", "listDownloads",
        // Navigation that doesn't lose state (history traversal)
        "goBack", "goForward",
        // View toggles (reversible, local to current view)
        "toggleReaderMode", "zoomIn", "zoomOut", "resetZoom",
        // DOM inspection (read-only queries)
        "extract", "findElements", "getPageLinks",
        // Comment / chat structured extraction (read-only)
        "getComments", "getConversation", "getFormFields",
        // Waiting / timing (pure observation)
        "waitForText",
        // Visual-only (temporary outline class, auto-removed)
        "highlight",
        // Waiting / timing
        "wait", "waitForElement", "findInPage",
        // Media (PiP is a local view action, reversible)
        "togglePictureInPicture",
    ]

    /// Tools that execute arbitrary code or are otherwise unbounded in
    /// effect. Every call requires explicit confirmation.
    private static let dangerousTools: Set<String> = [
        "executeJS",
    ]

    /// A short, human-readable label for this tier, shown in the approval UI.
    var displayName: String {
        switch self {
        case .readonly:   "Safe (read-only)"
        case .sideEffect: "Changes state"
        case .dangerous:  "Runs code"
        }
    }
}
