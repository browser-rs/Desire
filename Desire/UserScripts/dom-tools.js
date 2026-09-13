// dom-tools.js
// Source: extracted from inline JS in BrowserToolProvider.swift (DOM tools)
// Injected as: WKUserScript @ atDocumentStart, forMainFrameOnly: false
//
// These functions are invoked by Swift via `callAsyncJavaScript(_:arguments:)`,
// which passes parameters as native typed values — NO string interpolation,
// NO escaping. Selectors and values arrive as real JS strings, so there is
// no injection surface. The functions live on the page's window so
// `contentWorld: .page` calls can reach them.
//
// Each function returns a short status string matching the old `eval` shape,
// so BrowserToolProvider's return values stay unchanged.

// --- DOM mutation (side-effect tier) ---

// Resolves `selector`, scrolls it into the viewport (instant, so the rect
// is valid immediately), and returns its bounding rect as a JSON string —
// consumed by the trusted-input click/hover path in SyntheticInput.swift.
// Returns "" when the element is missing.
async function __desireElementRect(selector) {
    var el = document.querySelector(selector);
    if (!el) return "";
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    var r = el.getBoundingClientRect();
    return JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height });
}

async function __desireClick(selector) {
    var el = document.querySelector(selector);
    if (!el) return "Element not found: " + selector;
    el.click();
    return "Clicked";
}

async function __desireFill(selector, value) {
    var el = document.querySelector(selector);
    if (!el) return "Element not found";
    // React/Vue-controlled inputs ignore plain `el.value = ...`: the
    // framework installs its own value property over the element and only
    // reacts when the ORIGINAL prototype setter wrote the change. Write
    // through the prototype descriptor, then fire the same event sequence
    // a real keystroke produces.
    var proto = el instanceof HTMLTextAreaElement
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    var desc = Object.getOwnPropertyDescriptor(proto, "value");
    function set(v) {
        if (desc && desc.set) { desc.set.call(el, v); } else { el.value = v; }
        el.dispatchEvent(new Event("input", { bubbles: true }));
    }
    el.focus();
    set("");          // clear first so framework change detection sees the edit
    set(value);
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return "Filled";
}

async function __desireSelect(selector, value) {
    var el = document.querySelector(selector);
    if (!el || el.tagName !== "SELECT") return "Element not found or not a <select>";
    // The model may pass either an option's value or its visible label.
    var match = Array.prototype.find.call(el.options, function (o) {
        return o.value === value || o.text.trim() === value;
    });
    if (!match) return "No option matching: " + value;
    var desc = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value");
    if (desc && desc.set) { desc.set.call(el, match.value); } else { el.value = match.value; }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return "Selected: " + (match.text.trim() || match.value);
}

async function __desireHover(selector) {
    var el = document.querySelector(selector);
    if (!el) return "Element not found";
    el.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    return "Hovered";
}

async function __desireFocus(selector) {
    var el = document.querySelector(selector);
    if (!el) return "Element not found";
    el.focus();
    return "Focused";
}

async function __desireScroll(x, y) {
    window.scrollTo(x, y);
    return "Scrolled";
}

async function __desireWaitForElement(selector, timeout) {
    var start = Date.now();
    return await new Promise(function (resolve) {
        function check() {
            var el = document.querySelector(selector);
            if (el) return resolve("Found element");
            if (Date.now() - start > timeout) return resolve("Timeout");
            setTimeout(check, 200);
        }
        check();
    });
}

// --- DOM inspection (read-only tier) ---

// Structured page snapshot for the AI agent: cleaned main-content text plus
// a capped list of visible interactive elements. Each element is tagged with
// a `data-desire-ref` attribute so the agent can act on it afterwards with
// the regular click/fill tools via selector `[data-desire-ref="e12"]` —
// no extra ref-dispatch tool needed.
// Returns a JSON string (consumed by BrowserToolProvider.getPageSnapshot).
async function __desireSnapshot(maxChars, maxElements) {
    maxChars = maxChars || 12000;
    maxElements = maxElements || 60;

    // --- main content text (scored containers, same idea as reader mode) ---
    var root = null, bestScore = -Infinity;
    var candidates = document.querySelectorAll(
        "article, [role=main], main, .post, .article, .content, #content, #article");
    for (var c = 0; c < candidates.length; c++) {
        var el = candidates[c];
        var t = el.innerText || "";
        var score = t.length - el.querySelectorAll("a").length * 20;
        if (score > bestScore && t.trim().length > 80) { bestScore = score; root = el; }
    }
    if (!root) root = document.body;
    var text = (root.innerText || "")
        .replace(/[ \t]+/g, " ")
        .replace(/\n{3,}/g, "\n\n")
        .trim();
    if (text.length > maxChars) text = text.substring(0, maxChars) + "…[truncated]";

    // --- visible interactive elements ---
    var selector = "a[href], button, input, select, textarea, summary, " +
                   "[role=button], [onclick], [contenteditable=true]";
    var all = document.querySelectorAll(selector);
    var elements = [];
    for (var i = 0; i < all.length && elements.length < maxElements; i++) {
        var e = all[i];
        var rect = e.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) continue;
        var style = window.getComputedStyle(e);
        if (style.visibility === "hidden" || style.display === "none") continue;
        var refId = "e" + (elements.length + 1);
        try { e.setAttribute("data-desire-ref", refId); } catch (err) {}
        var label = (e.getAttribute("aria-label") || e.innerText || e.value ||
                     e.placeholder || e.getAttribute("title") || "")
                    .trim().replace(/\s+/g, " ").substring(0, 80);
        var tag = e.tagName.toLowerCase();
        if (tag === "input") tag = "input[" + (e.type || "text") + "]";
        elements.push({ ref: refId, tag: tag, text: label });
    }

    return JSON.stringify({
        title: document.title || "",
        url: location.href,
        text: text,
        elements: elements
    });
}

async function __desireExtract(selector) {
    var els = document.querySelectorAll(selector);
    return Array.from(els).map(function (e) {
        return e.textContent.trim();
    }).filter(Boolean).join("\n---\n");
}

async function __desireFindElements(selector) {
    var els = document.querySelectorAll(selector);
    if (els.length === 0) return "No elements found";
    var first = els[0].textContent.trim().substring(0, 200);
    return "Found " + els.length + " elements. First: " + first;
}
