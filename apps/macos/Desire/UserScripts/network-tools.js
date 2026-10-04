// --- 网络依赖工具（页面世界专属）：__desireWaitForNetworkIdle 猴补页面世界
// 的 XHR/fetch——隔离世界补丁拦不到页面请求（getNetworkLog 已原生化，
// 改读 DevToolsStore，不再依赖页面世界状态）。

async function __desireWaitForNetworkIdle({timeout, quietMs}) {
    quietMs = quietMs || 500;
    var start = Date.now();
    var lastActivity = Date.now();
    var inflight = 0;
    var origOpen = XMLHttpRequest.prototype.open;
    var origSend = XMLHttpRequest.prototype.send;
    try {
        XMLHttpRequest.prototype.open = function () {
            this.addEventListener("loadstart", function () { inflight++; lastActivity = Date.now(); });
            this.addEventListener("loadend", function () { inflight--; lastActivity = Date.now(); });
            return origOpen.apply(this, arguments);
        };
    } catch (e) {}
    var origFetch = window.fetch;
    try {
        window.fetch = function () {
            inflight++; lastActivity = Date.now();
            return origFetch.apply(this, arguments).finally(function () {
                inflight--; lastActivity = Date.now();
            });
        };
    } catch (e) {}
    return await new Promise(function (resolve) {
        function done(why) {
            try { XMLHttpRequest.prototype.open = origOpen; } catch (e) {}
            try { window.fetch = origFetch; } catch (e) {}
            resolve(why);
        }
        (function check() {
            if (Date.now() - start > (timeout || 5000)) return done("Timeout");
            if (inflight <= 0 && Date.now() - lastActivity >= quietMs) return done("Network idle");
            setTimeout(check, 100);
        })();
    });
}
