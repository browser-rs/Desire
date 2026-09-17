# Desire 功能实测报告（第一轮，2026-09-17）

测试方式：Debug 构建启动 + AppleScript UI 自动化（键盘注入）+ 截图比对。
已覆盖：启动、新标签页、地址栏导航。未覆盖：Agent 面板、多窗口、下载、书签。

## 发现的问题

### BUG-A（高）：地址栏输入带 scheme 的网址 → 被交给系统打开
- 复现：⌘L → 输入 `https://example.com` → 回车
- 现象：弹出我们自己的 `confirmAndOpenExternalURL` 弹窗（"Desire 没有找到已注册处理此链接的应用：https://example.com"），页面白屏
- 疑点：`WebView.swift:597` 的 `!internalSchemes.contains(scheme)` 白名单里明明有 https
  （:667），静态分析无法解释。需插桩 decidePolicy 输出实际收到的
  url/scheme/navigationType/targetFrame 定位。

### BUG-B（高）：导航 example.com → 白屏
- 复现：⌘L → 输入 `example.com`（无 scheme）→ 回车
- 现象：页面全白。example.com 应渲染内容；错误页（ErrorPageView）也未出现。
- 待查：didFailProvisional 是否触发、lastError 是否为空、沙盒
  `com.apple.security.network.client` 授权、HTTPS-upgrade 循环。
- 佐证：新标签页的快捷拨号 favicon 能显示（可能来自磁盘缓存），不代表网络可用。

### ISSUE-C（低）：新标签页「最近访问」区域上缘有横贯全宽的虚线锯齿渲染伪影
- 截图 /tmp/desire_test2.png 可见。疑似虚线边框样式绘制宽度错误。

### ISSUE-D（中）：confirmAndOpenExternalURL 在导航委托里用 NSAlert.runModal()
- 模态阻塞主线程 + 阻塞导航委托；确认框应改为非模态（或至少
  dispatch 到下一次 runloop）。顺带在 BUG-A 修复时处理。

## 正常项
- 启动、窗口 chrome、新标签页布局、快捷拨号 + favicon、最近访问列表、
  ⌘L 聚焦地址栏、地址栏文字输入与回车提交链路（提交本身到达了导航层）。

## 下一轮计划
1. decidePolicy 插桩（Log.agent）→ 重跑复现 BUG-A，确定 scheme 实际值
2. 排查 BUG-B 网络失败原因（entitlements / lastError / 错误页显示条件）
3. 修 ISSUE-C 伪影、ISSUE-D 非模态化
4. 继续覆盖：Agent 面板开关、多标签、下载、书签/历史面板
