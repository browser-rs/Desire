# AI 浏览器开发踩坑记：SwiftUI 发布风暴、隐形加载与 Cloudflare 拒绝我

> 用 Swift 6.2 + SwiftUI + WKWebView 写一个原生 AI 浏览器（Desire），
> 这篇文章记录路上踩得最疼的几个坑。每个都是：现象 → 排查 → 原因 → 解法。
> 有几个坑，搜索引擎里几乎没有成体系的中文资料。

## 坑 1：一条 Swift 编译期警告都没违反，主线程却卡死了

**现象**：打开 AI 侧栏，网页一加载，整个 app 卡死，控制台刷屏：

```
Publishing changes from within view updates is not allowed, this will cause undefined behavior.
```

**排查**：这句话的意思是"在视图更新周期里改了被观察的状态"。但所有 `@State` mutation 都老老实实写在按钮回调里。盯了半天才发现，凶手藏在 `body` 里调用的一个 helper——`makeWebView(for:)`，它每次渲染都顺手调 `aiSession.setWebView(...)`，而后者**无条件赋值**了一个 `@Published var contextLabel`。

**原因**：`@Published` 的坑在于——**赋相同的值也会发 objectWillChange**。于是死亡螺旋：页面加载进度条每跳一格 → `body` 重算 → `setWebView` → 发布 → AI 面板重渲染 → SwiftUI 记一次警告。每秒几十次，主线程被淹死。

**解法**：两层防护，治本加治标。

```swift
func setWebView(_ wv: WKWebView?) {
    guard webView !== wv else { return }   // 身份没变直接返回（99% 的调用）
    webView = wv
    refreshContextLabel()                   // 内部：值变了才赋值
}
```

**教训**：在 View `body`（及其调用的任何 helper）里，把"调用 Store 方法"当作会触发全 UI 重绘的操作来对待。发布要么按身份去重，要么按值去重，二者至少占一个。

## 坑 2：工具全部报 "Tool surface not configured"

**现象**：重构后 AI 突然全瞎：导航、读页面、点按钮，所有工具统一返回 `Tool surface not configured`。编译零警告，测试全绿——因为出事的是运行期生命周期。

**原因**：工具提供者持有 surface 用的是 `weak var`（当年 surface 是全局 AppState，被 app 强持有，weak 没毛病）。重构后 surface 改成了**每窗口临时创建**的小对象，除了那个 weak 指针没有任何人持有它——`configure(with:)` 一返回，ARC 当场收割。weak 引用是所有权契约，不是免费保险。

**解法**：会话 store 显式强持有：

```swift
private var toolSurface: (any BrowserToolSurface)?   // 强引用
func configure(with surface: BrowserToolSurface) {
    toolSurface = surface
    toolProvider.attach(surface: surface)             // 那边继续 weak，防环
}
```

**教训**：把一个属性从 strong 改 weak 时，问一句"现在谁强持有它"。答案从"全局单例"变成"临时创建"的那一刻，这个 weak 就是定时炸弹。

## 坑 3：AI 导航"成功"了，页面却纹丝不动

**现象**：对 AI 说"打开百度"。工具返回 `Navigated to https://www.baidu.com`，快照还能读到完整的百度内容——但浏览器窗口里，新标签页还在原地。AI 没撒谎，页面也真加载了，就是**看不见**。

**排查**：聊天记录里有个铁证——导航"成功"之后调 `listTabs`，返回的标签标题和 URL 居然是空的。加载真实发生了，但 tab 级状态没跟上。

**原因**：两层叠加。

1. `isOnNewTabPage` 是**存储型布尔**（新标签页显示与否看它，不是从 URL 推导）。应用自己的地址栏导航会先清这个标志再 load；AI 的 navigate 工具只调了 `webView.load()`，标志永远为 true，新标签页界面就一直盖在已加载好的页面上。
2. 更隐蔽的是：标志为 true 时，webview **根本没挂载进视图树**——没有挂载就没有 navigation delegate，`didFinish` 不会回写 `urlString`，连地址栏都是空的。DOM 在看不见的世界里加载完毕。

**解法**：AI 导航与应用导航走同一条状态同步：

```swift
if let tab = surface.tabManager?.tabs.first(where: { $0.browser.webView === webView }) {
    tab.isOnNewTabPage = false
    tab.isSuspended = false
    tab.urlString = u.absoluteString
}
webView.load(URLRequest(url: u))
```

