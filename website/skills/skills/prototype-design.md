---
name: prototype-design
description: 原型设计：把需求变成 HTML 高保真原型并可视化迭代
---
## 流程
1. 和用户确认页面结构/风格（askUser：用途、目标设备、风格倾向）。
2. writeFile(path: "prototype/page.html", content: 完整单文件 HTML —— 内联 CSS/JS，移动端优先，使用系统字体与柔和阴影)。
3. navigate file://<工作目录>/prototype/page.html 预览。
4. screenshot 看效果 → 按反馈迭代（每次改完重新 writeFile + navigate）。
5. 完成后报告文件路径，说明可双击在浏览器打开。

## 设计规则
- 现代简约：大留白、圆角卡片、克制配色（一个主色+中性灰）。
- 单文件自包含，不依赖外部 CDN。

