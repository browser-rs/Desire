# 让 AI 像人一样点网页：一个 macOS AI 浏览器的 DOM 操作引擎设计

> 大模型早就会"想"了，但一直不太会"点"。这篇文章讲 Desire（一个我独立开发的 macOS AI 浏览器）
> 里最核心的一块工程：Agent 的网页操作引擎。为什么"点个赞"这么难，以及我们怎么让它稳。

## 一、问题：模型会选，但页面不配合

给模型一个 `click(selector)` 工具，它在 2023 年的静态页面上表现得还行，在 2026 年的真实网页上处处碰壁。难点按出现频率排：

1. **目标根本不是标准控件**。B 站的点赞是 SVG 图标——`SVGElement` 没有 `.click()` 方法；微博的转发是个 `div`，事件是框架在根节点委托监听的；`[onclick]` 选择器只抓得到内联属性，`addEventListener` 绑的对它隐形。
2. **模型写不对选择器**。生产站的 class 是构建产物（`css-1x2f3a`、`Button-sc-1abc`），从快照里让模型拼 CSS，拼错是常态。
3. **点了没反应**。合成事件序列不完整：React 18 的事件委托挂在 root 上，靠的是事件冒泡 + 合成事件系统；很多组件还盯着 `pointerdown` 而不只是 `click`。
4. **反自动化拦截**。`element.click()` 派发的事件 `isTrusted === false`，Cloudflare / Turnstile 一眼识别，轻则挑战、重则封会话。
5. **富文本编辑器写不进去**。评论框 ten 有九个是 contenteditable（Draft.js / ProseMirror / Lexical），直接改 DOM 或设 value，框架状态纹丝不动。

对应的解法分四层，从下往上讲。

## 二、快照：给模型一双"看清楚"的眼

让模型直接面对 DOM 是不人道的。Desire 注入一份页面快照脚本，产出结构化 JSON：

```json
{
  "title": "…", "url": "…",
  "viewport": { "width": 1514, "height": 1024, "scrollX": 0, "scrollY": 209 },
  "text": "…正文提炼（评分选容器，剔除导航噪音）…",
  "elements": [
    { "ref": "e12", "tag": "button", "text": "点赞 1.2万", "pressed": "false" }
  ]
}
```

三个设计点：

- **每个可见可交互元素打上 `data-desire-ref` 编号**。模型之后用 `click {ref: "e12"}` 直达，完全不用碰选择器。
- **ref 每轮快照先清后发**。SPA 页面元素会重排，指向旧位置的 ref 比没有 ref 更危险——宁可让它重新看一眼。
- **快照带 viewport 几何信息**。这是为视觉模型准备的：截图 + 坐标系，就能走"看图 → 按像素点"的兜底回路。

## 三、三路定位 + 祖先回溯：把"猜"变成"查"

`click` / `hover` / `fill` 统一支持三种定位方式，按可靠性排序：

```
ref ("e12")  →  text ("点赞")  →  selector ("button.like-btn")
```

**text 定位**是给快照漏掉的控件准备的：按可见文本 / aria-label / title 打分匹配——精确匹配 > 前缀 > 包含，同分时更深的节点（更具体）、原生控件（button/a/[role=button]）、更短的标签胜出。模型说人话"点赞"，引擎去找那个按钮。

**祖先回溯**解决"点到了但没点对"：

```js
function clickableAncestor(el) {
  for (let hops = 0; el && el !== document.body && hops < 6; hops++) {
    if (isClickable(el)) return el;   // button/a/[role]/tabindex/cursor:pointer…
    el = el.parentElement;
  }
  return el;  // 原样返回，宁可试一试
}
```

模型经常命中的是 `<svg><path>` 或包着按钮的 `<span>`——SVG 没有 `.click()`，span 没有处理器。向上找最多 6 层，落到真正响应激活的祖先上。这一个函数把"图标按钮点不动"类的失败几乎清零。

## 四、可信输入：让页面相信"这是个人"

