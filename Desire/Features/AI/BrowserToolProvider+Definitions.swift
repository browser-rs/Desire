import Foundation

/// Tool-definition table sent to the model on each agent-loop iteration.
/// Split out of `BrowserToolProvider` so the Store class holds only state
/// + dispatch helpers.
extension BrowserToolProvider {
    static var toolDefs: [AIToolDef] {
        [
            // --- Page reading ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageSnapshot", description: "PREFERRED way to read the current page: returns JSON with the cleaned main-content text plus a list of visible interactive elements, each with a ref (\"e1\", \"e2\", …). Act on elements with click/fill {ref: \"e12\"}. Controls missing from the list (icon buttons, custom widgets) can be targeted with click {text: \"<visible label>\"} or found via screenshot + clickAt(x,y).",
                parameters: AIJSONSchema(type: "object", properties: [
                    "maxChars": AIJSONSchemaValue(type: "number", description: "Max characters of text content (default 12000)"),
                    "maxElements": AIJSONSchemaValue(type: "number", description: "Max interactive elements listed (default 60)"),
                ])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageLinks", description: "Extract the page's visible links as [{text, href}] — use to plan navigation (\"which link leads to X?\") instead of guessing URLs.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "maxItems": AIJSONSchemaValue(type: "number", description: "Max links to return (default 50)"),
                ])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "highlight", description: "Scroll to an element and flash an orange outline around it so the USER can see what you are acting on. Use before an important click/fill when narrating a task. Same targeting as click: ref, text, or selector.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "ref": AIJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "text": AIJSONSchemaValue(type: "string", description: "Visible text of the target"),
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector (fallback)"),
                ], required: [])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "copyToClipboard", description: "Copy text to the system clipboard (e.g. a summary, a link, generated content).",
                parameters: AIJSONSchema(type: "object", properties: [
                    "text": AIJSONSchemaValue(type: "string", description: "Text to copy"),
                ], required: ["text"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "readClipboard", description: "Read text from the system clipboard. Use when the user references copied content (\"打开剪贴板里的链接\", \"总结我复制的东西\"). Requires approval.",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "pressKey", description: "Press a keyboard key in the page (trusted key event): enter, escape, tab, backspace, arrows, pageup/pagedown, home/end, letters, digits. Optional modifiers. Use for Enter-to-search, Escape-to-close, ⌘A-style selection.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "key": AIJSONSchemaValue(type: "string", description: "Key name, e.g. \"enter\", \"escape\", \"tab\", \"a\", \"ArrowDown\"→\"down\""),
                    "modifiers": AIJSONSchemaValue(type: "array", description: "Optional: [\"cmd\"], [\"shift\"], [\"ctrl\"], [\"alt\"]", items: JSONSchemaItemBox(value: AIJSONSchemaValue(type: "string"))),
                ], required: ["key"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "type", description: "Type text as REAL keystrokes into the focused element (autocomplete and search-as-you-type respond). Optionally focus a target first via ref/selector. For plain form filling prefer fill.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "text": AIJSONSchemaValue(type: "string", description: "Text to type"),
                    "ref": AIJSONSchemaValue(type: "string", description: "Element to focus before typing"),
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector to focus before typing"),
                ], required: ["text"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "waitForText", description: "Wait until visible text appears anywhere on the page (e.g. search results rendered). Use instead of blind wait after triggering an action.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "text": AIJSONSchemaValue(type: "string", description: "Text to wait for"),
                    "timeout": AIJSONSchemaValue(type: "number", description: "Max milliseconds (default 8000)"),
                ], required: ["text"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getFormFields", description: "Inventory all visible form fields as structured JSON: {ref, tag, name, id, label, value, required, options}. Fields carry data-desire-ref ids, so fill {ref} targets them directly. Use before filling any form.",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listPageVideos", description: "Extract video/audio/stream addresses from the current page. Merges network sniffing (real CDN URLs behind blob: players — m3u8/mp4 as they load) with a DOM/meta scan (<video>, links, og:video, JSON-LD). Use for \"提取这个页面的视频/视频地址\". If empty, play the video briefly and call again.",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "downloadMedia", description: "Download a media resource to the user's Downloads folder. Handles DIRECT files (mp4/webm/mp3/…) and HLS playlists (m3u8: fetches all segments with the page's Referer, decrypts AES-128, concatenates into one playable file). Pair with listPageVideos: extract, confirm with the user which one, then download. The tool call blocks until the export finishes.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "url": AIJSONSchemaValue(type: "string", description: "Media or m3u8 playlist URL (http/https)"),
                    "fileName": AIJSONSchemaValue(type: "string", description: "Optional file name without extension"),
                ], required: ["url"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageText", description: "Get the RAW visible text of the current page (unfiltered, may be huge). Prefer getPageSnapshot.",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getComments", description: "Extract the page's comment section as structured JSON: [{author, text, time, likes}]. Best tool for \"总结评论 / summarize the comments\", gauging opinions, or gathering context before replying. Falls back to raw comment-area text when the site's markup is unknown.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "maxItems": AIJSONSchemaValue(type: "number", description: "Max comments to extract (default 50)"),
                ])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getConversation", description: "Extract the page's chat/IM messages as structured JSON: [{sender, text, mine}] — mine=true means the user sent it. Best tool for \"总结对话 / summarize this chat\" and drafting a reply on web-based chat or customer-service pages.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "maxItems": AIJSONSchemaValue(type: "number", description: "Max messages to extract (default 100)"),
                ])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageHTML", description: "Get the full HTML of the current page (very large — use only when getPageSnapshot is not enough).",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageTitle", description: "Get the page title",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "screenshot", description: "Capture the viewport as an image and return it for visual analysis. Use before clickAt(x,y) to see what's on screen, or whenever you need to verify layout/appearance. The image is delivered to you as a vision input.",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "clickAt", description: "Dispatch a real mouse click at viewport CSS-pixel coordinates (x, y). Use when DOM selectors fail (canvas apps, shadow DOM, virtual lists) or when a screenshot shows something you can't locate in the DOM.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "x": AIJSONSchemaValue(type: "number", description: "Viewport X in CSS pixels"),
                    "y": AIJSONSchemaValue(type: "number", description: "Viewport Y in CSS pixels"),
                ], required: ["x", "y"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getSelectedText", description: "Get the text currently selected by the user on the page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "readTab", description: "Get a structured snapshot (text + interactive elements) of ANOTHER tab without switching to it — use with listTabs for cross-tab comparison and research tasks",
                parameters: AIJSONSchema(type: "object", properties: [
                    "index": AIJSONSchemaValue(type: "number", description: "Tab index (0-based, from listTabs)"),
                ], required: ["index"])
            )),

            // --- Navigation ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "navigate", description: "Navigate to a URL",
                parameters: AIJSONSchema(type: "object", properties: ["url": AIJSONSchemaValue(type: "string", description: "The URL to navigate to")], required: ["url"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "goBack", description: "Go back in history",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "goForward", description: "Go forward in history",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Tab management ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "newTab", description: "Open a new tab, optionally navigated to a URL and optionally inside a named container (isolated cookies — see listContainers)",
                parameters: AIJSONSchema(type: "object", properties: [
                    "url": AIJSONSchemaValue(type: "string", description: "URL to load in the new tab (optional)"),
                    "container": AIJSONSchemaValue(type: "string", description: "Container name for isolated cookies (optional, see listContainers)"),
                ])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listContainers", description: "List tab containers (isolated cookie/session profiles) usable as the newTab container argument",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "closeTab", description: "Close the current or specified tab by index (0-based)",
                parameters: AIJSONSchema(type: "object", properties: ["index": AIJSONSchemaValue(type: "number", description: "Tab index to close (optional, defaults to current)")])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listTabs", description: "List all open tabs with their titles and indices",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "switchTab", description: "Switch to a tab by its index (0-based)",
                parameters: AIJSONSchema(type: "object", properties: ["index": AIJSONSchemaValue(type: "number", description: "Tab index to switch to")], required: ["index"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "closeOtherTabs", description: "Close all tabs EXCEPT the currently selected one, in this window. Destructive — confirm with the user first unless they asked explicitly.",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "reopenLastClosedTab", description: "Reopen the most recently closed tab in this window.",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "duplicateTab", description: "Duplicate the currently selected tab.",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Bookmarks ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "addBookmark", description: "Bookmark the current page",
                parameters: AIJSONSchema(type: "object", properties: ["title": AIJSONSchemaValue(type: "string", description: "Custom title (optional)")])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listBookmarks", description: "List all bookmarks with titles and URLs",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "removeBookmark", description: "Remove a bookmark by its URL",
                parameters: AIJSONSchema(type: "object", properties: ["url": AIJSONSchemaValue(type: "string", description: "URL of the bookmark to remove")], required: ["url"])
            )),

            // --- History ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getHistory", description: "Get recent browsing history entries",
                parameters: AIJSONSchema(type: "object", properties: ["count": AIJSONSchemaValue(type: "number", description: "Number of entries to return (default 20)")])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "clearHistory", description: "Clear all browsing history",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Page controls ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "findInPage", description: "Search for text on the current page",
                parameters: AIJSONSchema(type: "object", properties: ["text": AIJSONSchemaValue(type: "string", description: "Text to search for")], required: ["text"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleDarkMode", description: "Toggle dark mode for the current website",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleReaderMode", description: "Toggle reader mode for the current page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "zoomIn", description: "Zoom in the page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "zoomOut", description: "Zoom out the page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "resetZoom", description: "Reset zoom to default (100%)",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Content blockers ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleAdBlocking", description: "Enable or disable ad blocking",
                parameters: AIJSONSchema(type: "object", properties: ["enabled": AIJSONSchemaValue(type: "boolean", description: "True to enable, false to disable")], required: ["enabled"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleTrackingProtection", description: "Enable or disable tracking protection",
                parameters: AIJSONSchema(type: "object", properties: ["enabled": AIJSONSchemaValue(type: "boolean", description: "True to enable, false to disable")], required: ["enabled"])
            )),

            // --- Reading list ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "addToReadingList", description: "Add the current page to reading list",
                parameters: AIJSONSchema(type: "object", properties: ["title": AIJSONSchemaValue(type: "string", description: "Custom title (optional)")])
            )),

            // --- Downloads ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listDownloads", description: "List all downloads with filenames and status",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Plugins ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listPlugins", description: "List all installed user scripts and plugins",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "togglePlugin", description: "Enable or disable a plugin by name",
                parameters: AIJSONSchema(type: "object", properties: [
                    "name": AIJSONSchemaValue(type: "string", description: "Plugin name"),
                    "enabled": AIJSONSchemaValue(type: "boolean", description: "True to enable, false to disable"),
                ], required: ["name", "enabled"])
            )),

            // --- Element blocker ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listBlockedElements", description: "List all blocked element rules",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "unblockElement", description: "Remove a blocked element rule by its CSS selector",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string", description: "CSS selector to unblock")], required: ["selector"])
            )),

            // --- Responsive design ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleResponsiveMode", description: "Toggle responsive design mode, optionally setting a device preset (iPhone SE, iPhone 14 Pro, iPhone 14 Pro Max, iPad 10, iPad Pro 12.9)",
                parameters: AIJSONSchema(type: "object", properties: ["device": AIJSONSchemaValue(type: "string", description: "Device preset name (optional)")])
            )),

            // --- Picture in Picture ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "togglePictureInPicture", description: "Toggle picture-in-picture for the current video",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Tab groups ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listTabGroups", description: "List all tab groups",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "addTabToGroup", description: "Add the current tab to a tab group",
                parameters: AIJSONSchema(type: "object", properties: ["groupName": AIJSONSchemaValue(type: "string", description: "Name of the tab group")], required: ["groupName"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "removeTabFromGroup", description: "Remove the current tab from its tab group",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Print & PDF ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "printPage", description: "Print the current page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "saveAsPDF", description: "Save the current page as a PDF file",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- Quick Dials ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "listQuickDials", description: "List quick dial shortcuts on the new tab page",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "addQuickDial", description: "Add a quick dial shortcut",
                parameters: AIJSONSchema(type: "object", properties: [
                    "title": AIJSONSchemaValue(type: "string", description: "Display title"),
                    "url": AIJSONSchemaValue(type: "string", description: "URL"),
                ], required: ["title", "url"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "removeQuickDial", description: "Remove a quick dial shortcut by title",
                parameters: AIJSONSchema(type: "object", properties: ["title": AIJSONSchemaValue(type: "string", description: "Title of the quick dial to remove")], required: ["title"])
            )),

            // --- Search engine ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "setSearchEngine", description: "Change the default search engine. Built-ins: google, duckduckgo, bing, baidu. Custom engines are matched by their name.",
                parameters: AIJSONSchema(type: "object", properties: ["engine": AIJSONSchemaValue(type: "string", description: "Search engine name")], required: ["engine"])
            )),

            // --- Sidebar ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "toggleSidebar", description: "Toggle the sidebar (bookmarks, history, reading list)",
                parameters: AIJSONSchema(type: "object", properties: [:])
            )),

            // --- DOM interaction ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "click", description: "Click a page element. Target it with ONE of: ref (e.g. \"e12\" from the latest getPageSnapshot — preferred), text (visible label/aria-label, best for buttons the snapshot missed, e.g. \"点赞\", \"Like\", \"Submit\"), or selector (CSS, last resort). The page is scrolled to the element and a real mouse click is dispatched on its nearest clickable ancestor, so icon buttons and framework-wrapped controls work.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "ref": AIJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot, e.g. \"e12\""),
                    "text": AIJSONSchemaValue(type: "string", description: "Visible text of the target, e.g. \"点赞\" or \"Sign in\""),
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector (fallback when ref/text unavailable)"),
                ], required: [])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "fill", description: "Fill a form field with a value (fires proper input/change events, works with React/Vue forms)",
                parameters: AIJSONSchema(type: "object", properties: [
                    "ref": AIJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector of the input (fallback)"),
                    "value": AIJSONSchemaValue(type: "string", description: "Value to fill"),
                ], required: ["value"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "select", description: "Select an option from a dropdown <select>",
                parameters: AIJSONSchema(type: "object", properties: [
                    "ref": AIJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector of the select element (fallback)"),
                    "value": AIJSONSchemaValue(type: "string", description: "Option value or visible label"),
                ], required: ["value"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "scroll", description: "Scroll the page to coordinates",
                parameters: AIJSONSchema(type: "object", properties: [
                    "x": AIJSONSchemaValue(type: "number", description: "Horizontal scroll position"),
                    "y": AIJSONSchemaValue(type: "number", description: "Vertical scroll position"),
                ], required: ["x", "y"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "hover", description: "Hover over an element (reveals hover-only controls). Target with ref, text, or selector — same as click.",
                parameters: AIJSONSchema(type: "object", properties: [
                    "ref": AIJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "text": AIJSONSchemaValue(type: "string", description: "Visible text of the target"),
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector (fallback)"),
                ], required: [])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "focus", description: "Focus an element",
                parameters: AIJSONSchema(type: "object", properties: [
                    "ref": AIJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector (fallback)"),
                ], required: [])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "postComment", description: "Post a comment / reply / chat message: automatically finds the page's comment or chat input (textarea or rich-text editor), types the text with framework-compatible events, then submits — real mouse click on the 发送/发表/Send button when present, otherwise Enter. Use for \"帮我评论 / 回复 / 自动回消息\". Pass submit=false to type without sending (then click the send button yourself).",
                parameters: AIJSONSchema(type: "object", properties: [
                    "text": AIJSONSchemaValue(type: "string", description: "The comment/reply text to type"),
                    "submit": AIJSONSchemaValue(type: "boolean", description: "Submit after typing (default true)"),
                ], required: ["text"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "extract", description: "Extract text content from elements matching a CSS selector",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "findElements", description: "Find elements by CSS selector, returns count and first match text",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
            )),

            // --- Utilities ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "wait", description: "Wait for a specified number of milliseconds",
                parameters: AIJSONSchema(type: "object", properties: ["ms": AIJSONSchemaValue(type: "number", description: "Milliseconds to wait")], required: ["ms"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "waitForElement", description: "Wait for an element to appear in the DOM",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchemaValue(type: "string"),
                    "timeout": AIJSONSchemaValue(type: "number", description: "Max milliseconds to wait"),
                ], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "executeJS", description: "Execute arbitrary JavaScript code in the page context and return the result",
                parameters: AIJSONSchema(type: "object", properties: ["code": AIJSONSchemaValue(type: "string", description: "JavaScript code")], required: ["code"])
            )),
        ]
    }
}
