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
//
// Element resolution accepts THREE targeting modes (checked in this order):
//   ref      — a `data-desire-ref` id from the last getPageSnapshot
//   text     — visible text / aria-label / title, score-matched (e.g. "点赞")
//   selector — a plain CSS selector
// Whatever resolves is then walked UP to the nearest actually-clickable
// ancestor: modern frameworks put handlers on a <div> wrapper, and SVG
// children have no `.click()` at all.

// --- Element resolution helpers ---

// Is `node` something a real user could activate?
function __desireIsClickable(node) {
    if (!node || node.nodeType !== 1) return false;
    var tag = node.tagName.toLowerCase();
    if (tag === "button" || tag === "a" || tag === "summary" ||
        tag === "select" || tag === "label" || tag === "option") return true;
    if (tag === "input" && node.type !== "hidden") return true;
    if (tag === "textarea" || node.isContentEditable) return true;
    var role = node.getAttribute("role");
    if (role === "button" || role === "tab" || role === "menuitem" ||
        role === "checkbox" || role === "radio" || role === "option" ||
        role === "switch" || role === "link") return true;
    if (node.hasAttribute("onclick")) return true;
    if (node.hasAttribute("tabindex") && node.getAttribute("tabindex") !== "-1") return true;
    try {
        if (window.getComputedStyle(node).cursor === "pointer") return true;
    } catch (err) {}
    return false;
}

// Walk up (max 6 hops) from a child hit (svg path, icon span, inner text)
// to the element that will actually respond to activation.
function __desireClickableAncestor(el) {
    var node = el;
    for (var hops = 0; node && node !== document.body && hops < 6; hops++) {
        if (__desireIsClickable(node)) return node;
        node = node.parentElement;
    }
    return el;
}

// Score-based lookup by visible text. Handles icon buttons whose only
// labels are aria-label/title, and framework nodes with plain innerText.
function __desireFindByText(text) {
    var q = String(text).trim().toLowerCase();
    if (!q) return null;
    var candidates = document.querySelectorAll(
        "button, a, [role], [onclick], label, summary, input, textarea, " +
        "svg, span, div, li, td, p, h1, h2, h3, h4, h5, h6");
    var best = null, bestScore = -Infinity;
    for (var i = 0; i < candidates.length; i++) {
        var el = candidates[i];
        var rect = el.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) continue;
        var style = window.getComputedStyle(el);
        if (style.visibility === "hidden" || style.display === "none") continue;
        var label = (el.getAttribute("aria-label") || el.innerText ||
                     el.getAttribute("title") || "")
                    .trim().toLowerCase();
        if (!label || label.length > 300) continue;
        var score = -1;
        if (label === q) score = 100;
        else if (label.indexOf(q) === 0) score = 80;
        else if (label.indexOf(q) !== -1) score = 50;
        else if (q.length >= 4 && label.indexOf(q.substring(0, 4)) !== -1) score = 20;
        if (score <= 0) continue;
        // Prefer deeper (more specific) nodes, native controls, tight labels.
        var depth = 0, n = el;
        while (n && n !== document.body) { depth++; n = n.parentElement; }
        var native = __desireIsClickable(el) ? 8 : 0;
        score += Math.min(depth, 30) * 0.5 + native - Math.abs(label.length - q.length) * 0.05;
        if (score > bestScore) { bestScore = score; best = el; }
    }
    return best;
}

async function __desireResolveEl(selector, ref, text) {
    var el = null;
    if (ref && /^e\d+$/.test(String(ref))) {
        el = document.querySelector('[data-desire-ref="' + ref + '"]');
    } else if (text) {
        el = __desireFindByText(text);
    } else if (selector) {
        // Main document first, then same-origin iframes.
        el = document.querySelector(selector);
        if (!el) {
            var docs = __desireAllDocs();
            for (var di = 1; di < docs.length && !el; di++) {
                try { el = docs[di].querySelector(selector); } catch (err) {}
            }
        }
    }
    if (!el) return null;
    return __desireClickableAncestor(el);
}

// --- DOM mutation (side-effect tier) ---

