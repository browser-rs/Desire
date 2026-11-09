// yt-json-prune.js — Desire 移植 uBlock Origin 的 json-prune scriptlet
// （uBO 通用能力，非自创对抗）：hook JSON.parse，把 YouTube player 响应里的
// 广告字段（adPlacements / playerAds / adSlots）剪掉后再交给页面——pre-roll
// 广告数据到不了播放器，无感去除。这层只删 JSON 属性，不做任何播放器对抗。
//
// **native 伪装（2026-11-09 用户实测 enforcement 整页弹出的主向量）**：裸替换
// `JSON.parse = function…` 后 `JSON.parse.toString()` 直接吐出 hook 源码——
// YouTube 的反拦截检测第一步就是探这个（实测 parseNative=false 即弹整页
// enforcement）。uBO 同款手法：hook Function.prototype.toString，WeakMap
// 里给每个被 hook 的函数存一份 native 样子的源码；toString 自身也要入表
// 自掩（否则探 toString.toString() 同样穿帮）。
(function() {
    if (window.__desireJSONPrune) return;
    window.__desireJSONPrune = true;

    // 共享掩护协议（yt-anti-detect 同用）：__desireMaskNative(fn, fakeSource)。
    // 先到的脚本装 maskedToString，后到的只往同一张 WeakMap 塞条目。
    if (!window.__desireMaskNative) {
        var nativeToString = Function.prototype.toString;
        var maskedSources = new WeakMap();
        var maskedToString = function() {
            var fake = maskedSources.get(this);
            return fake !== undefined ? fake : nativeToString.call(this);
        };
        maskedSources.set(maskedToString, 'function toString() { [native code] }');
        Function.prototype.toString = maskedToString;
        window.__desireMaskNative = function(fn, source) {
            try { maskedSources.set(fn, source); } catch (e) {}
        };
    }
    var maskNative = window.__desireMaskNative;

    // 剪裁目标路径：YouTube 播放器响应中的广告容器（与 uBO json-prune 参数一致）
    var PRUNE_PATHS = [
        'adPlacements', 'playerAds', 'adSlots',
        'playerResponse.adPlacements', 'playerResponse.playerAds', 'playerResponse.adSlots'
    ];

    var origParse = JSON.parse;
    function prune(obj, depth) {
        if (!obj || typeof obj !== 'object' || depth > 8) return obj;
        if (Array.isArray(obj)) {
            for (var i = 0; i < obj.length; i++) prune(obj[i], depth + 1);
            return obj;
        }
        for (var key in obj) {
            if (!Object.prototype.hasOwnProperty.call(obj, key)) continue;
            if (PRUNE_PATHS.indexOf(key) !== -1) {
                delete obj[key];
                continue;
            }
            prune(obj[key], depth + 1);
        }
        return obj;
    }

    JSON.parse = function(text, reviver) {
        var obj = origParse.apply(this, arguments);
        try {
            // 只处理可能是 YouTube player 响应的大对象（小对象零成本跳过）
            if (obj && typeof obj === 'object' &&
                (obj.adPlacements || obj.playerAds || obj.adSlots ||
                 (obj.playerResponse && typeof obj.playerResponse === 'object'))) {
                prune(obj, 0);
            }
        } catch (e) {}
        return obj;
    };
    // 替换后再入表（WeakMap key 是新函数对象）；伪造 name/长度一致性顺带保住
    maskNative(JSON.parse, 'function parse() { [native code] }');
})();
