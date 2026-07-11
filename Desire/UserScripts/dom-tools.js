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

async function __desireClick(selector) {
    var el = document.querySelector(selector);
    if (!el) return "Element not found: " + selector;
    el.click();
    return "Clicked";
}

async function __desireFill(selector, value) {
    var el = document.querySelector(selector);
    if (!el) return "Element not found";
    el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return "Filled";
}

async function __desireSelect(selector, value) {
    var el = document.querySelector(selector);
    if (!el) return "Element not found";
    el.value = value;
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return "Selected";
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
