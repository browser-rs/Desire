// desire-dpp-sdk 冒烟测试：node test/smoke.mjs——假 window 环境，
// 断言 expose/emit/validate 的核心行为（发布前与 build 后都跑）。
import { createDesireSDK } from "../dist/desire-sdk.esm.js";
import { readFileSync } from "node:fs";

let failures = 0;
function check(name, cond) {
    if (cond) { console.log("  ✓ " + name); }
    else { failures++; console.log("  ✗ " + name); }
}

// 假宿主环境
const posted = { control: [], event: [] };
const fakeWindow = {
    location: { host: "example.com" },
    webkit: {
        messageHandlers: {
            desireProtocolControl: { postMessage: (p) => posted.control.push(p) },
            desireProtocolEvent: { postMessage: (p) => posted.event.push(p) },
        },
    },
};
const desire = createDesireSDK({
    global: fakeWindow,
    postControl: (p) => posted.control.push(p),
    postEvent: (p) => posted.event.push(p),
});

console.log("smoke:");

// expose：挂 window + 通知宿主 reparse
desire.expose({
    page: { type: "catalog" },
    views: { items: { item: ".card", fields: { title: "h3" } } },
    signals: { ready: "[data-ready]" },
});
check("expose 挂载 __desireProtocolExposed", fakeWindow.__desireProtocolExposed?.views?.items?.item === ".card");
check("expose 通知宿主 reparse", posted.control.length === 1 && posted.control[0].kind === "reparse");

// SPA 二次 expose = 更新 + 再次通知
desire.expose({ views: { records: { item: ".row", fields: { a: ".a" } } }, signals: { ready: "x" } });
check("二次 expose 更新声明", fakeWindow.__desireProtocolExposed.views.records != null);
check("二次 expose 再通知", posted.control.length === 2);

// emit
desire.emit("new-message", { text: "hi" });
check("emit 走事件通道", posted.event.length === 1 && posted.event[0].eventName === "new-message" && posted.event[0].host === "example.com");

// validate：完整声明
const v1 = desire.validate();
check("validate 完整声明无警告", v1.valid === true && v1.warnings.length === 0);

// validate：profile 契约（catalog 缺 items 视图 → 警告）
desire.expose({ profile: "catalog", views: {}, signals: { ready: "x" } });
const v2 = desire.validate();
check("validate profile 契约警告", v2.warnings.some((w) => w.includes("requires view 'items'")));

// validate：空声明
const empty = createDesireSDK({ global: fakeWindow, postControl: () => {}, postEvent: () => {} }).validate();
check("validate 未 expose", empty.valid === false);

// UMD 产物形态：可被 node 的 vm 当浏览器脚本求值
import vm from "node:vm";
const umd = readFileSync(new URL("../dist/desire-sdk.js", import.meta.url), "utf8");
const sandbox = {
    window: {
        location: { host: "umd.test" },
        webkit: { messageHandlers: { desireProtocolControl: { postMessage: () => {} }, desireProtocolEvent: { postMessage: () => {} } } },
        __desireProtocolExposed: undefined,
    },
    console,
    JSON,
};
vm.createContext(sandbox);
vm.runInContext(umd, sandbox);
check("UMD 在浏览器形态求值并挂载 window.desire", typeof sandbox.window.desire === "object" && sandbox.window.desire.version === "1.0.0");
sandbox.window.desire.expose({ views: { t: { item: ".i", fields: { f: ".f" } } }, signals: { ready: "r" } });
check("UMD expose 写入沙箱 window", sandbox.window.__desireProtocolExposed?.views?.t != null);

console.log(failures === 0 ? "\n全部通过 ✓" : `\n失败 ${failures} 项`);
process.exit(failures === 0 ? 0 : 1);
