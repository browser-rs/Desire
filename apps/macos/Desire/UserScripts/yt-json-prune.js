// yt-json-prune.js — Desire 移植 uBlock Origin 的 json-prune scriptlet
// （uBO 通用能力，非自创对抗）：hook JSON.parse，把 YouTube player 响应里的
// 广告字段（adPlacements / playerAds / adSlots）剪掉后再交给页面——pre-roll
// 广告数据到不了播放器，无感去除。这层只删 JSON 属性，不做任何播放器对抗。
(function() {
    if (window.__desireJSONPrune) return;
    window.__desireJSONPrune = true;

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
})();