// Resolves the target (selector/ref/text), scrolls it into the viewport
// (instant, so the rect is valid immediately), and returns its bounding
// rect as a JSON string — consumed by the trusted-input click/hover path
// in SyntheticInput.swift. Returns "" when nothing resolves.
async function __desireElementRect(selector, ref, text) {
    var el = await __desireResolveEl(selector, ref, text);
    if (!el) return "";
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    var r = __desirePageRect(el);
    return JSON.stringify({ x: r.left, y: r.top, w: r.width, h: r.height });
}

// In-page click fallback: full pointer+mouse sequence with coordinates, so
// delegated listeners (React/Vue root handlers, jQuery) see a realistic
// activation — a bare `.click()` misses pointerdown/mousedown consumers.
async function __desireClick(selector, ref, text) {
    var el = await __desireResolveEl(selector, ref, text);
    if (!el) {
        var which = text ? ("text '" + text + "'") : (ref ? ("ref " + ref) : selector);
        return "Element not found: " + which;
    }
    el.scrollIntoView({ block: "center", behavior: "instant" });
    var r = el.getBoundingClientRect();
    var opts = {
        bubbles: true, cancelable: true, view: window, button: 0,
        clientX: r.left + r.width / 2, clientY: r.top + r.height / 2
    };
    try {
        el.dispatchEvent(new PointerEvent("pointerover", opts));
        el.dispatchEvent(new MouseEvent("mouseover", opts));
        el.dispatchEvent(new PointerEvent("pointerdown", opts));
        el.dispatchEvent(new MouseEvent("mousedown", opts));
        if (el.focus) el.focus();
        el.dispatchEvent(new PointerEvent("pointerup", opts));
        el.dispatchEvent(new MouseEvent("mouseup", opts));
        el.dispatchEvent(new MouseEvent("click", opts));
    } catch (err) {
        if (el.click) el.click();
    }
    return "Clicked";
}

