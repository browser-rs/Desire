# Desire — macOS 原生 AI 浏览器（详细版项目描述）

> 独立开发的 macOS 原生浏览器，以 AI Agent 为核心交互范式：AI 可看、可听、可操作任意网页，
> 完整实现现代浏览器的高级特性（扩展系统、内容拦截、容器隔离、多窗口会话）。

**技术栈**：Swift 6.2（严格并发）/ SwiftUI / AppKit / WebKit / Foundation Models / Speech / MetricKit / OSLog

---

## 一、浏览器 AI Agent 系统

- **多提供商模型路由**：统一 OpenAI 兼容协议接入云端模型（GLM / DeepSeek / OpenAI / OpenRouter 等）+ Apple 端侧模型（Foundation Models，macOS 26 Intelligence）+ 本地 Ollama，实现按任务复杂度自动路由（简单任务端侧执行保隐私，复杂任务云端执行），带会话级粘性锁与实时 "via" 来源标识
- **Agent 工具调用运行时**：为模型暴露 40+ 浏览器操作工具（导航、多标签管理、DOM 读写、截图、下载、内容拦截、书签历史、搜索引擎切换等），支持并行工具调用（SSE 流式聚合多 index 调用）、50 轮迭代上限、危险操作审批门控（allow-once / always / deny）
- **MCP 客户端**：实现 Model Context Protocol Streamable HTTP 传输，外部工具服务器可无缝桥接进 Agent 工具表（`mcp_*` 前缀统一调度与审批）
- **每窗口独立 Agent 会话**：自定义 WindowToolSurface 将工具操作面固定绑定到所属窗口的 TabManager，多窗口/浮动聊天窗场景下 AI 永远操作正确的窗口（解决了全局 surface 指针导致的跨窗口误操作）
- **会话连续性**：对话持久化 + 打开面板自动恢复最近会话、快捷动作条、选中文字即问（Selection AI Bar）、元素级上下文注入
- **Agent 系统提示词工程**：中文场景指令路由（"打开XX"→navigate、"总结评论"→getComments），内置提示词版本迁移（指纹检测过期默认值，不覆盖用户自定义）

## 二、网页智能操作引擎（Agent 的"手"）

- **元素三路定位**：快照 ref（`data-desire-ref` 编号直达）→ 可见文本打分匹配（aria-label/innerText/title，精确>前缀>包含，深度加权）→ CSS 选择器兜底，模型用自然语言（"点赞"）即可定位控件
- **可点击祖先回溯**：解析命中后向上回溯最多 6 层找到真正响应激活的元素——解决 React/Vue 事件委托、SVG 图标无 `.click()`、`cursor:pointer` 自定义节点等现代前端难题
- **可信输入管线**：通过 AppKit 事件管道派发真实 NSEvent 鼠标点击/悬停（isTrusted=true），绕过 Turnstile 等反自动化检测；视口 CSS 坐标 → 窗口坐标的缩放/翻转换算
- **拟真事件序列**：JS 兜底路径派发完整 pointer/mouse 事件链（带坐标），唤醒框架委托监听器
- **评论/IM 场景自动化**：站点无关启发式抽取评论区（作者/内容/时间/点赞）与网页聊天（发送者/内容/收发方向），结构化失败自动降级原文；`postComment` 自动定位输入框（占位符+容器+位置打分）、富文本编辑器兼容写入（execCommand 走真实编辑事件，兼容 contenteditable/原型 setter）、智能提交（找发送按钮走可信点击，无按钮按 Enter）
- **视觉操作回路**：截图压缩管线（≤1024px JPEG q80，NSBitmapImageRep 离屏绘制）+ 视口坐标元数据，支持视觉模型看屏后按像素坐标点击（canvas/虚拟列表/shadow DOM 兜底方案）

## 三、语音与多模态

- **语音直控浏览器**：SFSpeechRecognizer + AVAudioEngine 实时转写，zh-CN 优先多区域回退、错误码分级处理（取消/无语音/权限）、录音脉冲动画与即时状态反馈，说完自动发送指令
- **TCC 隐私权限全链路**：麦克风 + 语音识别双权限预检、失败引导跳转系统设置、Sandbox entitlement 正确配置（audio-input 而非 microphone）

