// --- 网络依赖工具（页面世界专属）：__desireGetNetworkLog 读 network-monitor.js
// 在页面世界维护的 __desireNetLog；__desireWaitForNetworkIdle 猴补页面世界的
// XHR/fetch。这两个函数是 dom-tools 仅存的页面世界成员（第三轮审计指导 4）。

async function __desireGetNetworkLog({filter, maxItems}) {
    maxItems = maxItems || 100;
    var log = (window.__desireNetLog || []);
    var out = [];
    for (var i = log.length - 1; i >= 0 && out.length < maxItems; i--) {
        var entry = log[i];
        if (!filter || entry.url.toLowerCase().indexOf(String(filter).toLowerCase()) !== -1) {
            out.push(entry);
        }
    }
    return out.length ? JSON.stringify({ count: out.length, requests: out.reverse() }) : "No requests captured" + (filter ? " matching filter" : "");
}

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
