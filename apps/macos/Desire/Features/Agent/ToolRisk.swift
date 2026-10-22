import Foundation

/// Risk classification for browser tools the AI agent can invoke.
///
/// The agent loop (`AgentSessionStore.processLoop`) checks each tool call's
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

    /// Maps a tool name (matching `AgentToolFunctionDef.name` /
    /// `BrowserToolProvider.toolDefs`) to its risk tier.
    ///
    /// Unknown tools default to `.sideEffect` — the conservative middle tier.
    /// We don't default to `.dangerous` (that would block legitimate new
    /// tools behind an un-whitelistable wall), and we don't default to
    /// `.readonly` (that would auto-run unknown side effects).
    static func classify(_ toolName: String) -> ToolRisk {
        // MCP tools are third-party capabilities. Their descriptions are
        // untrusted input and their side effects cannot be inferred from the
        // dynamic schema, so every call requires explicit approval.
        if toolName.hasPrefix("mcp_") { return .dangerous }
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
        "screenshot", "screenshotElement",
        // Listing / inspection
        "listContainers", "listTabs", "listBookmarks", "getHistory", "searchHistory", "listPlugins",
        "listBlockedElements", "listTabGroups", "listQuickDials", "listDownloads",
        "listWorkflows",
        // Navigation that doesn't lose state (history traversal)
        "goBack", "goForward",
        // View toggles (reversible, local to current view)
        "toggleReaderMode", "zoomIn", "zoomOut", "resetZoom", "setZoom", "setSiteFont", "bilingualTranslate",
        // DOM inspection (read-only queries)
        "extract", "findElements", "getPageLinks",
        // Comment / chat structured extraction (read-only)
        "getComments", "getConversation", "getFormFields",
        // Media address extraction (read-only: network sniffer + DOM scan)
        "listPageVideos",
        // 批量下载进度查询（只读；批量启动是有副作用工具，走默认 sideEffect）
        "listBatchDownloads",
        // Deep page data extraction (read-only)
        "getTables", "getImages", "getPageMeta", "getElementHTML", "getNetworkLog",
        // Document reading & export (local OCR / PDF text layer / page→PDF writes a file only)
        "readPdf", "ocrImage", "exportPageAsPDF", "exportPageAsWebArchive",
        // 文档/表格取文（本地解析：textutil 富文本、xlsx/csv 表格；不写任何状态）
        "readDocument", "readSpreadsheet",
        // 运营工作台简报/周报（只读；promotionSave/Metrics/Lesson 写本地状态走默认 sideEffect）
        "promotionBrief", "promotionReport", "promotionPreflight",
        // Waiting / timing (pure observation)
        "waitForText", "waitForSelector", "waitForDownload",
        // Reading list inspection (add/cache stay side-effect)
        "listReadingList",
        // 归档会话查看（restoreArchivedSession 会替换窗口标签，走默认 sideEffect）
        "listArchivedSessions",
        // 页面监视查看（add/remove/check 是写操作/远端抓取，走默认 sideEffect）
        "listPageWatches",
        // readURL 有意不进只读集：带登录态的 GET 按 httpRequest 同族处理
        //（"抓远端内容"一律过一次审批，fullAccess 档无摩擦）。
        // Workspaces 查看（save/restore/delete 是写操作，走默认 sideEffect）
        "listWorkspaces",
        // Skills (read-only instruction loading)
        "useSkill", "listSkills",
        // Scheduled task inspection (creation/cancel stays side-effect)
        "listScheduledTasks",
        // Workspace inspection (reads inside the sandboxed working directory)
        "readFile", "listDirectory",
        // Plan checklist (pure UI state)
        "updatePlan",
        // Whiteboard (pure UI state — local render only)
        "whiteboard",
        // Waits for the user's answer; changes nothing
        "askUser",
        // Visual-only (temporary outline class, auto-removed)
        "highlight",
        // Waiting / timing
        "wait", "waitForElement", "findInPage",
        // Media (PiP is a local view action, reversible)
        "togglePictureInPicture",
        // 停止朗读永远安全（消音方向）；readAloud 本身走默认 sideEffect——
        // 它让设备出声，与 notify 同类。
        "stopSpeaking",
        // Past-conversation search / reading (local files, read-only)
        "searchConversations", "readConversation",
        // 研究来源汇总（当前页/标签/正文索引/历史/阅读列表/书签；只读）
        "researchSources",
        // 文档研究工作台（跨文档分段检索，只读）
        "researchDocuments",
        // Reads back an already-stored tool result (session memory, read-only)
        "getToolResult",
        // Self-critique (one extra model call; changes nothing)
        "reflect",
    ]

    /// Tools that execute arbitrary code or are otherwise unbounded in
    /// effect. Every call requires explicit confirmation.
    private static let dangerousTools: Set<String> = [
        "executeJS", "runCommand",
        // 凭据操作：填存档密码并（可选）提交登录——必须显式确认。
        "fillLogin",
        // 日历事件删除（v0.7.20）：**不可逆**且无 Always-Allow 可接受——
        // 每次调用都必须让用户看见对象摘要再点头（确定性"删错比删不掉更糟"）。
        "deleteCalendarEvent",
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