## 四、WebKit 浏览器核心

- **地址栏解析引擎**：单一 URL 判定源（scheme 识别 / localhost / IP:端口 / TLD 启发式 / IDN 编码 / 失败回退搜索而非静默失败）、引擎关键词路由（"baidu 关键词"直走百度）、IME 组合输入防护（hasMarkedText 不触发建议、不回写文本）、键盘选中建议回车提交
- **每窗口独立会话**：value-based WindowGroup + 按窗口会话键持久化，标签挂起（idle 自动挂起省内存 / interactionState 快照恢复滚动与表单状态）、窗口关闭行为、最近关闭恢复
- **容器标签页**：每容器独立 WKWebsiteDataStore（Cookie/存储完全隔离），类 Firefox Multi-Account Containers
- **内容拦截**：ABP 过滤规则语法 → WKContentRuleList JSON 编译器（通配符/例外规则/元素隐藏/选项解析，6 万条上限），EasyList China 默认启用 + 周自动更新 + 编译缓存持久化；视频广告拦截（注入脚本）、元素级手动拦截（选择器/XPath + 撤销 toast）
- **反爬兼容性工程**：完整桌面 Safari UA 深度研究（WebKit Bug 313542 首请求 UA 不生效的 workaround、UA token 形状与 WAF 校验关系），解决 Cloudflare 拦截；HTTPS 自动升级
- **下载系统**：断点续传（Range 请求 + 部分文件管理）、HTTP 状态校验与错误分类、暂停/恢复

## 五、扩展系统（WebExtensions 兼容层）

- **自研扩展运行时 v0.3**：manifest 解析、内容脚本注入（document_start/end、每扩展独立 WKContentWorld 隔离）、background 页（离屏 WKWebView）、browser action 弹窗（NSPanel）
- **chrome.* API 桥**：chrome.storage.local（每扩展 JSON 持久化）、chrome.runtime.onMessage/sendMessage 三方路由（内容脚本↔弹窗↔background）、用户脚本管理（启用/禁用/移除的 rebuild-all 模式）

## 六、性能优化

- **渲染隔离**：标签页内容视图拆分，隔离高频 objectWillChange（加载进度 tick）避免全窗口重绘；修复 @Published 同值发布风暴（视图更新周期内发布导致主线程卡死）
- **资源缓存**：favicon 缓存（in-flight 去重 + 负结果 TTL + 解码下主线程）、搜索建议 LRU 缓存 + 超时、会话归档指纹去重（15s 定时器不再全量重归档所有标签）
- **标签生命周期**：后台标签自动挂起、窗口关闭及时释放 WKWebView、懒加载建议模型（地址栏/新标签页各自独立避免串扰）

## 七、工程架构

- **Feature 模块化三层架构**：Model（纯数据）/ Store（@MainActor ObservableObject 业务）/ View（纯渲染），组件分类体系（Primitive/Composite/Panel/Page），回调聚合规范（>8 参数聚合为 Actions struct）
- **基础设施**：命令总线（类型化 Combine publisher 替代 NotificationCenter 字符串路由）、OSLog 门面（8 分类）、MetricKit 崩溃/卡顿诊断采集落盘、DiskStore 防抖离主线程 JSON 持久化
- **并发正确性**：Swift 6.2 严格并发 + MainActor 默认隔离零警告构建；App Sandbox + Hardened Runtime + Keychain 按提供商隔离 API 密钥
- **SwiftUI 深度实践**：NSViewRepresentable 生命周期管理、视图更新周期外的状态发布、FocusState 多窗口焦点管理、value-based WindowGroup 状态恢复

---

## 一句话亮点（按需选用）

- 让 AI 像人一样操作浏览器：看得到（截图+视觉模型）、点得准（可信事件+三路定位）、说得清（语音输入）、写得了（富文本自动填写）
- 云端/端侧模型自动路由 + MCP 协议扩展，Agent 工具生态无限延伸
- 站点无关的评论区/网页 IM 启发式抽取，"总结评论""自动回复"一句话完成
- WebKit 深度定制：ABP 规则编译、容器隔离、标签挂起恢复、Cloudflare UA 兼容工程
- Swift 6.2 严格并发零警告，Feature 模块化三层架构，MetricKit 可观测性