async function __desireFill(selector, value, ref) {
    var el = await __desireResolveEl(selector, ref, null);
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

async function __desireSelect(selector, value, ref) {
    var el = await __desireResolveEl(selector, ref, null);
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

async function __desireHover(selector, ref, text) {
    var el = await __desireResolveEl(selector, ref, text);
    if (!el) return "Element not found";
    el.scrollIntoView({ block: "center", behavior: "instant" });
    var r = el.getBoundingClientRect();
    var opts = {
        bubbles: true, cancelable: true, view: window,
        clientX: r.left + r.width / 2, clientY: r.top + r.height / 2
    };
    try {
        el.dispatchEvent(new PointerEvent("pointerover", opts));
        el.dispatchEvent(new MouseEvent("mouseover", opts));
        el.dispatchEvent(new MouseEvent("mouseenter", { bubbles: false, view: window, clientX: opts.clientX, clientY: opts.clientY }));
        el.dispatchEvent(new MouseEvent("mousemove", opts));
    } catch (err) {
        el.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
    }
    return "Hovered";
}

async function __desireFocus(selector, ref) {
    var el = await __desireResolveEl(selector, ref, null);
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
// click {ref: "e12"} — no selector crafting needed.
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
    // Drop refs from the previous snapshot first — elements move around in
    // SPAs, and a stale ref silently targeting the wrong node is worse than
    // no ref.
    var stale = document.querySelectorAll("[data-desire-ref]");
    for (var s = 0; s < stale.length; s++) {
        try { stale[s].removeAttribute("data-desire-ref"); } catch (err0) {}
    }

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
        var entry = { ref: refId, tag: tag, text: label };
        var pressed = e.getAttribute("aria-pressed");
        if (pressed !== null) entry.pressed = pressed;
        elements.push(entry);
    }

    return JSON.stringify({
        title: document.title || "",
        url: location.href,
        // Viewport geometry in CSS pixels — lets a vision model map
        // screenshot pixels to clickAt(x, y) coordinates.
        viewport: {
            width: window.innerWidth,
            height: window.innerHeight,
            scrollX: window.scrollX,
            scrollY: window.scrollY
        },
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

// --- Comment / chat extraction & posting ---
//
// Heuristic, site-agnostic support for the highest-frequency agent tasks:
// summarizing comment sections and web-chat conversations, and posting
// replies. Class-name patterns cover the common shapes (bilibili, weibo,
// zhihu, news sites, service-chat widgets) without per-site rules.

// Largest visible container whose class/id mentions comments/replies.
function __desireFindCommentRoot() {
    var cands = document.querySelectorAll(
        "[id*='comment' i], [class*='comment' i], [class*='reply' i], [class*='Comment' i]");
    var best = null, bestLen = 200;   // must look like real content
    for (var i = 0; i < cands.length; i++) {
        var el = cands[i];
        var rect = el.getBoundingClientRect();
        if (rect.width < 100 || rect.height < 60) continue;
        var len = (el.innerText || "").length;
        if (len > bestLen) { bestLen = len; best = el; }
    }
    return best;
}

function __desireItemAuthor(item) {
    var a = item.querySelector("[class*='name' i], [class*='user' i], [class*='author' i], [class*='nick' i], [class*='sender' i]");
    var t = a ? (a.innerText || "").trim().split("\n")[0] : "";
    return t.substring(0, 40);
}

function __desireItemText(item) {
    // Clone and strip the furniture (author/time/likes/actions/avatar) so
    // the remaining text IS the comment/message body — robust across
    // markup where the content node has no recognizable class.
    var clone = item.cloneNode(true);
    var junk = clone.querySelectorAll(
        "[class*='time' i], [class*='date' i], [class*='like' i], [class*='praise' i], " +
        "[class*='digg' i], [class*='agree' i], [class*='action' i], [class*='avatar' i], " +
        "[class*='reply' i], [class*='floor' i], time, img, svg");
    for (var j = 0; j < junk.length; j++) {
        try { junk[j].remove(); } catch (err) {}
    }
    return (clone.innerText || "").trim().replace(/\n{2,}/g, "\n").substring(0, 500);
}

// Dedupe overlapping hits (an item containing a previously picked item, or
// nested inside one) so a comment isn't listed twice.
function __desirePushUnique(list, seen, item) {
    for (var i = 0; i < seen.length; i++) {
        if (seen[i] === item) return;
        if (seen[i].contains(item) || item.contains(seen[i])) return;
    }
    seen.push(item);
    list.push(item);
}

async function __desireGetComments(maxItems) {
    maxItems = maxItems || 50;
    var root = __desireFindCommentRoot();
    if (!root) return "";
    var hits = root.querySelectorAll(
        "[class*='item' i], [class*='comment' i], [class*='reply' i], li, article, [class*='cell' i]");
    var seen = [], picked = [];
    for (var i = 0; i < hits.length && picked.length < maxItems; i++) {
        var it = hits[i];
        var r = it.getBoundingClientRect();
        if (r.width < 50 || r.height < 20) continue;
        var text = __desireItemText(it);
        if (text.length < 2) continue;
        var before = picked.length;
        __desirePushUnique(picked, seen, it);
        if (picked.length === before) continue;
    }
    var items = [];
    for (var k = 0; k < picked.length; k++) {
        var el = picked[k];
        var timeEl = el.querySelector("time, [class*='time' i], [class*='date' i]");
        var likeEl = el.querySelector("[class*='like' i], [class*='praise' i], [class*='digg' i], [class*='agree' i]");
        var entry = {
            author: __desireItemAuthor(el),
            text: __desireItemText(el)
        };
        var t = timeEl ? ((timeEl.getAttribute && timeEl.getAttribute("datetime")) || timeEl.innerText || "") : "";
        if (t.trim()) entry.time = t.trim().substring(0, 30);
        var l = likeEl ? (likeEl.innerText || "").trim() : "";
        if (l) entry.likes = l.substring(0, 12);
        items.push(entry);
    }
    if (items.length === 0) {
        // Structured extraction failed but a comment area exists — hand the
        // model the raw text so it can still summarize.
        return JSON.stringify({
            note: "unstructured",
            text: (root.innerText || "").substring(0, 6000)
        });
    }
    return JSON.stringify({ count: items.length, items: items });
}

async function __desireGetConversation(maxItems) {
    maxItems = maxItems || 100;
    var cands = document.querySelectorAll(
        "[class*='message' i], [class*='msg' i], [class*='chat' i], [class*='bubble' i], [class*='conversation' i], [class*='im-' i]");
    var root = null, bestLen = 150;
    for (var i = 0; i < cands.length; i++) {
        var r = cands[i].getBoundingClientRect();
        if (r.width < 150 || r.height < 80) continue;
        var len = (cands[i].innerText || "").length;
        if (len > bestLen) { bestLen = len; root = cands[i]; }
    }
    if (!root) return "";
    var hits = root.querySelectorAll(
        "[class*='message' i], [class*='msg' i], [class*='bubble' i], [class*='item' i], li");
    var seen = [], picked = [];
    for (var j = 0; j < hits.length && picked.length < maxItems; j++) {
        var it = hits[j];
        var rc = it.getBoundingClientRect();
        if (rc.width < 30 || rc.height < 12) continue;
        __desirePushUnique(picked, seen, it);
    }
    var items = [];
    for (var k = 0; k < picked.length; k++) {
        var el = picked[k];
        var cls = (el.className && el.className.baseVal !== undefined)
            ? el.className.baseVal : String(el.className || "");
        var mine = /(self|mine|right|outgoing|send|own)/i.test(cls) ||
                   (el.parentElement && /(self|mine|right|outgoing|send|own)/i.test(String(el.parentElement.className || "")));
        var sender = __desireItemAuthor(el);
        var text = __desireItemText(el);
        if (!text) continue;
        var entry = { text: text };
        if (sender) entry.sender = sender;
        entry.mine = !!mine;
        items.push(entry);
    }
    if (items.length === 0) {
        return JSON.stringify({
            note: "unstructured",
            text: (root.innerText || "").substring(0, 6000)
        });
    }
    return JSON.stringify({ count: items.length, items: items });
}

// Types `text` into the page's comment / reply / chat box and — when
// `submit` is set — reports the submit button's rect so Swift can dispatch
// a TRUSTED click on it (falls back to an Enter key event in-page when the
// page has no visible submit button).
// Contenteditable editors (Draft.js / ProseMirror / Lexical / bilibili's
// comment box) are handled via execCommand('insertText'), which fires the
// beforeinput/input events those frameworks listen for — naive value
// writes are ignored by them.
async function __desirePostComment(text, submit) {    var inputs = document.querySelectorAll('textarea, [contenteditable="true"], [contenteditable=""]');
    var re = /(评论|回复|说点什么|留言|吐槽|发条|写下|发言|聊天|说说|comment|reply|message|say something|type)/i;
    var best = null, bestScore = -Infinity;
    for (var i = 0; i < inputs.length; i++) {
        var el = inputs[i];
        var r = el.getBoundingClientRect();
        if (r.width < 60 || r.height < 16) continue;
        var style = window.getComputedStyle(el);
        if (style.visibility === "hidden" || style.display === "none") continue;
        var score = 0;
        var ph = (el.placeholder || el.getAttribute("placeholder") ||
                  el.getAttribute("data-placeholder") || el.getAttribute("aria-label") || "");
        if (re.test(ph)) score += 50;
        if (el.closest("[class*='comment' i], [id*='comment' i], [class*='reply' i], [class*='chat' i], [class*='editor' i], form")) score += 30;
        if (el.isContentEditable) score += 5;   // modern comment boxes
        score += Math.min(r.top, 2000) * 0.01;  // lower on page = likelier
        if (score > bestScore) { bestScore = score; best = el; }
    }
    if (!best) {
        return JSON.stringify({ status: "No comment or chat input found on this page", submitRect: null });
    }

    best.scrollIntoView({ block: "center", behavior: "instant" });
    best.focus();
    if (best.isContentEditable) {
        // Collapse the caret to the end, then type through the editing API.
        var sel = window.getSelection();
        var range = document.createRange();
        range.selectNodeContents(best);
        range.collapse(false);
        sel.removeAllRanges();
        sel.addRange(range);
        var ok = false;
        try { ok = document.execCommand("insertText", false, text); } catch (err) {}
        if (!ok) {
            best.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: "insertText", data: text }));
            best.appendChild(document.createTextNode(text));
            best.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: text }));
        }
    } else {
        var proto = best instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        var desc = Object.getOwnPropertyDescriptor(proto, "value");
        if (desc && desc.set) { desc.set.call(best, text); } else { best.value = text; }
        best.dispatchEvent(new Event("input", { bubbles: true }));
        best.dispatchEvent(new Event("change", { bubbles: true }));
    }

    if (!submit) {
        return JSON.stringify({ status: "Typed (not submitted)", submitRect: null });
    }

    // Submit button: short verb labels only, near the editor.
    var scope = best.closest("form") || best.parentElement;
    var btnRe = /^(发送|发表|回复|评论|发布|提交|确定|发送语音|send|post|reply|submit|comment|publish)\s*:?\s*$/i;
    var btn = null;
    for (var hop = 0; hop < 4 && !btn && scope; hop++) {
        var buttons = scope.querySelectorAll("button, [role=button], input[type=submit], a[class*='btn' i], [class*='send' i], [class*='submit' i]");
        for (var b = 0; b < buttons.length; b++) {
            var label = ((buttons[b].innerText || buttons[b].value || "")).trim();
            if (label.length <= 8 && btnRe.test(label)) { btn = buttons[b]; break; }
        }
        scope = scope.parentElement;
    }
    if (btn) {
        btn.scrollIntoView({ block: "center", behavior: "instant" });
        var br = btn.getBoundingClientRect();
        return JSON.stringify({
            status: "Typed into the " + (best.isContentEditable ? "editor" : "input box"),
            submitRect: { x: br.left, y: br.top, w: br.width, h: br.height }
        });
    }
    // No visible button — many chat UIs submit on Enter.
    var enterOpts = { bubbles: true, cancelable: true, key: "Enter", code: "Enter", keyCode: 13, which: 13 };
    best.dispatchEvent(new KeyboardEvent("keydown", enterOpts));
    best.dispatchEvent(new KeyboardEvent("keypress", enterOpts));
    best.dispatchEvent(new KeyboardEvent("keyup", enterOpts));
    return JSON.stringify({ status: "Typed (pressed Enter to send)", submitRect: null });
}

