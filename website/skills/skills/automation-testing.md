---
name: automation-testing
description: 网页自动化测试：把浏览器操作变成可重复的断言并输出测试报告
---
## 流程
1. 和用户确认测试范围，用 updatePlan 列出用例清单。
2. 每个用例：navigate → 操作（click/fill/type）→ 断言（waitForText / getPageText 包含期望 / findElements 计数）。
3. 记录 PASS/FAIL 与失败原因截图（screenshot）。
4. 全部执行后 writeFile 输出 Markdown 测试报告（用例/期望/实际/结果表）。
## 规则
- 断言失败先重试一次再判 FAIL（网络抖动）。
- 涉及支付的流程只测到支付页出现为止。

