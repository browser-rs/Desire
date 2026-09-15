import Foundation

/// Tool-definition table sent to the model on each agent-loop iteration.
/// Split out of `BrowserToolProvider` so the Store class holds only state
/// + dispatch helpers.
extension BrowserToolProvider {
    static var toolDefs: [AIToolDef] {
        [
            // --- Page reading ---
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageSnapshot", description: "PREFERRED way to read the current page: returns JSON with the cleaned main-content text plus a list of visible interactive elements. Each element carries a data-desire-ref attribute — act on it with click/fill using the selector [data-desire-ref=\"e12\"].",
                parameters: AIJSONSchema(type: "object", properties: [
                    "maxChars": AIJSONSchemaValue(type: "number", description: "Max characters of text content (default 12000)"),
                    "maxElements": AIJSONSchemaValue(type: "number", description: "Max interactive elements listed (default 60)"),
                ])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageText", description: "Get the RAW visible text of the current page (unfiltered, may be huge). Prefer getPageSnapshot.",
                parameters: AIJSONSchema(type: "object", properties: [:])
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
                name: "screenshot", description: "Take a screenshot of the current viewport, returns base64 PNG. Pairs with clickAt: coordinates are viewport CSS pixels (getPageSnapshot reports the viewport size).",
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
                name: "click", description: "Click an element identified by CSS selector",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string", description: "CSS selector")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "fill", description: "Fill a form field with a value",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector of the input"),
                    "value": AIJSONSchemaValue(type: "string", description: "Value to fill"),
                ], required: ["selector", "value"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "select", description: "Select an option from a dropdown",
                parameters: AIJSONSchema(type: "object", properties: [
                    "selector": AIJSONSchemaValue(type: "string", description: "CSS selector of the select element"),
                    "value": AIJSONSchemaValue(type: "string", description: "Value to select"),
                ], required: ["selector", "value"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "scroll", description: "Scroll the page to coordinates",
                parameters: AIJSONSchema(type: "object", properties: [
                    "x": AIJSONSchemaValue(type: "number", description: "Horizontal scroll position"),
                    "y": AIJSONSchemaValue(type: "number", description: "Vertical scroll position"),
                ], required: ["x", "y"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "hover", description: "Hover over an element",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "focus", description: "Focus an element",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
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
