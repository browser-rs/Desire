// desire-protocol.js — DPP（Desire Page Protocol）解析器。
// 每次导航后由宿主 callAsyncJavaScript 执行，返回归一化协议 JSON
// （L3 SDK > L2 声明块 > L1 data-dpp-* 属性 > L0 JSON-LD，高形态覆盖低形态）。
// 宿主把结果缓存进 BrowserState.pageProtocol，供 pageExtract/pageProtocol 工具与
// page_context 增强使用。
return (function() {
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
        if (src.events && typeof src.events === "object") out.events = src.events;
        if (src.context && typeof src.context === "object") out.context = src.context;
        return out;
    }

    // —— L3：SDK expose（window.__desireProtocolExposed）——
    function readSDK() {
        try {
            var p = window.__desireProtocolExposed || (window.desire && window.desire.__protocol);
            if (p && typeof p === "object") {
                var out = normalize(p);
                out.__form = "sdk";
                return out;
            }
        } catch (e) {}
        return null;
    }

    // —— L2：声明块 ——
    function readBlock() {
        try {
            var block = document.querySelector('script[type="application/x-desire+json"]');
            if (block && block.textContent.trim()) {
                var out = normalize(JSON.parse(block.textContent));
                out.__form = "block";
                return out;
            }
        } catch (e) {}
        return null;
    }

    // —— L1：data-dpp-* 属性微标注 ——
    function readAttributes() {
        var containers = document.querySelectorAll('[data-dpp-view]');
        if (!containers.length) return null;
        var out = empty();
        for (var i = 0; i < containers.length; i++) {
            var c = containers[i];
            var viewName = c.getAttribute('data-dpp-view');
            var itemSel = c.hasAttribute('data-dpp-item') ? c : (c.querySelector('[data-dpp-item]') || c.firstElementChild);
            var itemPath = '';
            if (c.hasAttribute('data-dpp-item')) {
                itemSel = c; itemPath = '';
            } else if (itemSel) {
                var seg = [];
                var node = itemSel;
                while (node && node !== c) {
                    var parent = node.parentElement;
                    var idx = parent ? Array.prototype.indexOf.call(parent.children, node) + 1 : 1;
                    seg.unshift(':scope > *:nth-child(' + idx + ')');
                    node = parent;
                }
                itemPath = ':scope' + seg.join('');
            }
            var item = itemSel || c.firstElementChild;
            if (!item) continue;
            var fields = {};
            // 字段 = 首个 item 子树内带 data-dpp-field 的元素；字段值路径相对 item。
            var fieldEls = item.matches('[data-dpp-field]')
                ? [item] : Array.prototype.slice.call(item.querySelectorAll('[data-dpp-field]'));
            for (var j = 0; j < fieldEls.length; j++) {
                var f = fieldEls[j];
                var fieldName = f.getAttribute('data-dpp-field');
                var attr = f.getAttribute('data-dpp-field-attr');
                var path = [];
                var node2 = f;
                while (node2 && node2 !== item) {
                    var p2 = node2.parentElement;
                    var idx2 = p2 ? Array.prototype.indexOf.call(p2.children, node2) + 1 : 1;
                    path.unshift(':scope > *:nth-child(' + idx2 + ')');
                    node2 = p2;
                }
                var rel = path.join('');
                fields[fieldName] = attr ? (rel + '@' + attr) : (rel || '@text');
            }
            out.views[viewName] = { item: itemPath || '*', fields: fields };
        }
        var ignores = document.querySelectorAll('[data-dpp-ignore]');
        for (var m = 0; m < ignores.length; m++) {
            var ig = ignores[m];
            var igSel = ig.id ? '#' + ig.id
                : (ig.className && typeof ig.className === 'string'
                    ? '.' + ig.className.trim().split(/\\s+/).join('.') : null);
            if (igSel) out.ignore.push(igSel);
        }
        if (!Object.keys(out.views).length && !out.ignore.length) return null;
        out.__form = "attributes";
        return out;
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
        out.__form = "jsonld";
        return out;
    }

    var merged = readSDK() || readBlock() || readAttributes() || readJSONLD();
    // **事件监听**：按 merged.events 声明安装 MutationObserver →
    // postMessage 给宿主 → PageEventHub → 事件驱动回合。
    if (merged && Object.keys(merged.events || {}).length) {
        window.__dppEventObserver = window.__dppEventObserver || null;
        if (window.__dppEventObserver) window.__dppEventObserver.disconnect();
        var observedSelectors = Object.values(merged.events).map(function(e) { return e; });
        var allSel = observedSelectors.join(", ");
        window.__dppEventObserver = new MutationObserver(function(mutations) {
            for (var eventName in merged.events) {
                var sel = merged.events[eventName];
                try {
                    var els = document.querySelectorAll(sel);
                    if (els.length > 0) {
                        window.webkit.messageHandlers.desireProtocolEvent.postMessage({
                            host: location.host,
                            eventName: eventName,
                            detail: { selector: sel, matchCount: els.length }
                        });
                    }
                } catch (e) {}
            }
        });
        window.__dppEventObserver.observe(document.body || document.documentElement, {
            childList: true, subtree: true, attributes: true, characterData: true
        });
    }

    if (merged) { delete merged.__form; delete merged.revisedAt; }
    return JSON.stringify(merged || null);
})()
