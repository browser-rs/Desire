# desire-dpp-sdk

Desire Page Protocol (DPP) L3 SDK —— 让网页**声明自己的能力**（视图/信号/动作/事件），
AI 智能体据此精确读取内容与执行操作。可以理解为"页面版的 llms.txt"。

规范文档：[`docs/DPP-PROTOCOL.md`](../../docs/DPP-PROTOCOL.md)（协议全貌：L0–L3 四种接入形态、
views/signals/actions/events 语义、profile 契约、well-known 站点级声明）

## 安装

```bash
npm install @browser-rs/dpp-sdk
```

或直接用 CDN（UMD，无需构建）：

```html
<script src="https://desire.mankong.icu/desire-sdk.js"></script>
```

## 用法

```html
<script src="https://desire.mankong.icu/desire-sdk.js"></script>
<script>
  desire.expose({
    protocol: "desire/1",
    page: { type: "catalog" },
    views: {
      products: { item: ".card", fields: { title: "h3", price: ".price" } }
    },
    signals: { ready: "[data-app-ready]" },
    actions: [
      { name: "add-to-cart", run: [{ click: ".add-btn" }], effects: "persist" }
    ],
    events: { "price-change": { watch: "#price", debounce: 2 } }
  });
</script>
```

- **`expose(protocol)`** — 声明协议；SPA 路由变化时**重新调用即可**，Desire 会自动重新解析
- **`emit(name, detail)`** — 发射精确事件（比 DOM 监听可靠，宿主事件驱动回合的入口）
- **`validate()`** — 检查声明完整性（缺 signals.ready / profile 契约缺失等，console 提示）

ESM / bundler 用法：

```js
import { createDesireSDK } from "desire-dpp-sdk";

const desire = createDesireSDK({
    global: window,
    postControl: (p) => window.webkit?.messageHandlers.desireProtocolControl?.postMessage(p),
    postEvent: (p) => window.webkit?.messageHandlers.desireProtocolEvent?.postMessage(p),
});
desire.expose({ /* … */ });
```

（`createDesireSDK` 不依赖具体宿主——env 注入桥通道，方便测试与自建宿主。）

## 网站没适配？第三方适配包

站点不会都主动接入。Desire 浏览器支持**外挂 DPP 适配包**：按 host 匹配的声明式 JSON
（与 `expose()` 同一套协议格式），第三方为热门站点编写并分享，浏览器侧加载后由
解析器合并（页面原生声明优先，适配器只补空白；动作照走审批链）。
适配包目录与格式见 `docs/dpp-adapters/`。

## 开发

```bash
node build.mjs        # src/core.js → dist/（UMD + ESM），并同步 website/ 与 app bundle 副本
node test/smoke.mjs   # 假宿主冒烟（expose/emit/validate/UMD 求值）
```

改了 `src/core.js` 必须重跑 build——`website/desire-sdk.js` 与
`apps/macos/Desire/UserScripts/desire-sdk.js` 都是构建产物（提交进仓库）。

## 发布（维护者）

```bash
npm login                 # 或 CI 里配 NPM_TOKEN
bash publish.sh --dry-run # 预览包内容
bash publish.sh           # build + test + npm publish
```