// --- Agent visibility & navigation planning ---

// Extract up to `maxItems` visible links as {text, href} — lets the agent
// plan navigation ("which link goes to the settings page?") without
// dumping raw HTML.
async function __desireGetLinks(maxItems) {
    maxItems = maxItems || 50;
    var all = document.querySelectorAll("a[href]");
    var items = [];
    var seen = {};
    for (var i = 0; i < all.length && items.length < maxItems; i++) {
        var a = all[i];
        var rect = a.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) continue;
        var style = window.getComputedStyle(a);
        if (style.visibility === "hidden" || style.display === "none") continue;
        var href = a.href || "";
        if (!href || href.indexOf("javascript:") === 0) continue;
        // Same page anchors are noise for navigation planning.
        if (href.split("#")[0] === location.href.split("#")[0] && href.indexOf("#") !== -1) continue;
        var text = (a.innerText || a.getAttribute("aria-label") || a.getAttribute("title") || "")
            .trim().replace(/\s+/g, " ").substring(0, 80);
        if (!text) continue;
        var key = text + "|" + href;
        if (seen[key]) continue;
        seen[key] = true;
        items.push({ text: text, href: href.substring(0, 300) });
    }
    return JSON.stringify({ count: items.length, links: items });
}

// Scroll the target into view and flash a temporary outline so the USER can
// see which element the agent is about to act on. Purely visual — returns
// "" when nothing resolves (callers treat that as "not found").
async function __desireHighlight(selector, ref, text) {
    var el = await __desireResolveEl(selector, ref, text);
    if (!el) return "";
    el.scrollIntoView({ block: "center", behavior: "instant" });
    // Inject into the ELEMENT's document — the element may live inside a
    // same-origin iframe, whose stylesheet is separate from the main frame.
    var doc = el.ownerDocument;
    var id = "desire-highlight-style";
    if (!doc.getElementById(id)) {
        var s = doc.createElement("style");
        s.id = id;
        s.textContent = "@keyframes desireFlash{0%,100%{outline-color:rgba(255,149,0,0)}" +
            "20%,60%{outline-color:rgba(255,149,0,0.95)}40%,80%{outline-color:rgba(255,149,0,0.35)}}" +
            ".desire-flash{outline:3px solid rgba(255,149,0,0) !important;" +
            "outline-offset:2px !important;border-radius:4px !important;" +
            "animation:desireFlash 1.6s ease-in-out 2 !important;}";
        (doc.head || doc.documentElement).appendChild(s);
    }
    el.classList.add("desire-flash");
    setTimeout(function () { el.classList.remove("desire-flash"); }, 3400);
    return "Highlighted";
}

