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
        return { protocolVersion: "desire/1", profile: null, pageType: null, contentMain: null, sections: {},
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
        if (typeof src.profile === "string") out.profile = src.profile;
        if (src.page && src.page.type) out.pageType = src.page.type;
        else if (src.pageType) out.pageType = src.pageType;
        if (src.content && src.content.main) out.contentMain = src.content.main;
        else if (src.contentMain) out.contentMain = src.contentMain;
        if (Array.isArray(src.ignore)) out.ignore = src.ignore;
        else if (src.content && Array.isArray(src.content.ignore)) out.ignore = src.content.ignore; // 规范 §4.1：ignore 在 content 内
        // 规范 §4.3：content.sections（命名分区，值 = 选择器字符串）。非字符串值丢弃记 warning。
        if (src.content && src.content.sections && typeof src.content.sections === "object") {
            var secs = {};
            for (var sn in src.content.sections) {
                var sv = src.content.sections[sn];
                if (typeof sv === "string") secs[sn] = sv;
                else warnings.push("content.sections." + sn + " skipped: selector must be a string");
            }
            if (Object.keys(secs).length) out.sections = secs;
        } else if (src.sections && typeof src.sections === "object") {
            out.sections = src.sections; // 已平铺形态（站点级 well-known 直喂）
        }
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

    // —— shadow DOM 支持（L1 扫描进 open shadow root）：
    // roots 递归收集 document 与所有可达的 open shadowRoot；
    // dppPath 生成跨边界选择器（`>>>` = 下钻 shadow root），供
    // __desireQueryAll（agentToolWorld）求值。
    function dppAllRoots() {
        var roots = [document];
        for (var r = 0; r < roots.length; r++) {
            var els = roots[r].querySelectorAll('*');
            for (var i = 0; i < els.length; i++) {
                if (els[i].shadowRoot) roots.push(els[i].shadowRoot);
            }
        }
        return roots;
    }
    function dppPath(el) {
        var parts = [];
        var node = el;
        while (node && node.nodeType === 1 && node !== document.documentElement) {
            var root = node.getRootNode();
            var host = root && root.host;
            var parent = node.parentNode;
            var idx = parent ? Array.prototype.indexOf.call(parent.children, node) + 1 : 1;
            var seg = node.tagName.toLowerCase() + ':nth-child(' + idx + ')';
            if (host) { parts.unshift('>>> ' + seg); node = host; }
            else { parts.unshift('> ' + seg); node = parent; }
        }
        return 'html' + (parts.length ? ' ' + parts.join(' ') : '');
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
        // 清掉上一次解析留下的锚点（SPA 同文档重解析时旧 data-dpp-items/uid
        // 会残留，重打编号后选择器可能同时匹配新旧两批元素）。
        try {
            document.querySelectorAll('[data-dpp-uid],[data-dpp-items]').forEach(function(el) {
                el.removeAttribute('data-dpp-uid');
                el.removeAttribute('data-dpp-items');
            });
        } catch (e) {}
        var roots = dppAllRoots();
        function queryAllRoots(sel) {
            var out = [];
            for (var ri = 0; ri < roots.length; ri++) {
                try { out = out.concat(Array.prototype.slice.call(roots[ri].querySelectorAll(sel))); } catch (e) {}
            }
            return out;
        }
        var containers = queryAllRoots('[data-dpp-view]');
        // ignore 收集先于 views 判空：只标噪音的页面也是合法的 L1。
        var ignoreSelectors = [];
        var ignores = queryAllRoots('[data-dpp-ignore]');
        for (var m = 0; m < ignores.length; m++) {
            var ig = ignores[m];
            var igSel = ig.id ? '#' + ig.id
                : (ig.className && typeof ig.className === 'string' && ig.className.trim()
                    ? '.' + ig.className.trim().split(/\s+/).filter(Boolean).join('.') : null);
            if (!igSel || ig.getRootNode() !== document) igSel = dppPath(ig); // shadow/跨边界 → 路径
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
                if (!items.length) {
                    warnings.push("view '" + viewName + "': container has no item elements, skipped");
                    continue;
                }
                if (items[0].getRootNode() !== document) {
                    // 条目在 shadow root 内：data-dpp-items 跨边界不可查——
                    // 生成跨边界路径 `container >>> 相对段`（__desireQueryAll 求值）
                    var rel = [];
                    for (var t2 = 0; t2 < items.length; t2++) {
                        try { items[t2].setAttribute('data-dpp-items', 'rel'); } catch (e) {}
                    }
                    var cpath = dppPath(c);
                    itemPath = cpath + ' >>> [data-dpp-items="rel"]';
                } else {
                    var tag = 'dpp-' + (++uidCounter);
                    for (var t = 0; t < items.length; t++) {
                        try { items[t].setAttribute('data-dpp-items', tag); } catch (e) {}
                    }
                    itemPath = '[data-dpp-items="' + tag + '"]';
                }
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
            }
        if (type === "Article" || type === "NewsArticle" || type === "BlogPosting") {
                out.views["article"] = { item: '[itemtype*="schema.org/Article"], article',
                    fields: { title: 'meta[property="og:title"]@content, h1',
                              text: 'meta[property="og:description"]@content' } };
                out.context = out.context || {};
                out.context["articleJSONLD"] = JSON.stringify({ headline: it.headline,
                    text: (it.articleBody || it.description || "").slice(0, 2000),
                    author: it.author && it.author.name, date: it.datePublished });
            }
        }
        // schema.org potentialAction → DPP actions（L0 消费：大量站点已声明
        // 机器可读动作，规范 §3.1）。对**所有** @type 生效；URL target 映射为
        // navigate 步骤，占位符 → params（pageAction 模板填充）。
        for (var k2 = 0; k2 < items.length; k2++) {
            var it2 = items[k2];
            var pa = it2 && it2.potentialAction;
            var paList = Array.isArray(pa) ? pa : (pa ? [pa] : []);
            for (var pi = 0; pi < paList.length; pi++) {
                var act = paList[pi];
                if (!act || typeof act !== 'object') continue;
                var at = (typeof act['@type'] === 'string') ? act['@type'] : '';
                var target = (typeof act.target === 'string') ? act.target
                    : (act.target && typeof act.target === 'object' && typeof act.target.urlTemplate === 'string' ? act.target.urlTemplate : null);
                var base = at.replace(/Action$/, '').toLowerCase();
                var nm = (typeof act.name === 'string' && act.name) ? act.name : base;
                if (!nm || !target || typeof target !== 'string') continue;
                if (out.actions.some(function(x){ return x.name === nm; })) continue;
                var params = {};
                (target.match(/\{([^}]+)\}/g) || []).forEach(function(ph){
                    var key = ph.slice(1, -1);
                    params[key] = { type: 'string', description: 'placeholder from potentialAction target' };
                });
                out.actions.push({
                    name: nm,
                    description: (typeof act.description === 'string' && act.description) || 'site-declared potentialAction (' + (at || 'Action') + ')',
                    params: params,
                    run: [{ navigate: target }],
                    effects: 'local'
                });
            }
        }
        // actions-only 的页面（如 WebSite + potentialAction）也保留
        if (!Object.keys(out.views).length && !out.actions.length) return null;
        return out;
    }

    var merged = readSDK() || readBlock() || readAttributes() || readJSONLD();
    // 宿主注入的站点级 events（/.well-known/desire.json，经 callAsyncJavaScript
    // 参数传入）：补进页面声明没覆盖的键，与页面级**一起**装 observer——
    // 站点级 monitor 事件由此获得自动回合能力（此前 merge 只进了展示/命中
    // 检查，observer 不装，站点级事件永远不会触发回合）。
    if (typeof hostExtraEvents === 'string' && hostExtraEvents) {
        try {
            var extraEvents = JSON.parse(hostExtraEvents);
            if (extraEvents && typeof extraEvents === 'object') {
                if (!merged) merged = empty();
                for (var extraKey in extraEvents) {
                    if (!(extraKey in merged.events)) {
                        merged.events[extraKey] = extraEvents[extraKey];
                        warnings.push("events." + extraKey + ": from site-level protocol");
                    }
                }
            }
        } catch (e) {}
    }
    // **事件监听**：按 merged.events 声明安装 MutationObserver → postMessage
    // 给宿主 → PageEventHub → 事件驱动回合。
    // 语义 = **匹配数由 0 变正的跳变**（transition）而不是"匹配存在期间的每次
    // DOM 变动"——后者在聊天页是消息风暴（宿主只有 3s debounce 兜底）。
    if (merged && Object.keys(merged.events || {}).length) {
        window.__dppEventObserver = window.__dppEventObserver || null;
        if (window.__dppEventObserver) window.__dppEventObserver.disconnect();
        window.__dppEventState = window.__dppEventState || {};
        window.__dppEventState = {}; // 新协议 = 重置跳变基线
        // 跳变即发，**不做 JS 侧节流**——此前的 500ms 全局节流会把窗口内的
        // 第二个跳变永久吞掉（state 已更新、消息没发、0→正不再满足）。风暴
        // 防护由宿主负责：同事件 3s 防抖 + 单 host 60s 滑窗限频（PageEventHub）。
        window.__dppEventObserver = new MutationObserver(function(mutations) {
            for (var eventName in merged.events) {
                var sel = merged.events[eventName];
                var matched = false;
                try {
                    matched = document.querySelectorAll(sel).length > 0;
                } catch (e) { continue; }
                var was = !!window.__dppEventState[eventName];
                window.__dppEventState[eventName] = matched;
                if (matched && !was) {
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
