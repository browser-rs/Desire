# DPP 跨源 iframe spike 结论（0.6.10，2026-10-06）

**判定：完整可行——不止路线图猜测的"声明式透传"，跨源子框架的声明聚合与
定向提取都能做。0.7 立项（跨源 iframe 视图为完整成员，非二等公民）。**

## 方法

独立 WKWebView 程序（`/tmp/iframe-spike/spike.swift`，双源 fixture：
127.0.0.1:8877 主页内嵌 127.0.0.1:8878 跨源 iframe——同 host 不同端口即跨源），
`WKUserScript`（forMainFrameOnly: false）注入探针，实测三问，本机 macOS 27 WebKit：

| 问题 | 结果 |
|---|---|
| ① 注入范围：用户脚本进跨源子框架？ | **是**——`.page` 与 `.defaultClient` 两个世界的脚本都在子框架执行（服务器可见的 `<img>` ping 双双命中） |
| ② 消息回传：跨源子框架的 `scriptMessageHandler` 到达？ | **是**——消息带 `frameInfo`（`isMainFrame=false` + 子框架 URL），双世界均达 |
| ③ frame 级求值：宿主能否定向跨源子框架执行 JS？ | **是**——`webView.evaluateJavaScript(_:in:in:contentWorld:)` 传入消息携带的 `WKFrameInfo`，成功读回子框架的 `window.__desireProtocolExposed` 声明与 DOM 文本 |

原始输出（节选）：

```
MSG[spike]  main=false url=http://127.0.0.1:8878/frame.html body=[page] ran declared=true …
MSG[spike2] main=false url=http://127.0.0.1:8878/frame.html body=[main-world] ran declared=false …
FRAME-EVAL OK: {"declared":true,"view":"h1","text":"Cross-origin frame content (port 8878)"}
```

## 实现路径（0.7 跨源视图）

1. **注入**：DPP 的框架探针脚本以 `forMainFrameOnly: false` 注入（`.page` 世界，
   与现网 DPP SDK 同世界）——每个框架各自上报 `location.href` + 声明对象。
2. **聚合**：宿主按 `frameInfo` 收集各框架声明，视图表 = 主框架声明 ∪ 各子框架
   声明（视图名冲突时主框架优先，子框架视图以 `frame:<序号>` 或框架 URL 命名空间化）。
3. **提取**：`pageExtract` 对声明来自子框架的视图，把抽取 JS 经
   `evaluateJavaScript(in: frameInfo)` 送进**那个框架**执行（模板/字段语法不变）。
4. **ignore**：`data-dpp-ignore` 同理按框架生效。

## 两个实测顺带发现（实现时注意）

- **atDocumentEnd 用户脚本可能早于 body 内联脚本执行**（本 spike 主框架第一次
  实测 `declared=false`，同页内联脚本明明先"写"了 true；换缓存/时序后又能为
  true）——**声明读取不要依赖"用户脚本时页内变量已就绪"**，要么轮询重读，要么
  SDK 自身用 `atDocumentStart` + DOM 事件后声明（线上 SDK 已是文档头注入，不受影响）。
- 声明时序竞态不影响 ③：定向求值是在**消息到达后**执行的，读到的是子框架的
  实时状态。

## 复测

fixture 与探针都在本文档描述里可重建（双源 python http.server + swiftc 单文件）；
WebKit 大版本更新后如需回归，重跑同一三问即可。