// --- Same-origin iframe penetration ---
// dom-tools.js is injected per-frame (forMainFrameOnly: false), but tools
// are invoked in the MAIN frame. These helpers let main-frame resolution
// reach elements living inside same-origin iframes (payment forms, embeds)
// and compute page-space rects with the frame offset folded in.

function __desireAllDocs() {
    var docs = [document];
    for (var i = 0; i < window.frames.length && docs.length < 6; i++) {
        try {
            var d = window.frames[i].document;
            if (d) docs.push(d);
        } catch (err) {}   // cross-origin frame — inaccessible by design
    }
    return docs;
}

// Bounding rect in PAGE coordinates: folds in same-origin frame offsets so
// trusted mouse clicks land on the right spot even inside embeds.
function __desirePageRect(el) {
    var r = el.getBoundingClientRect();
    var left = r.left, top = r.top;
    var win = el.ownerDocument.defaultView;
    while (win && win.frameElement) {
        var fr = win.frameElement.getBoundingClientRect();
        left += fr.left;
        top += fr.top;
        win = win.parent;
    }
    return { left: left, top: top, width: r.width, height: r.height };
}

async function __desireWaitForText(text, timeout) {
    timeout = timeout || 8000;
    var start = Date.now();
    return await new Promise(function (resolve) {
        function check() {
            var body = document.body ? document.body.innerText : "";
            if (body.indexOf(text) !== -1) return resolve("Found text");
            if (Date.now() - start > timeout) return resolve("Timeout waiting for text");
            setTimeout(check, 250);
        }
        check();
    });
}

