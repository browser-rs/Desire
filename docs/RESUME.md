# Desire — macOS 原生 AI 浏览器（简历项目描述）

> 独立开发的 macOS 原生浏览器，以 AI Agent 为核心：AI 可直接理解并操作任意网页，
> 支持语音指令、视觉理解与自动执行（导航、点击、填表、评论、总结）。

## 技术栈

Swift 6.2（严格并发）/ SwiftUI / AppKit / WebKit（WKWebView 深度定制）/ SF Symbols / MetricKit / OSLog

## 核心工作

- **浏览器 AI Agent 系统**：实现 OpenAI 兼容多提供商 + Apple 端侧模型（Foundation Models）+ Ollama 的自动路由架构，40+ 浏览器操作工具（导航/标签页/DOM 交互/截图/下载/内容拦截），支持并行工具调用与审批门控
- **网页智能操作引擎**：设计元素三路定位（快照 ref / 可见文本 / CSS 选择器）+ 可点击祖先回溯算法，解决现代前端框架（React/Vue）图标按钮、事件委托元素的点击难题；可信鼠标事件（真实 NSEvent）绕过反自动化检测
- **多模态与语音**：截图压缩管线（视口坐标映射）支持视觉模型看屏操作；SFSpeechRecognizer 语音转文字直控浏览器，含 TCC 隐私权限全链路
- **评论/聊天场景自动化**：站点无关的评论区与网页 IM 启发式抽取（结构化 JSON），富文本编辑器（contenteditable/Prototyped setter）兼容写入与智能提交
- **WebKit 深度定制**：内容拦截（ABP 规则编译为 WKContentRuleList，EasyList 中国列表周更）、容器标签页（隔离 Cookie 存储）、标签挂起与恢复、每窗口独立会话持久化
- **WebExtensions 支持**：自研扩展运行时 v0.3（内容脚本隔离世界、background 页、browser action 弹窗、chrome.storage/runtime 消息路由）
- **工程质量**：Feature 模块化三层架构（Model/Store/View）、命令总线解耦菜单/快捷键、MetricKit 崩溃诊断采集、零警告严格并发构建

## 项目亮点（一句话版）

- 让 AI 像人一样操作浏览器：看得到（截图/快照）、点得准（可信事件+智能定位）、说得清（语音输入）
- 云端/端侧模型自动路由，敏感任务本地执行
- 完整实现浏览器高级特性：扩展系统、内容拦截、容器隔离、多窗口会话
