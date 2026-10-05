// cookie-banner-guard.js
// Source: Desire/Features/Privacy/CookieBannerGuard.swift（偏好由注入时内插）
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false, page world
// Cookie 弹窗自动处理（0.6.5 轻量版）：按已知 CMP 词表识别同意弹窗，
// 按用户偏好自动点击「拒绝全部」或「接受全部」，命中后经
// cookieGuardHandled 消息通道告知宿主出提示条。
//
// 边界（诚实口径）：
//  - 词表覆盖主流 CMP（OneTrust/CookieBot/Complianz/Usercentrics 及
//    cookie/banner/gdpr 关键词的通用形态）；iframe 内的 CMP 由
//    forMainFrameOnly:false 覆盖；自绘非标按钮可能漏——漏了就当没这功能。
//  - 只点击按钮，不注入样式遮罩；点击失败不重试（每页一次机会，防循环）。
(function() {
    "use strict";
    if (window.__desireCookieGuard) return;
    window.__desireCookieGuard = true;

    var PREF = window.__desireCookiePref || "off"; // off | reject | accept
    if (PREF === "off") return;

    var handled = false;

    // 已知 CMP 的容器/按钮选择器词表（小写匹配）
    var CONTAINER_HINTS = ["onetrust", "cookiebot", "cybot", "complianz", "usercentrics",
                           "cookieconsent", "cookie-banner", "cookie_banner", "cookiebanner",
                           "gdpr", "consent", "cmpliance", "borlabs"];

    function isConsentContainer(el) {
        var id = (el.id || "").toLowerCase();
        var cls = (el.className && el.className.toLowerCase) ? String(el.className).toLowerCase() : "";
        for (var i = 0; i < CONTAINER_HINTS.length; i++) {
            if (id.indexOf(CONTAINER_HINTS[i]) !== -1 || cls.indexOf(CONTAINER_HINTS[i]) !== -1) return true;
        }
        return false;
    }

    function clickableIn(el) {
        return el.querySelectorAll('button, input[type="button"], a[role="button"], [role="button"]');
    }

    function findButton(kind) {
        // kind = reject | accept：优先词表容器内找，找不到退全页扫（限 CMP 词）
        var roots = [];
        document.querySelectorAll('div, aside, section, dialog').forEach(function (el) {
            if (isConsentContainer(el) && el.offsetParent !== null) roots.push(el);
        });
        var scopes = roots.length ? roots : [document];
        var rejectWords = ["reject all", "reject", "deny", "decline", "拒绝全部", "拒绝"];
        var acceptWords = ["accept all", "accept", "allow all", "allow", "同意全部", "接受"];
        var words = kind === "reject" ? rejectWords : acceptWords;
        for (var s = 0; s < scopes.length; s++) {
            var candidates = clickableIn(scopes[s]);
            for (var i = 0; i < candidates.length; i++) {
                var btn = candidates[i];
                if (btn.offsetParent === null) continue;
                var label = ((btn.textContent || "") + " " + (btn.id || "") + " " +
                             (btn.className && btn.className.toLowerCase ? String(btn.className).toLowerCase() : "")).toLowerCase();
                for (var w = 0; w < words.length; w++) {
                    if (label.indexOf(words[w]) !== -1) return btn;
                }
            }
        }
        return null;
    }

    function attempt() {
        if (handled || PREF === "off") return;
        var btn = findButton(PREF);
        if (!btn && PREF === "reject") btn = findButton("reject"); // 双保险（同 kind）
        if (!btn) return;
        handled = true;
        try { btn.click(); } catch (e) { return; }
        try {
            window.webkit.messageHandlers.cookieGuardHandled.postMessage({
                pref: PREF,
                label: (btn.textContent || "").trim().substring(0, 60)
            });
        } catch (e) { /* 宿主通道缺席静默 */ }
    }

    // CMP 懒加载：首批扫描 + DOM 变化 8s 内补扫（每页一次机会防循环）
    var observer = new MutationObserver(function () { attempt(); });
    document.addEventListener("DOMContentLoaded", function () {
        attempt();
        observer.observe(document.body, { childList: true, subtree: true });
        setTimeout(function () { observer.disconnect(); }, 8000);
    });
    setTimeout(attempt, 1500);
})();
