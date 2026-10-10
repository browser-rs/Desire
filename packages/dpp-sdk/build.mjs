// desire-dpp-sdk 构建：src/core.js → dist/desire-sdk.js（UMD/IIFE）
// + dist/desire-sdk.esm.js（ESM）。纯字符串拼接，零依赖。
// core.js 的结构约定：第一行 `/**` 头注释 + `function createDesireSDK(env) {…}`
// + `function browserEnv(global) {…}` 两个顶层函数——包装器按标记切分。
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";

const src = readFileSync(new URL("./src/core.js", import.meta.url), "utf8");
mkdirSync(new URL("./dist/", import.meta.url), { recursive: true });

// 头注释（core.js 第一段块注释）作为两个产物的公共文档头。
const headerEnd = src.indexOf("*/") + 2;
const header = src.slice(0, headerEnd);
const body = src.slice(headerEnd).trim();

if (!body.startsWith("function createDesireSDK") || !body.includes("function browserEnv")) {
    throw new Error("core.js structure drifted — expected createDesireSDK + browserEnv top-level functions");
}

// UMD/IIFE：浏览器 <script> 直接引。挂 window.desire，兜底宿主桥。
const umd = `${header}

/**
 * desire-dpp-sdk（UMD 构建，来自 packages/dpp-sdk — 勿直接编辑本文件）
 * 网页接入：<script src="…/desire-sdk.js"></script> + desire.expose({…})
 * 规范：docs/DPP-PROTOCOL.md
 */
(function() {
    "use strict";
${body}

    // 挂载到 window（宿主解析器读取 window.__desireProtocolExposed）
    window.desire = createDesireSDK(browserEnv(window));
})();
`;

// ESM：bundler/Node 用户。导出工厂，不自动挂载（宿主自行传 env/global）。
const esm = `${header}

/**
 * desire-dpp-sdk（ESM 构建，来自 packages/dpp-sdk — 勿直接编辑本文件）
 * import { createDesireSDK } from "desire-dpp-sdk";
 * const desire = createDesireSDK({ global: window, postControl: …, postEvent: … });
 */
${body}

export { createDesireSDK, browserEnv };
`;

writeFileSync(new URL("./dist/desire-sdk.js", import.meta.url), umd);
writeFileSync(new URL("./dist/desire-sdk.esm.js", import.meta.url), esm);
console.log("built dist/desire-sdk.js (UMD) + dist/desire-sdk.esm.js (ESM)");
