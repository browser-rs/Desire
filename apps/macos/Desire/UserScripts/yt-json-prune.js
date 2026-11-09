// yt-json-prune.js — 剪掉 YouTube player 响应里的广告容器字段（pre-roll 去掉）。
//
// **2026-11-10 重写：不再 hook JSON.parse。** YouTube 的反拦截套件（页面 bundle
// 里 `WJF` → 16 个探针，检测结果经 `bkaEnforcementMessageViewModel` 下发）里有
// 两条 canary 直接打这个手法：
//   · m9m（j.s_）：`JSON.parse(jsonRepresentation)` 后与页面自己手里的
//     `objectRepresentation` 做深度比对（Oz）。canary 里 adPlacements / playerAds
//     是**真实形态的非空数组**，任何"解析时删键"的 hook 都会比对失败 → 判定拦截。
//   · LVo（r.s_）：同一组 canary 走 `new Response(...).json()` 再来一遍。
// 结论：**只要在 JSON.parse 语义上做删键，就必然被检出**——canary 与真实响应同形
// （responseContext / playabilityStatus / streamingData / adPlacements 全有），
// 靠形状或数组判据都区分不开。
//
// 现方案（只在数据入口动，不碰任何全局解析语义）：
//   ① 文档内嵌的 `window.ytInitialPlayerResponse`：DOMContentLoaded 时原地删
//      adPlacements / playerAds / adSlots（对象是页面自己的，属性正常可删，
//      没有 defineProperty 陷阱——陷阱本身才是上一版被检出的原因）。
//   ② SPA 导航/播放器刷新走的 `fetch('/youtubei/v1/player')`：包一层 Proxy，
//      用**响应的真实 URL**（`response.url`，不是请求对象的可伪造 getter）判定，
//      克隆后解析、删键、重建 Response 返回。canary 的 fetch 走 data: URL，
//      response.url 不匹配 → 原样放行（ojo 探针读到的仍是完整对象）。
//   ③ 用 Proxy 而不是替换函数 + Function.prototype.toString 伪装：代理对象的
//      `fn.toString()` 天然是 `function () { [native code] }`，不必再污染全局
//      toString（全局 toString 伪装本身就是可探的改动面）。
(function() {
    if (window.__desireJSONPrune) return;
    window.__desireJSONPrune = true;

    var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots'];

    // 真实 player 响应才有这些字段；canary 也伪造了它们，所以这里只用于
    // "别误删用户数据对象"，不作为检测对抗的判据。
    function looksLikePlayerResponse(obj) {
        if (!obj || typeof obj !== 'object') return false;
        return !!(obj.playabilityStatus || obj.videoDetails || obj.streamingData ||
                  obj.responseContext);
    }

    function pruneAds(obj) {
        var removed = 0;
        for (var i = 0; i < AD_KEYS.length; i++) {
            var key = AD_KEYS[i];
            if (Object.prototype.hasOwnProperty.call(obj, key)) {
                try {
                    delete obj[key];
                    removed++;
                } catch (e) {}
            }
        }
        return removed;
    }

    function prunePlayerResponse(root) {
        if (!root || typeof root !== 'object') return 0;
        var removed = 0;
        // playerResponse.adPlacements（watch/next 响应里的嵌套形态）
        var nested = root.playerResponse;
        if (nested && typeof nested === 'object' && looksLikePlayerResponse(nested)) {
            removed += pruneAds(nested);
        }
        if (looksLikePlayerResponse(root)) removed += pruneAds(root);
        return removed;
    }

    // ── ① 文档内嵌的 ytInitialPlayerResponse ──────────────────────────
    function pruneInitial() {
        try {
            prunePlayerResponse(window.ytInitialPlayerResponse);
        } catch (e) {}
    }
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', pruneInitial, { once: true });
    } else {
        pruneInitial();
    }

    // ── ② fetch /youtubei/v1/player 响应 ─────────────────────────────
    // 用**绑定的命名函数**而不是 Proxy：JSC 对 bound function 的
    // `String(fn)` 输出 `function fetch() { [native code] }`，且 bound 函数
    // 没有 prototype（与原生 fetch 同形）；Proxy 会暴露 `function ProxyObject()`。
    var nativeFetch = window.fetch;
    if (typeof nativeFetch === 'function') {
        var wrapped = (function fetch(input) {
            return nativeFetch.apply(this, arguments).then(function(res) {
                try {
                    // 只认响应自己报告的 URL：canary（ojo）用 data: URL 发请求、
                    // 只是把请求对象的 url getter 伪造成 player 端点。
                    var url = (res && res.url) || '';
                    if (typeof url !== 'string' ||
                        !/\/youtubei\/v1\/player(\?|$)/.test(url)) {
                        return res;
                    }
                    return res.clone().text().then(function(text) {
                        var data;
                        try { data = JSON.parse(text); } catch (e) { return res; }
                        if (!data || typeof data !== 'object') return res;
                        if (prunePlayerResponse(data) === 0) return res;
                        var out = new Response(JSON.stringify(data), {
                            status: res.status,
                            statusText: res.statusText,
                            headers: res.headers
                        });
                        // 构造的 Response 没有 url；播放器若读它，补成真值。
                        try {
                            Object.defineProperty(out, 'url', { value: res.url });
                        } catch (e) {}
                        return out;
                    }, function() { return res; });
                } catch (e) {
                    return res;
                }
            });
        }).bind(undefined);
        try { Object.defineProperty(wrapped, 'name', { value: 'fetch' }); } catch (e) {}
        try { Object.defineProperty(wrapped, 'length', { value: 1 }); } catch (e) {}
        window.fetch = wrapped;
    }
})();
