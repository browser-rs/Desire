# 纯文本缩放 spike 结论（v0.8.82）

## 目标

在不改变页面布局的前提下只放大/缩小文字（区别于已有整页缩放）。

## 结论（2026-11-28）

**v0.8.82 不实现纯文本缩放，也不加设置开关。**

- WKWebView 没有公开的“纯文本缩放”API；`WKWebpagePreferences` / `WKPreferences`
  没有对应属性。
- 可行路径只有 CSS 注入：
  - `document.documentElement.style.fontSize` 只影响 `rem`，大量站点正文是 `px`，
    实际会出现“设置生效一半页面”；
  - `-webkit-text-size-adjust` 在 macOS WebKit 上不是可靠的内容缩放开关，
    且会与站点响应式布局互动；
  - 逐节点放大 `font-size` 会破坏既有布局、表格与 Shadow DOM，风险高于收益。
- 与项目约定一致：**不做看起来能点但只对一部分页面生效的开关**。

## 后续可选

若将来 WebKit 暴露文本缩放 API，或愿意接受“仅阅读模式生效”的受限语义，
再以独立设置项实现；当前由整页缩放覆盖。
