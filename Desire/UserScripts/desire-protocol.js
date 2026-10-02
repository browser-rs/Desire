// desire-protocol.js — DPP（Desire Page Protocol）解析器。
// 每次导航后由宿主 callAsyncJavaScript 执行，返回归一化协议 JSON
// （L3 SDK > L2 声明块 > L1 data-dpp-* 属性 > L0 JSON-LD，高形态覆盖低形态）。
// 宿主把结果缓存进 BrowserState.pageProtocol，供 pageExtract/pageProtocol 工具与
// page_context 增强使用。
//
// **归一化原则**：站点照规范原文写的形态必须能用——events 对象形态
// {watch, debounce} 展平成 watch 选择器、protocol 键映射 protocolVersion；
// 降级/丢弃的字段记入 warnings 随结果返回（站点作者经 /protocol/inspect 自查）。
return (function() {
    var warnings = [];
    function empty() {
        return { protocolVersion: "desire/1", pageType: null, contentMain: null,
                 ignore: [], views: {}, signals: {}, actions: [], events: {}, context: {} };
    }

    // **显式字段映射**（勿用 for-in 泛拷贝）：声明式 JSON 的键结构与归一化
    // 结构不同（content.main → contentMain、page.type → pageType），泛拷贝
    // 会静默丢嵌套字段（实测 contentMain 丢失）。
    function normalize(src) {
        var out = empty();
        if (!src || typeof src !== "object") return out;
        if (src.protocolVersion) out.protocolVersion = src.protocolVersion;
        else if (src.protocol) out.protocolVersion = src.protocol; // 规范键名是 protocol
        if (src.page && src.page.type) out.pageType = src.page.type;
        else if (src.pageType) out.pageType = src.pageType;
        if (src.content && src.content.main) out.contentMain = src.content.main;
        else if (src.contentMain) out.contentMain = src.contentMain;
        if (Array.isArray(src.ignore)) out.ignore = src.ignore;
        if (src.views && typeof src.views === "object") out.views = src.views;
        if (src.signals && typeof src.signals === "object") out.signals = src.signals;
        if (Array.isArray(src.actions)) {
            out.actions = src.actions.map(function(a) {
                var copy = Object.assign({}, a);
                if (copy.run) copy.run = JSON.stringify(copy.run);
                return copy;
            });
        }
        if (src.events && typeof src.events === "object") {
            var evs = {};
            for (var en in src.events) {
                var ev = src.events[en];
                if (typeof ev === "string") {
                    evs[en] = ev;
                } else if (ev && typeof ev === "object" && typeof ev.watch === "string") {
                    // 规范 §4.5 的对象形态：宿主事件层统一做防抖/节流，
                    // 这里只留 watch 选择器。
                    evs[en] = ev.watch;
                    warnings.push("events." + en + ": object form flattened to watch selector (debounce/on handled by host)");
                } else if (ev != null) {
                    warnings.push("events." + en + " skipped: expected selector string or {watch}");
                }
            }
            out.events = evs;
        }
        if (src.context && typeof src.context === "object") {
            var ctx = {};
            for (var ck in src.context) {
                var cv = src.context[ck];
                if (typeof cv === "string") ctx[ck] = cv;
                else if (Array.isArray(cv)) ctx[ck] = cv.join(", ");
                else ctx[ck] = JSON.stringify(cv);
            }
            out.context = ctx;
        }
        return out;
    }

    // —— 稳定锚点：给元素打 data-dpp-* 属性，生成 document 级可求值的选择器。
    // 此前 L1 用 ':scope > …' 相对路径直接丢给 document.querySelectorAll，
    // 实测 :scope 在 document 级 = <html>，抽到的是 head（假数据）。
    var uidCounter = 0;
    function anchorFor(el, attribute) {
        var uid = 'dpp-' + (++uidCounter);
        try { el.setAttribute(attribute || 'data-dpp-uid', uid); } catch (e) { return null; }
        return '[' + (attribute || 'data-dpp-uid') + '="' + uid + '"]';
    }

    // —— L3：SDK expose（window.__desireProtocolExposed）——
    function readSDK() {
        try {
            var p = window.__desireProtocolExposed || (window.desire && window.desire.__protocol);
            if (p && typeof p === "object") {
                return normalize(p);
            }
        } catch (e) {}
        return null;
    }

    // —— L2：声明块 ——
    function readBlock() {
        try {
            var block = document.querySelector('script[type="application/x-desire+json"]');
            if (block && block.textContent.trim()) {
                return normalize(JSON.parse(block.textContent));
            }
        } catch (e) {}
        return null;
    }

    // —— L1：data-dpp-* 属性微标注 ——
    function readAttributes() {
        var containers = document.querySelectorAll('[data-dpp-view]');
        // ignore 收集先于 views 判空：只标噪音的页面也是合法的 L1。
        var ignoreSelectors = [];
        var ignores = document.querySelectorAll('[data-dpp-ignore]');
        for (var m = 0; m < ignores.length; m++) {
            var ig = ignores[m];
            var igSel = ig.id ? '#' + ig.id
                : (ig.className && typeof ig.className === 'string' && ig.className.trim()
                    ? '.' + ig.className.trim().split(/\s+/).filter(Boolean).join('.') : null);
            if (!igSel) igSel = anchorFor(ig); // 无 id 无 class → 锚点兜底
            if (igSel) ignoreSelectors.push(igSel);
        }
        if (!containers.length) {
            if (!ignoreSelectors.length) return null;
            var ignoreOnly = empty();
            ignoreOnly.ignore = ignoreSelectors;
            return ignoreOnly;
        }
        var out = empty();
        out.ignore = ignoreSelectors;
        for (var i = 0; i < containers.length; i++) {
            var c = containers[i];
            var viewName = c.getAttribute('data-dpp-view');
            if (!viewName) continue;
            var fields = {};
            var itemPath;
            if (c.hasAttribute('data-dpp-item')) {
                // 容器自身即条目：锚点就是 item。
                var selfSel = anchorFor(c);
                if (!selfSel) continue;
                itemPath = selfSel;
                var selfFieldEls = c.matches('[data-dpp-field]')
                    ? [c] : Array.prototype.slice.call(c.querySelectorAll('[data-dpp-field]'));
                fields = relativeFields(c, selfFieldEls);
            } else {
                // 条目集合：所有 data-dpp-item 元素；一个都没有则视为
                // "首子元素是模板、全部直接子元素都是条目"。给每个条目打
                // **同一个**标记，item 选择器匹配全部（此前只锚定第一个
                // 条目的 nth-child 结构路径，抽取永远只出 1 条）。
                var items = Array.prototype.slice.call(c.querySelectorAll('[data-dpp-item]'));
                if (!items.length) items = Array.prototype.slice.call(c.children);
                if (!items.length) continue;
                var tag = 'dpp-' + (++uidCounter);
                for (var t = 0; t < items.length; t++) {
                    try { items[t].setAttribute('data-dpp-items', tag); } catch (e) {}
                }
                itemPath = '[data-dpp-items="' + tag + '"]';
                fields = relativeFields(items[0],
                    items[0].matches('[data-dpp-field]')
                        ? [items[0]] : Array.prototype.slice.call(items[0].querySelectorAll('[data-dpp-field]')));
            }
            out.views[viewName] = { item: itemPath, fields: fields };
        }
        if (!Object.keys(out.views).length && !out.ignore.length) return null;
        return out;
    }

    // 字段值路径（相对 item 元素）：attr 存在 = "路径@属性"，纯文本 = 路径，
    // 字段在 item 自身 = '@text'。（:scope 在 Element 上下文 = 该元素本身，实测可用。）
    function relativeFields(item, fieldEls) {
        var fields = {};
        for (var j = 0; j < fieldEls.length; j++) {
            var f = fieldEls[j];
            var fieldName = f.getAttribute('data-dpp-field');
            var attr = f.getAttribute('data-dpp-field-attr');
            var path = [];
            var node = f;
            while (node && node !== item) {
                var p = node.parentElement;
                var idx = p ? Array.prototype.indexOf.call(p.children, node) + 1 : 1;
                path.unshift(':scope > *:nth-child(' + idx + ')');
                node = p;
            }
            var rel = path.join('');
            fields[fieldName] = attr ? (rel + '@' + attr) : (rel || '@text');
        }
        return fields;
    }

    // —— L0：JSON-LD 隐式视图 ——
    function readJSONLD() {
        var blocks = document.querySelectorAll('script[type="application/ld+json"]');
        if (!blocks.length) return null;
        var items = [];
        for (var i = 0; i < blocks.length; i++) {
            try {
                var parsed = JSON.parse(blocks[i].textContent);
                var graph = Array.isArray(parsed) ? parsed : (parsed["@graph"] || [parsed]);
                items = items.concat(graph);
            } catch (e) {}
        }
        if (!items.length) return null;
        var out = empty();
        for (var k = 0; k < items.length; k++) {
            var it = items[k];
            var type = it && it["@type"];
            if (type === "Product") {
                // 字段值 = 逗号分隔的候选回退（首个命中者胜，抽取端按序尝试）。
                out.views["product"] = { item: '[itemtype*="schema.org/Product"], [itemtype*="schema.org/product"]',
                    fields: { title: 'meta[itemprop="name"]@content, [itemprop="name"]',
                              price: 'meta[itemprop="price"]@content, [itemprop="price"]' } };
                // JSON-LD 数据本身内联为字段值兜底（DOM 缺 itemprop 时可用）。
                out.context = out.context || {};
                out.context["productJSONLD"] = JSON.stringify({ name: it.name, price: it.offers && it.offers.price,
                    currency: it.offers && it.offers.priceCurrency, description: it.description });
            } else if (type === "Article" || type === "NewsArticle" || type === "BlogPosting") {
                out.views["article"] = { item: '[itemtype*="schema.org/Article"], article',
                    fields: { title: 'meta[property="og:title"]@content, h1',
                              text: 'meta[property="og:description"]@content' } };
                out.context = out.context || {};
                out.context["articleJSONLD"] = JSON.stringify({ headline: it.headline,
                    text: (it.articleBody || it.description || "").slice(0, 2000),
                    author: it.author && it.author.name, date: it.datePublished });
            }
        }
        if (!Object.keys(out.views).length) return null;
        return out;
    }

    var merged = readSDK() || readBlock() || readAttributes() || readJSONLD();
    // **事件监听**：按 merged.events 声明安装 MutationObserver → postMessage
    // 给宿主 → PageEventHub → 事件驱动回合。
    // 语义 = **匹配数由 0 变正的跳变**（transition）而不是"匹配存在期间的每次
    // DOM 变动"——后者在聊天页是消息风暴（宿主只有 3s debounce 兜底）。
    if (merged && Object.keys(merged.events || {}).length) {
        window.__dppEventObserver = window.__dppEventObserver || null;
        if (window.__dppEventObserver) window.__dppEventObserver.disconnect();
        window.__dppEventState = window.__dppEventState || {};
        window.__dppEventState = {}; // 新协议 = 重置跳变基线
        var lastPost = 0;
        window.__dppEventObserver = new MutationObserver(function(mutations) {
            var now = Date.now();
            var throttled = (now - lastPost) < 500;
            var posted = false;
            for (var eventName in merged.events) {
                var sel = merged.events[eventName];
                var matched = false;
                try {
                    matched = document.querySelectorAll(sel).length > 0;
                } catch (e) { continue; }
                var was = !!window.__dppEventState[eventName];
                window.__dppEventState[eventName] = matched;
                // 只在 0 → >0 跳变时上报；节流窗口内跳过但保留基线更新
                //（否则窗口内的真跳变会被永久吞掉）。
                if (matched && !was && !throttled && !posted) {
                    posted = true;
                    lastPost = now;
                    try {
                        window.webkit.messageHandlers.desireProtocolEvent.postMessage({
                            host: location.host,
                            eventName: eventName,
                            detail: { selector: sel, url: location.href }
                        });
                    } catch (e) {}
                }
            }
        });
        window.__dppEventObserver.observe(document.body || document.documentElement, {
            childList: true, subtree: true, attributes: true, characterData: true
        });
    }

    if (merged) {
        merged.warnings = warnings;
        delete merged.revisedAt;
    }
    return JSON.stringify(merged || null);
})()
