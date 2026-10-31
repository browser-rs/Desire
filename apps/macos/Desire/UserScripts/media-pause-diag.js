// media-pause-diag.js — 暂停来源 oracle（v0.8.32 起常驻，自动播放专项的可观测层）
// 只记 **PAUSE**（含调用栈），PLAY 不记（正常起播无信息量）——每次"播一下
// 马上暂停/切回卡暂停"复发都会留下第一现场：谁按的暂停、哪个元素、什么状态。
// 经 console-intercept 汇入 DevTools store（桥 /devtools 可读），复发时先查这里。
(function () {
    'use strict';
    if (window.__desirePauseDiag) return;
    window.__desirePauseDiag = true;

    function shortStack() {
        var stack = (new Error().stack || '').split('\n')
            .filter(function (l) { return l.indexOf('media-pause-diag') === -1; })
            .slice(1, 7).map(function (l) { return l.trim().slice(0, 160); });
        return stack.join(' | ');
    }

    function tag(v) {
        var r = v.getBoundingClientRect ? v.getBoundingClientRect() : { width: 0, height: 0 };
        return (v.id || v.className || 'video').toString().slice(0, 40) +
            ' ' + Math.round(r.width) + 'x' + Math.round(r.height) +
            ' t=' + (v.currentTime || 0).toFixed(1) +
            ' muted=' + v.muted + ' vis=' + document.visibilityState;
    }

    function report(kind, v, stack) {
        var detail = 'tag={' + tag(v) + '} stack=' + stack;
        console.error('[desire-diag] ' + kind.toUpperCase() + ' ' + detail);
        try {
            window.webkit.messageHandlers.mediaPipelineEvent.postMessage({
                kind: kind, detail: detail, stack: stack,
            });
        } catch (e) {}
    }

    var originalPause = HTMLMediaElement.prototype.pause;
    HTMLMediaElement.prototype.pause = function () {
        var v = this;
        report('pause', v, shortStack());
        return originalPause.apply(this, arguments);
    };

    // play() 被拒（NotAllowedError）= WebKit consent 拦截——恢复路径卡暂停
    // 的直接信号，pause 事件之前就能抓到。
    var originalPlay = HTMLMediaElement.prototype.play;
    HTMLMediaElement.prototype.play = function () {
        var v = this;
        var result = originalPlay.apply(this, arguments);
        if (result && result.catch) {
            result.catch(function (err) {
                report('consent-blocked', v,
                    (err && err.name) + ': ' + (err && err.message || '').slice(0, 80) +
                    ' | ' + shortStack());
            });
        }
        return result;
    };

    // pause 事件（非方法调用路径，比如 WebKit 内部直接改 paused）也留痕。
    document.addEventListener('pause', function (e) {
        var t = e.target;
        if (!(t instanceof HTMLMediaElement)) return;
        console.error('[desire-diag] PAUSE-EVENT tag={' + tag(t) + '}');
    }, true);
})();