这是整条链路里最值钱的一层。Desire 优先走的不是 JS，而是 **AppKit 原生事件管道**：

```
快照/文本解析 → 元素矩形（页面内滚动到可视区）→ 视口 CSS 坐标
  → 缩放/翻转换算（pageZoom、isFlipped）→ 窗口 base 坐标
  → NSEvent 合成 → WKWebView 派发 → isTrusted = true
```

页面看到的是一次真实的、带坐标的鼠标点击。反自动化系统无话可说。

JS 兜底路径（webview 不在窗口里、元素无几何时）也升级成了完整事件序列：

```js
pointerover → mouseover → pointerdown → mousedown
  → focus → pointerup → mouseup → click
```

带真实 clientX/clientY，让 React 根节点的事件委托和盯着 `pointerdown` 的组件都拿到该拿的信号。裸 `element.click()` 只派发一个 click，这在 2026 年等于自报家门。

## 五、写内容：富文本编辑器与受控输入

**受控 input/textarea**（React/Vue）直接设 `el.value` 会被框架的属性拦截器吞掉。标准解法是绕过实例属性、通过原型描述符写值，再补齐事件：

```js
const desc = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value");
desc.set.call(el, text);                    // 绕过 React 的 value 拦截
el.dispatchEvent(new Event("input", { bubbles: true }));
```

**contenteditable 编辑器**用编辑 API 走"真打字"路径：`document.execCommand("insertText", false, text)`——虽然 API 已标记废弃，但它触发的 `beforeinput`/`input` 事件正是 Draft.js / ProseMirror / Lexical 监听的东西，兼容性至今无敌。caret 先折叠到文末，追加而不是覆盖。

**发表**链路串起来：自动找输入框（占位符文案"说点什么/写评论" + 所在容器 + 页面位置打分）→ 写入 → 找发送按钮（"发送/发表/Send"短动词匹配）→ 回传按钮矩形给 Swift → 走可信点击。没有按钮的聊天界面按 Enter（完整 keydown/keypress/keyup 序列）。

## 六、评论与聊天：站点无关的结构化抽取

"总结评论区"不能靠把三百条评论塞给模型。Desire 的抽取器全是启发式，零站点规则：

- **容器发现**：class/id 含 `comment/reply` 的可见容器中选内容量最大的；
- **条目识别**：容器内扫 `item/comment/reply/li/article` 类节点，**重叠去重**（包含关系的节点只留一个）；
- **字段拆解**：作者取 `name/user/author/nick` 类节点；正文用"克隆节点 → 剔除时间/点赞/头像/操作区 → 取剩余文本"，这样即使正文节点没有可识别的 class 也能抽干净；
- **降级链**：结构化失败但容器存在 → 交原文，模型自己读。永远有话说。

聊天同理，多了个方向判定：消息节点（含父节点）的 class 命中 `self/mine/right/outgoing` 判为"我发的"——这一个布尔值让"帮我回复"的语义完全不同。

## 七、分层兜底的哲学

整个引擎没有一层是"必胜"的，但失败会被下一层接住：

```
ref 直达 ──失败──▶ 文本匹配 ──失败──▶ CSS 选择器
   │                                    │
   ▼ 可信 NSEvent 点击                   ▼
        完整合成事件序列 ──失败──▶ 截图 + 坐标点击（视觉兜底）
```

Agent 循环里模型自己也会换招：快照找不到就截图看一眼，坐标点不上就 readTab 换个读法。工具只要保证"每次失败都有信息量"（"Element not found: text '点赞'"——告诉它是没找到而不是点空了），模型就会自己走通。

---

Desire 是我用 Swift 6.2 严格并发写的 macOS 原生浏览器，AI Agent、扩展系统、内容拦截、容器标签全都自己啃的。这一篇是操作引擎的设计篇，下一篇写开发路上踩的坑（SwiftUI 发布风暴卡死、WKWebView"隐形加载"、Cloudflare 把我的浏览器当机器人……），有兴趣可以关注。