**教训**："UI 显示什么"如果是存储型状态而非派生态，那么**每一条**能改变底层事实的路径都必须同步它——不只是用户走的那条。

## 坑 4：Cloudflare 把我的浏览器当机器人——UA 的两个隐藏字符

**现象**：自研 WKWebView 浏览器打开一半的网站，弹"由 Cloudflare 提供的性能和安全服务"人机验证。Safari 打开同一个网站没有任何问题。

**原因**：两层。

1. macOS WKWebView 的**默认 UA 是残疾的**：`Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)`——缺 `Version/` 和 `Safari/` token。WAF 一看：非 Safari、非 Chrome、非 Firefox，未知客户端，上挑战。
2. 补 UA 时又踩了 WebKit Bug 313542：`customUserAgent` 对**第一次** `load(_:)` 请求不生效（只对页内点击的跳转生效）。第一发请求带着残疾 UA 出门，挑战已经在路上了。

**解法**：视图创建后立刻设完整 UA，并且**每次** `didStartProvisionalNavigation` 再补一刀（covering 首请求）；UA 本身做到与真 Safari 逐字节一致——OS 串保持 `10_15_7`（真实 Safari 仍在发这个，改成 `26_5` 反而触发"未知浏览器"），并且**结尾必须是 `Safari/605.1.15`**——WAF 校验 Safari 声明的 token 形状，我们自己的产品名（`Desire/0.1`）只能通过别的渠道（About 面板）暴露，不能附加在 UA 里。

**教训**：UA 不是字符串，是身份协议。抄的时候一个 token 都不能自作主张。

## 坑 5：语音识别"授权了但永远没结果"

**现象**：麦克风、语音识别两个权限都授权了，录音动画正常转，文字永远为空。

**原因**：曾经为了省流量设了 `requiresOnDeviceRecognition = true`。如果用户的 Mac 没下载过中文端侧语音模型，识别请求会**静默失败**——不报错，不回调，就是没有结果。另一个相关的坑：macOS 上麦克风（TCC Media）和语音识别（TCC Speech）是**两个独立权限**，Sandbox entitlement 用的是 `com.apple.security.device.audio-input`（没有 `device.microphone` 这种东西）。

**解法**：不强制端侧（让系统自己选最优路径）；错误码分级处理——216 是用户取消、203 是没听到说话，都要静默吞掉而不是弹错；两个权限分别预检，缺哪个引导跳哪个系统设置面板。

**教训**：苹果家"静默降级"的 API，一定要在真机、全权限组合下测，模拟器和文档都不会告诉你模型没下载。

## 坑 6：多窗口下，AI 在帮别的窗口干活

**现象**：两个浏览器窗口，在窗口 A 的 AI 聊天里说"打开掘金"——窗口 A 没反应，窗口 B 跳转了。

**原因**：全局 AppState 上挂了一个共享的 `_tabManager` 指针，"最后成为 key 的窗口"会覆盖它。浮动 AI 聊天窗是 NSPanel，一获得焦点就把浏览器窗口挤出 key 状态——此时 AI 工具解析到的 tabManager 属于谁，全看时序。

**解法**：每窗口一个 surface，构造时固定绑定本窗口的 TabManager（对它 weak，防窗口关闭泄漏），共享的只有书签、历史、设置这些天然全局的 store。全局可变指针是并发多实例场景的第一嫌疑犯——哪怕你只有主线程。

## 坑 7：性能账是滚出来算的

两个不起眼的决定，在真实使用里滚成大问题：

- **会话持久化**：15 秒一次的定时器把所有标签页归档存盘。"所有标签"包括挂着重型页面的——`interactionState` 归档在主线程跑，一个重页面几十毫秒。解法：给每个标签加指纹（URL+标题+历史数），没变就跳过归档。
- **地址栏联想**：每敲一个字，两条建议管线（地址栏 + 新标签页搜索框）各自发请求、解码 favicon。解法：in-flight 去重 + 负结果短 TTL 缓存（没图标域名不再每次渲染都发四连击）+ 图片解码移出主线程。

**教训**：周期性任务的成本 = 单次成本 × 频率 × 规模（标签数、域名数），三者都会在用户手里变大。

---

以上坑全部来自 Desire 的真实开发过程，解法也都已落在代码里。这个浏览器本身——AI Agent 操作网页、WebExtensions 兼容、内容拦截、容器标签——欢迎试用，反馈直接提 issue。
