// password-detect.js
// Source: Desire/Features/Browsing/WebView.swift (BrowserState.init, passwordJS)
// Injected as: WKUserScript @ atDocumentEnd, forMainFrameOnly: false
// Detects login forms, notifies Swift of the username field name
// (`passwordDetect`), and on submit asks Swift to prompt to save credentials
// (`passwordSave`). The actual autofill happens in Swift (it injects a
// separate, templated JS snippet using the stored username/password).
(function() {
    function detectPasswordForm() {
        var pwd = document.querySelector('input[type=password]');
        if (!pwd) return;
        var form = pwd.closest('form');
        if (!form) return;
        var username = form.querySelector('input[type=text], input[type=email], input[name*=user], input[name*=email], input[name*=login], input[name*=mail], input[name*=account]');
        if (!username) username = form.querySelector('input:not([type=password]):not([type=hidden])');
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
        var username = form.querySelector('input[type=text], input[type=email], input[name*=user], input[name*=email], input[name*=mail], input[name*=login], input[name*=account]');
        if (!username) username = form.querySelector('input:not([type=password]):not([type=hidden])');
        var userVal = username ? username.value : '';
        setTimeout(function() {
            window.webkit.messageHandlers.passwordSave.postMessage({
                username: userVal,
                password: pwd.value
            });
        }, 500);
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