// Extract every visible form field with its identity (name/id/placeholder/
// label) and — for <select> — the first options. Fields get data-desire-ref
// ids so fill {ref} targets them directly. Use before fillForm-style work.
async function __desireGetFormFields() {
    var stale = document.querySelectorAll("[data-desire-ref]");
    for (var s = 0; s < stale.length; s++) {
        try { stale[s].removeAttribute("data-desire-ref"); } catch (err0) {}
    }
    var all = document.querySelectorAll("input:not([type=hidden]), textarea, select");
    var fields = [];
    for (var i = 0; i < all.length && fields.length < 40; i++) {
        var el = all[i];
        var rect = el.getBoundingClientRect();
        if (rect.width < 4 || rect.height < 4) continue;
        var style = window.getComputedStyle(el);
        if (style.visibility === "hidden" || style.display === "none") continue;
        var refId = "f" + (fields.length + 1);
        try { el.setAttribute("data-desire-ref", refId); } catch (err) {}
        var type = el.tagName.toLowerCase();
        if (type === "input") type = "input[" + (el.type || "text") + "]";
        var label = "";
        if (el.labels && el.labels.length > 0) label = el.labels[0].innerText || "";
        if (!label) {
            var lbl = el.closest("label");
            if (lbl) label = lbl.innerText || "";
        }
        if (!label) {
            var ph = el.getAttribute("placeholder") || el.getAttribute("aria-label") || "";
            label = ph;
        }
        var entry = {
            ref: refId, tag: type,
            name: el.name || "", id: el.id || "",
            label: label.trim().replace(/\s+/g, " ").substring(0, 60),
            value: String(el.value || "").substring(0, 80),
            required: !!el.required
        };
        if (el.tagName === "SELECT") {
            var opts = [];
            for (var o = 0; o < el.options.length && o < 8; o++) {
                opts.push(el.options[o].text.trim().substring(0, 40));
            }
            entry.options = opts;
        }
        fields.push(entry);
    }
    return JSON.stringify({ count: fields.length, fields: fields });
}
