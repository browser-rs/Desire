import WebKit

@MainActor
class BrowserToolProvider {
    static var toolDefs: [AIToolDef] {
        [
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageText", description: "Get the visible text content of the current page",
                parameters: AIJSONSchema(type: "object")
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageHTML", description: "Get the full HTML of the current page",
                parameters: AIJSONSchema(type: "object")
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getPageTitle", description: "Get the page title",
                parameters: AIJSONSchema(type: "object")
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "screenshot", description: "Take a screenshot of the current viewport, returns base64 PNG",
                parameters: AIJSONSchema(type: "object")
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "getSelectedText", description: "Get the text currently selected by the user on the page",
                parameters: AIJSONSchema(type: "object")
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "navigate", description: "Navigate to a URL",
                parameters: AIJSONSchema(type: "object", properties: ["url": AIJSONSchemaValue(type: "string", description: "The URL to navigate to")], required: ["url"])
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "goBack", description: "Go back in history",
                parameters: AIJSONSchema(type: "object")
            )),
            AIToolDef(type: "function", function: AIToolFunctionDef(
                name: "goForward", description: "Go forward in history",
                parameters: AIJSONSchema(type: "object")
            )),
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
                name: "find", description: "Find elements by CSS selector, returns count and first match text",
                parameters: AIJSONSchema(type: "object", properties: ["selector": AIJSONSchemaValue(type: "string")], required: ["selector"])
            )),
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

    func execute(_ call: AIToolCall, in webView: WKWebView) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: call.function.arguments.data(using: .utf8) ?? Data()) as? [String: Any]) ?? [:]
        switch call.function.name {
        case "getPageText":
            return await eval(webView, "document.body.innerText")
        case "getPageHTML":
            return await eval(webView, "document.documentElement.outerHTML")
        case "getPageTitle":
            return await eval(webView, "document.title")
        case "screenshot":
            return "[Screenshot capture not yet integrated]"
        case "getSelectedText":
            return await eval(webView, "window.getSelection().toString()")
        case "navigate":
            if let url = args["url"] as? String, let u = URL(string: url) {
                webView.load(URLRequest(url: u))
                return "Navigated to \(url)"
            }
            return "Invalid URL"
        case "goBack":
            webView.goBack()
            return "Going back"
        case "goForward":
            webView.goForward()
            return "Going forward"
        case "click":
            if let sel = args["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found: \(sel.jsEscaped)';
                    el.click();
                    return 'Clicked';
                })()
                """)
            }
            return "Missing selector"
        case "fill":
            if let sel = args["selector"] as? String, let val = args["value"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found';
                    el.value = '\(val.jsEscaped)';
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    return 'Filled';
                })()
                """)
            }
            return "Missing selector or value"
        case "select":
            if let sel = args["selector"] as? String, let val = args["value"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found';
                    el.value = '\(val.jsEscaped)';
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    return 'Selected';
                })()
                """)
            }
            return "Missing selector or value"
        case "scroll":
            let x = args["x"] as? Double ?? 0
            let y = args["y"] as? Double ?? 0
            return await eval(webView, "window.scrollTo(\(x), \(y)); 'Scrolled'")
        case "hover":
            if let sel = args["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found';
                    el.dispatchEvent(new MouseEvent('mouseover', {bubbles:true}));
                    return 'Hovered';
                })()
                """)
            }
            return "Missing selector"
        case "focus":
            if let sel = args["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var el = document.querySelector('\(sel.jsEscaped)');
                    if (!el) return 'Element not found';
                    el.focus();
                    return 'Focused';
                })()
                """)
            }
            return "Missing selector"
        case "extract":
            if let sel = args["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var els = document.querySelectorAll('\(sel.jsEscaped)');
                    return Array.from(els).map(function(e){ return e.textContent.trim(); }).filter(Boolean).join('\\n---\\n');
                })()
                """)
            }
            return "Missing selector"
        case "find":
            if let sel = args["selector"] as? String {
                return await eval(webView, """
                (function() {
                    var els = document.querySelectorAll('\(sel.jsEscaped)');
                    if (els.length === 0) return 'No elements found';
                    var first = els[0].textContent.trim().substring(0, 200);
                    return 'Found ' + els.length + ' elements. First: ' + first;
                })()
                """)
            }
            return "Missing selector"
        case "wait":
            let ms = args["ms"] as? Int ?? 1000
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return "Waited \(ms)ms"
        case "waitForElement":
            let sel = args["selector"] as? String ?? ""
            let timeout = args["timeout"] as? Int ?? 5000
            return await eval(webView, """
            (function() {
                var start = Date.now();
                return new Promise(function(resolve) {
                    function check() {
                        var el = document.querySelector('\(sel.jsEscaped)');
                        if (el) return resolve('Found element');
                        if (Date.now() - start > \(timeout)) return resolve('Timeout');
                        setTimeout(check, 200);
                    }
                    check();
                });
            })()
            """)
        case "executeJS":
            if let code = args["code"] as? String {
                return await eval(webView, code) ?? "Executed (no return value)"
            }
            return "Missing code"
        default:
            return "Unknown tool: \(call.function.name)"
        }
    }

    private func eval(_ wv: WKWebView, _ js: String) async -> String {
        await withCheckedContinuation { continuation in
            wv.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                } else if let result = result as? String {
                    continuation.resume(returning: result)
                } else if let result = result {
                    continuation.resume(returning: "\(result)")
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}

private extension String {
    var jsEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}
