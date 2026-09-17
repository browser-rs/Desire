import Foundation

/// Tool-definition table sent to the model on each agent-loop iteration.
/// Split out of `BrowserToolProvider` so the Store class holds only state
/// + dispatch helpers.
extension BrowserToolProvider {
    static var toolDefs: [AgentToolDef] {
        [
            // --- Page reading ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getPageSnapshot", description: "PREFERRED way to read the current page: returns JSON with the cleaned main-content text plus a list of visible interactive elements, each with a ref (\"e1\", \"e2\", …). Act on elements with click/fill {ref: \"e12\"}. Controls missing from the list (icon buttons, custom widgets) can be targeted with click {text: \"<visible label>\"} or found via screenshot + clickAt(x,y).",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "maxChars": AgentJSONSchemaValue(type: "number", description: "Max characters of text content (default 12000)"),
                    "maxElements": AgentJSONSchemaValue(type: "number", description: "Max interactive elements listed (default 60)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getPageLinks", description: "Extract the page's visible links as [{text, href}] — use to plan navigation (\"which link leads to X?\") instead of guessing URLs.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "maxItems": AgentJSONSchemaValue(type: "number", description: "Max links to return (default 50)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "highlight", description: "Scroll to an element and flash an orange outline around it so the USER can see what you are acting on. Use before an important click/fill when narrating a task. Same targeting as click: ref, text, or selector.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "ref": AgentJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "text": AgentJSONSchemaValue(type: "string", description: "Visible text of the target"),
                    "selector": AgentJSONSchemaValue(type: "string", description: "CSS selector (fallback)"),
                ], required: [])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "copyToClipboard", description: "Copy text to the system clipboard (e.g. a summary, a link, generated content).",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "text": AgentJSONSchemaValue(type: "string", description: "Text to copy"),
                ], required: ["text"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "readClipboard", description: "Read text from the system clipboard. Use when the user references copied content (\"打开剪贴板里的链接\", \"总结我复制的东西\"). Requires approval.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "pressKey", description: "Press a keyboard key in the page (trusted key event): enter, escape, tab, backspace, arrows, pageup/pagedown, home/end, letters, digits. Optional modifiers. Use for Enter-to-search, Escape-to-close, ⌘A-style selection.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "key": AgentJSONSchemaValue(type: "string", description: "Key name, e.g. \"enter\", \"escape\", \"tab\", \"a\", \"ArrowDown\"→\"down\""),
                    "modifiers": AgentJSONSchemaValue(type: "array", description: "Optional: [\"cmd\"], [\"shift\"], [\"ctrl\"], [\"alt\"]", items: JSONSchemaItemBox(value: AgentJSONSchemaValue(type: "string"))),
                ], required: ["key"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "type", description: "Type text as REAL keystrokes into the focused element (autocomplete and search-as-you-type respond). Optionally focus a target first via ref/selector. For plain form filling prefer fill.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "text": AgentJSONSchemaValue(type: "string", description: "Text to type"),
                    "ref": AgentJSONSchemaValue(type: "string", description: "Element to focus before typing"),
                    "selector": AgentJSONSchemaValue(type: "string", description: "CSS selector to focus before typing"),
                ], required: ["text"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "waitForText", description: "Wait until visible text appears anywhere on the page (e.g. search results rendered). Use instead of blind wait after triggering an action.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "text": AgentJSONSchemaValue(type: "string", description: "Text to wait for"),
                    "timeout": AgentJSONSchemaValue(type: "number", description: "Max milliseconds (default 8000)"),
                ], required: ["text"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getFormFields", description: "Inventory all visible form fields as structured JSON: {ref, tag, name, id, label, value, required, options}. Fields carry data-desire-ref ids, so fill {ref} targets them directly. Use before filling any form.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listPageVideos", description: "Extract video/audio/stream addresses from the current page. Merges network sniffing (real CDN URLs behind blob: players — m3u8/mp4 as they load) with a DOM/meta scan (<video>, links, og:video, JSON-LD). Use for \"提取这个页面的视频/视频地址\". If empty, play the video briefly and call again.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "renderDiagram", description: "Render a diagram on the built-in canvas (opens in the current tab). Source is Mermaid syntax: mindmap, flowchart, sequenceDiagram, gantt, pie… Use to visualize mind maps, flows, structures, plans for the user. Renders in the browser tab; saved under workspace/canvas/.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "title": AgentJSONSchemaValue(type: "string", description: "Diagram title"),
                    "source": AgentJSONSchemaValue(type: "string", description: "Mermaid source, e.g. \"mindmap\n  root((主题))\n    分支A\n    分支B\""),
                ], required: ["source"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "askUser", description: "Ask the user a clarifying question MID-TASK and wait for their answer (the loop pauses; the answer is returned to you). Use when choices are ambiguous: which account, which quality, publish now or schedule. Do NOT use for information already on the page.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "question": AgentJSONSchemaValue(type: "string", description: "Concrete question; offer options when possible"),
                ], required: ["question"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "writeFile", description: "Write text to a file. Relative paths resolve against the agent WORKING DIRECTORY; absolute paths must be inside the workspace / user folders (anywhere with FULL ACCESS). Use to export extracted data, reports, CSV.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "path": AgentJSONSchemaValue(type: "string", description: "Target file path (relative = working directory)"),
                    "content": AgentJSONSchemaValue(type: "string", description: "File content"),
                ], required: ["path"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "readFile", description: "Read a text file (working directory / user folders). Binary files are reported, not dumped.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "path": AgentJSONSchemaValue(type: "string", description: "File path (relative = working directory)"),
                ], required: ["path"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listDirectory", description: "List a directory's entries with sizes (defaults to the agent working directory).",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "path": AgentJSONSchemaValue(type: "string", description: "Directory path (default: working directory)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "updatePlan", description: "Maintain a VISIBLE task checklist for multi-step work. Send the FULL step list every time with per-step status (pending / in_progress / done); the user watches progress live. Required for any task with 3+ steps — update after each step completes.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "steps": AgentJSONSchemaValue(type: "array", description: "Full step list", items: JSONSchemaItemBox(value: AgentJSONSchemaValue(type: "object", properties: [
                        "content": AgentJSONSchemaValue(type: "string", description: "Step description"),
                        "status": AgentJSONSchemaValue(type: "string", description: "pending | in_progress | done"),
                    ], required: ["content"]))),
                ], required: ["steps"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "setUploadFile", description: "Arm a local file so the NEXT file-picker on any page auto-submits it (no panel). The upload primitive for publishing videos to platforms: arm → open the upload page → click the upload button. Consumed once; clear=true disarms.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "path": AgentJSONSchemaValue(type: "string", description: "Absolute file path, ~ supported"),
                    "clear": AgentJSONSchemaValue(type: "boolean", description: "Disarm instead of arming"),
                ], required: [])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "startRecording", description: "Start recording the browser window to an MP4 (30fps, with cursor). Use when the user asks to record/demonstrate: start → perform the steps → stopRecording. First use asks for macOS Screen Recording permission.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "stopRecording", description: "Stop the window recording and save the MP4 to ~/Downloads. Returns the file path and duration.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "runCommand", description: "Run an allowlisted system CLI tool (ffmpeg, brew, python3, …) with arguments. NO shell — pass argv items. Requires approval on EVERY call showing the exact command (auto-runs in FULL ACCESS). Use useSkill first when a skill covers the task.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "tool": AgentJSONSchemaValue(type: "string", description: "Binary name, e.g. \"ffmpeg\", \"brew\""),
                    "args": AgentJSONSchemaValue(type: "array", description: "Arguments as individual strings, e.g. [\"-y\", \"-i\", \"in.mp4\"]", items: JSONSchemaItemBox(value: AgentJSONSchemaValue(type: "string"))),
                    "timeoutSec": AgentJSONSchemaValue(type: "number", description: "Kill after N seconds (default 120, max 600)"),
                ], required: ["tool"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "useSkill", description: "Load a skill's full instructions into the conversation (progressive disclosure). Call before performing a task that matches a skill.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "name": AgentJSONSchemaValue(type: "string", description: "Skill name from the skills list in your context"),
                ], required: ["name"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listSkills", description: "List installed skills with descriptions.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "scheduleTask", description: "Create a scheduled task (定时任务): the prompt re-runs automatically on a recurrence while the app is open. Use everyMinutes (>= 5) OR dailyAt (\"HH:MM\", 24h). Do NOT use for one-off requests.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "name": AgentJSONSchemaValue(type: "string", description: "Short unique task name"),
                    "prompt": AgentJSONSchemaValue(type: "string", description: "Full prompt re-sent at each firing (must be self-contained)"),
                    "everyMinutes": AgentJSONSchemaValue(type: "string", description: "Interval in minutes (>= 5), e.g. \"30\""),
                    "dailyAt": AgentJSONSchemaValue(type: "string", description: "Daily time \"HH:MM\" 24h, e.g. \"09:00\""),
                ], required: ["name", "prompt"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listScheduledTasks", description: "List scheduled tasks (定时任务) with their recurrences and last-run status.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "cancelScheduledTask", description: "Delete a scheduled task by its name.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "name": AgentJSONSchemaValue(type: "string", description: "Task name"),
                ], required: ["name"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "spawnSubagent", description: "Delegate a SELF-CONTAINED sub-task to a fresh sub-agent with its own context window (same tools, same approvals). Only its final report returns to you — use for deep research, multi-page extraction, or long verification work that would flood this conversation with tool output. The prompt must be complete (goal, pages to visit, what to report). The subagent cannot ask the user questions; it cannot call spawnSubagent itself.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "task": AgentJSONSchemaValue(type: "string", description: "Complete sub-task instructions, e.g. \"Open these 3 URLs, extract price and rating for each, return a comparison table\""),
                    "maxSteps": AgentJSONSchemaValue(type: "number", description: "Max tool-loop steps for the subagent (default 10, cap 15)"),
                ], required: ["task"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "downloadMedia", description: "Download a media resource to the user's Downloads folder. Handles DIRECT files (mp4/webm/mp3/…) and HLS playlists (m3u8: fetches all segments with the page's Referer, decrypts AES-128, concatenates into one playable file). Pair with listPageVideos: extract, confirm with the user which one, then download. The tool call blocks until the export finishes.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "url": AgentJSONSchemaValue(type: "string", description: "Media or m3u8 playlist URL (http/https)"),
                    "fileName": AgentJSONSchemaValue(type: "string", description: "Optional file name without extension"),
                ], required: ["url"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getPageText", description: "Get the RAW visible text of the current page (unfiltered, may be huge). Prefer getPageSnapshot.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getComments", description: "Extract the page's comment section as structured JSON: [{author, text, time, likes}]. Best tool for \"总结评论 / summarize the comments\", gauging opinions, or gathering context before replying. Falls back to raw comment-area text when the site's markup is unknown.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "maxItems": AgentJSONSchemaValue(type: "number", description: "Max comments to extract (default 50)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getConversation", description: "Extract the page's chat/IM messages as structured JSON: [{sender, text, mine}] — mine=true means the user sent it. Best tool for \"总结对话 / summarize this chat\" and drafting a reply on web-based chat or customer-service pages.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "maxItems": AgentJSONSchemaValue(type: "number", description: "Max messages to extract (default 100)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getPageHTML", description: "Get the full HTML of the current page (very large — use only when getPageSnapshot is not enough).",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getPageTitle", description: "Get the page title",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "screenshot", description: "Capture the viewport as an image and return it for visual analysis. Use before clickAt(x,y) to see what's on screen, or whenever you need to verify layout/appearance. The image is delivered to you as a vision input.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "screenshotElement", description: "Capture a close-up screenshot of ONE element (chart, icon, widget) for visual analysis — sharper than the full-viewport screenshot. Same targeting as click: ref, text, or selector.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "ref": AgentJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "text": AgentJSONSchemaValue(type: "string", description: "Visible text of the target"),
                    "selector": AgentJSONSchemaValue(type: "string", description: "CSS selector (fallback)"),
                ], required: [])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "clickAt", description: "Dispatch a real mouse click at viewport CSS-pixel coordinates (x, y). Use when DOM selectors fail (canvas apps, shadow DOM, virtual lists) or when a screenshot shows something you can't locate in the DOM.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "x": AgentJSONSchemaValue(type: "number", description: "Viewport X in CSS pixels"),
                    "y": AgentJSONSchemaValue(type: "number", description: "Viewport Y in CSS pixels"),
                ], required: ["x", "y"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getTables", description: "Extract HTML tables as JSON rows — comparison shopping, stats pages, schedules. Far more reliable than reading rendered text.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "maxTables": AgentJSONSchemaValue(type: "number", description: "Max tables (default 5)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getImages", description: "List visible images with dimensions and alt text — use to pick covers, find assets, or describe a page's visual content.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "maxItems": AgentJSONSchemaValue(type: "number", description: "Max images (default 40)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getPageMeta", description: "Get page metadata: title, description, og: tags, canonical URL, favicon, language.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getElementHTML", description: "Get an element's outerHTML (ref/text/selector targeting) — for debugging pages or inspecting exact markup.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "ref": AgentJSONSchemaValue(type: "string"),
                    "text": AgentJSONSchemaValue(type: "string"),
                    "selector": AgentJSONSchemaValue(type: "string"),
                    "maxLength": AgentJSONSchemaValue(type: "number", description: "Max characters (default 6000)"),
                ], required: [])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getNetworkLog", description: "List the page's fetch/XHR requests (most recent first, filterable). Powerful for discovering a site's internal APIs and JSON endpoints.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "filter": AgentJSONSchemaValue(type: "string", description: "Substring filter, e.g. \"api\" or \".json\""),
                    "maxItems": AgentJSONSchemaValue(type: "number", description: "Max entries (default 100)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getSelectedText", description: "Get the text currently selected by the user on the page",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "readTab", description: "Get a structured snapshot (text + interactive elements) of ANOTHER tab without switching to it — use with listTabs for cross-tab comparison and research tasks",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "index": AgentJSONSchemaValue(type: "number", description: "Tab index (0-based, from listTabs)"),
                ], required: ["index"])
            )),

            // --- Navigation ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "navigate", description: "Navigate to a URL",
                parameters: AgentJSONSchema(type: "object", properties: ["url": AgentJSONSchemaValue(type: "string", description: "The URL to navigate to")], required: ["url"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "goBack", description: "Go back in history",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "goForward", description: "Go forward in history",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- Tab management ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "newTab", description: "Open a new tab, optionally navigated to a URL and optionally inside a named container (isolated cookies — see listContainers)",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "url": AgentJSONSchemaValue(type: "string", description: "URL to load in the new tab (optional)"),
                    "container": AgentJSONSchemaValue(type: "string", description: "Container name for isolated cookies (optional, see listContainers)"),
                ])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listContainers", description: "List tab containers (isolated cookie/session profiles) usable as the newTab container argument",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "closeTab", description: "Close the current or specified tab by index (0-based)",
                parameters: AgentJSONSchema(type: "object", properties: ["index": AgentJSONSchemaValue(type: "number", description: "Tab index to close (optional, defaults to current)")])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listTabs", description: "List all open tabs with their titles and indices",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "switchTab", description: "Switch to a tab by its index (0-based)",
                parameters: AgentJSONSchema(type: "object", properties: ["index": AgentJSONSchemaValue(type: "number", description: "Tab index to switch to")], required: ["index"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "closeOtherTabs", description: "Close all tabs EXCEPT the currently selected one, in this window. Destructive — confirm with the user first unless they asked explicitly.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "reopenLastClosedTab", description: "Reopen the most recently closed tab in this window.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "duplicateTab", description: "Duplicate the currently selected tab.",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- Bookmarks ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "addBookmark", description: "Bookmark the current page",
                parameters: AgentJSONSchema(type: "object", properties: ["title": AgentJSONSchemaValue(type: "string", description: "Custom title (optional)")])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listBookmarks", description: "List all bookmarks with titles and URLs",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "removeBookmark", description: "Remove a bookmark by its URL",
                parameters: AgentJSONSchema(type: "object", properties: ["url": AgentJSONSchemaValue(type: "string", description: "URL of the bookmark to remove")], required: ["url"])
            )),

            // --- History ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "getHistory", description: "Get recent browsing history entries",
                parameters: AgentJSONSchema(type: "object", properties: ["count": AgentJSONSchemaValue(type: "number", description: "Number of entries to return (default 20)")])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "clearHistory", description: "Clear all browsing history",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- Page controls ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "findInPage", description: "Search for text on the current page",
                parameters: AgentJSONSchema(type: "object", properties: ["text": AgentJSONSchemaValue(type: "string", description: "Text to search for")], required: ["text"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "toggleDarkMode", description: "Toggle dark mode for the current website",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "toggleReaderMode", description: "Toggle reader mode for the current page",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "zoomIn", description: "Zoom in the page",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "zoomOut", description: "Zoom out the page",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "resetZoom", description: "Reset zoom to default (100%)",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- Content blockers ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "toggleAdBlocking", description: "Enable or disable ad blocking",
                parameters: AgentJSONSchema(type: "object", properties: ["enabled": AgentJSONSchemaValue(type: "boolean", description: "True to enable, false to disable")], required: ["enabled"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "toggleTrackingProtection", description: "Enable or disable tracking protection",
                parameters: AgentJSONSchema(type: "object", properties: ["enabled": AgentJSONSchemaValue(type: "boolean", description: "True to enable, false to disable")], required: ["enabled"])
            )),

            // --- Reading list ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "addToReadingList", description: "Add the current page to reading list",
                parameters: AgentJSONSchema(type: "object", properties: ["title": AgentJSONSchemaValue(type: "string", description: "Custom title (optional)")])
            )),

            // --- Downloads ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listDownloads", description: "List all downloads with filenames and status",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- Plugins ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listPlugins", description: "List all installed user scripts and plugins",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "togglePlugin", description: "Enable or disable a plugin by name",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "name": AgentJSONSchemaValue(type: "string", description: "Plugin name"),
                    "enabled": AgentJSONSchemaValue(type: "boolean", description: "True to enable, false to disable"),
                ], required: ["name", "enabled"])
            )),

            // --- Element blocker ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listBlockedElements", description: "List all blocked element rules",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "unblockElement", description: "Remove a blocked element rule by its CSS selector",
                parameters: AgentJSONSchema(type: "object", properties: ["selector": AgentJSONSchemaValue(type: "string", description: "CSS selector to unblock")], required: ["selector"])
            )),

            // --- Responsive design ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "toggleResponsiveMode", description: "Toggle responsive design mode, optionally setting a device preset (iPhone SE, iPhone 14 Pro, iPhone 14 Pro Max, iPad 10, iPad Pro 12.9)",
                parameters: AgentJSONSchema(type: "object", properties: ["device": AgentJSONSchemaValue(type: "string", description: "Device preset name (optional)")])
            )),

            // --- Picture in Picture ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "togglePictureInPicture", description: "Toggle picture-in-picture for the current video",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- Tab groups ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listTabGroups", description: "List all tab groups",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "addTabToGroup", description: "Add the current tab to a tab group",
                parameters: AgentJSONSchema(type: "object", properties: ["groupName": AgentJSONSchemaValue(type: "string", description: "Name of the tab group")], required: ["groupName"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "removeTabFromGroup", description: "Remove the current tab from its tab group",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- Print & PDF ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "printPage", description: "Print the current page",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "saveAsPDF", description: "Save the current page as a PDF file",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- Quick Dials ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "listQuickDials", description: "List quick dial shortcuts on the new tab page",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "addQuickDial", description: "Add a quick dial shortcut",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "title": AgentJSONSchemaValue(type: "string", description: "Display title"),
                    "url": AgentJSONSchemaValue(type: "string", description: "URL"),
                ], required: ["title", "url"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "removeQuickDial", description: "Remove a quick dial shortcut by title",
                parameters: AgentJSONSchema(type: "object", properties: ["title": AgentJSONSchemaValue(type: "string", description: "Title of the quick dial to remove")], required: ["title"])
            )),

            // --- Search engine ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "setSearchEngine", description: "Change the default search engine. Built-ins: google, duckduckgo, bing, baidu. Custom engines are matched by their name.",
                parameters: AgentJSONSchema(type: "object", properties: ["engine": AgentJSONSchemaValue(type: "string", description: "Search engine name")], required: ["engine"])
            )),

            // --- Sidebar ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "toggleSidebar", description: "Toggle the sidebar (bookmarks, history, reading list)",
                parameters: AgentJSONSchema(type: "object", properties: [:])
            )),

            // --- DOM interaction ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "click", description: "Click a page element. Target it with ONE of: ref (e.g. \"e12\" from the latest getPageSnapshot — preferred), text (visible label/aria-label, best for buttons the snapshot missed, e.g. \"点赞\", \"Like\", \"Submit\"), or selector (CSS, last resort). The page is scrolled to the element and a real mouse click is dispatched on its nearest clickable ancestor, so icon buttons and framework-wrapped controls work.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "ref": AgentJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot, e.g. \"e12\""),
                    "text": AgentJSONSchemaValue(type: "string", description: "Visible text of the target, e.g. \"点赞\" or \"Sign in\""),
                    "selector": AgentJSONSchemaValue(type: "string", description: "CSS selector (fallback when ref/text unavailable)"),
                ], required: [])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "fill", description: "Fill a form field with a value (fires proper input/change events, works with React/Vue forms)",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "ref": AgentJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "selector": AgentJSONSchemaValue(type: "string", description: "CSS selector of the input (fallback)"),
                    "value": AgentJSONSchemaValue(type: "string", description: "Value to fill"),
                ], required: ["value"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "select", description: "Select an option from a dropdown <select>",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "ref": AgentJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "selector": AgentJSONSchemaValue(type: "string", description: "CSS selector of the select element (fallback)"),
                    "value": AgentJSONSchemaValue(type: "string", description: "Option value or visible label"),
                ], required: ["value"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "scroll", description: "Scroll the page to coordinates",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "x": AgentJSONSchemaValue(type: "number", description: "Horizontal scroll position"),
                    "y": AgentJSONSchemaValue(type: "number", description: "Vertical scroll position"),
                ], required: ["x", "y"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "hover", description: "Hover over an element (reveals hover-only controls). Target with ref, text, or selector — same as click.",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "ref": AgentJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "text": AgentJSONSchemaValue(type: "string", description: "Visible text of the target"),
                    "selector": AgentJSONSchemaValue(type: "string", description: "CSS selector (fallback)"),
                ], required: [])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "focus", description: "Focus an element",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "ref": AgentJSONSchemaValue(type: "string", description: "Element ref from the latest getPageSnapshot"),
                    "selector": AgentJSONSchemaValue(type: "string", description: "CSS selector (fallback)"),
                ], required: [])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "postComment", description: "Post a comment / reply / chat message: automatically finds the page's comment or chat input (textarea or rich-text editor), types the text with framework-compatible events, then submits — real mouse click on the 发送/发表/Send button when present, otherwise Enter. Use for \"帮我评论 / 回复 / 自动回消息\". Pass submit=false to type without sending (then click the send button yourself).",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "text": AgentJSONSchemaValue(type: "string", description: "The comment/reply text to type"),
                    "submit": AgentJSONSchemaValue(type: "boolean", description: "Submit after typing (default true)"),
                ], required: ["text"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "extract", description: "Extract text content from elements matching a CSS selector",
                parameters: AgentJSONSchema(type: "object", properties: ["selector": AgentJSONSchemaValue(type: "string")], required: ["selector"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "findElements", description: "Find elements by CSS selector, returns count and first match text",
                parameters: AgentJSONSchema(type: "object", properties: ["selector": AgentJSONSchemaValue(type: "string")], required: ["selector"])
            )),

            // --- Utilities ---
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "wait", description: "Wait for a specified number of milliseconds",
                parameters: AgentJSONSchema(type: "object", properties: ["ms": AgentJSONSchemaValue(type: "number", description: "Milliseconds to wait")], required: ["ms"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "waitForElement", description: "Wait for an element to appear in the DOM",
                parameters: AgentJSONSchema(type: "object", properties: [
                    "selector": AgentJSONSchemaValue(type: "string"),
                    "timeout": AgentJSONSchemaValue(type: "number", description: "Max milliseconds to wait"),
                ], required: ["selector"])
            )),
            AgentToolDef(type: "function", function: AgentToolFunctionDef(
                name: "executeJS", description: "Execute arbitrary JavaScript code in the page context and return the result",
                parameters: AgentJSONSchema(type: "object", properties: ["code": AgentJSONSchemaValue(type: "string", description: "JavaScript code")], required: ["code"])
            )),
        ]
    }
}
