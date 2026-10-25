// password-detect.js
// Source: Desire/Features/Browsing/WebView.swift (BrowserState.init, passwordJS)
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false
// Detects login forms, notifies Swift of the username field name
// (`passwordDetect`), and on submit asks Swift to prompt to save credentials
// (`passwordSave`). The actual autofill happens in Swift (it injects a
// separate, templated JS snippet using the stored username/password).
(function() {
    // 字段识别容错（v0.8.8 基础件 4）：autocomplete → name/id 关键词 →
    // placeholder → 相邻 label 文本，逐档打分取最高；scope 兜底 div 登录
    // 布局（不少站点登录框不在 <form> 里，此前完全不触发检测）。
    function scoreUsernameField(el) {
        var s = 0;
        var ac = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (ac === 'username' || ac === 'email') s += 8;
        var key = (el.name + ' ' + (el.id || '')).toLowerCase();
        if (/user|email|login|mail|account|phone|mobile/.test(key)) s += 4;
        var ph = (el.getAttribute('placeholder') || '').toLowerCase();
        if (/user|email|login|mail|account|手机|邮箱|账号|用户/.test(ph)) s += 2;
        var lb = el.labels && el.labels[0] ? el.labels[0].textContent.toLowerCase() : '';
        if (/user|email|login|mail|account|手机|邮箱|账号|用户/.test(lb)) s += 2;
        var type = (el.getAttribute('type') || 'text').toLowerCase();
        if (type === 'email') s += 2;
        return s;
    }
    function pickUsername(scope, pwd) {
        var best = null, bestScore = -1;
        var fields = scope.querySelectorAll(
            'input:not([type=password]):not([type=hidden]):not([type=submit]):not([type=button]):not([type=checkbox]):not([type=radio])');
        for (var i = 0; i < fields.length; i++) {
            var f = fields[i];
            // 只取密码框之前的可见文本框（登录布局里账号在前；跳过被藏起来的字段）。
            if (pwd.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_FOLLOWING) continue;
            if (!(f.offsetWidth || f.offsetHeight || f.getClientRects().length)) continue;
            var sc = scoreUsernameField(f);
            if (sc > bestScore) { bestScore = sc; best = f; }
        }
        return best;
    }
    function detectPasswordForm() {
        var pwd = document.querySelector('input[type=password]');
        if (!pwd) return;
        var form = pwd.closest('form');
        // div 登录布局兜底：无 form 时退到最近块容器；再退 document。
        var scope = form || pwd.closest('div,section') || document;
        var username = pickUsername(scope, pwd);
        return { form: form, pwd: pwd, username: username };
    }
    /* Auto-fill detection */
    function detectLoginForm() {
        var r = detectPasswordForm();
        if (!r || !r.username) return;
        window.webkit.messageHandlers.passwordDetect.postMessage({
            username: r.username.name || r.username.id || 'username'
        });
    }
    /* Save-prompt: listen for form submit */
    document.addEventListener('submit', function(e) {
        var form = e.target;
        var pwd = form.querySelector('input[type=password]');
        if (!pwd || !pwd.value) return;
        var scope = form || e.target.closest('div,section') || document;
        var pwdAny = form ? pwd : document.querySelector('input[type=password]');
        var username = pwdAny ? pickUsername(scope, pwdAny) : null;
        var userVal = username ? username.value : '';
        // P1：值在 submit 时已捕获——立即 post（原 500ms 定时器在快速登录时
        // 随旧文档一起销毁，保存提示时灵时不灵）。
        window.webkit.messageHandlers.passwordSave.postMessage({
            username: userVal,
            password: pwd.value,
            // 提交**发起页**的 origin：submit 会触发导航，Swift 收到消息时
            // 读 webView.url 已是新页——凭据会被记到别的域名下。
            origin: location.origin
        });
    }, true);
    /* OTP 检测（0.3.6）：验证码输入框出现时通知宿主弹提示条。 */
    function detectOTPField() {
        var el = document.querySelector(
            "input[autocomplete=one-time-code], input[name*=otp i], input[id*=otp i]," +
            "input[name*=onetime i], input[autocomplete*=one-time-code]");
        if (el) {
            window.webkit.messageHandlers.otpDetect.postMessage({
                field: el.name || el.id || "verification code"
            });
            return;
        }
        setTimeout(detectOTPField, 1500);
    }
    document.addEventListener('DOMContentLoaded', function() {
        detectLoginForm();
        detectOTPField();
    });
    setTimeout(detectLoginForm, 1000);
    setTimeout(detectOTPField, 1200);
})();
