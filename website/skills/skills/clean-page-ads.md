---
name: clean-page-ads
description: 页面广告清理：AI 识别广告元素 → 列出候选与理由 → 用户确认 → 永久屏蔽该站
---
## 流程
1. `findAdCandidates` 扫描当前页，拿到带**理由**的候选（class/id 关键词、跨域 iframe、
   广告联盟域名、覆盖层 z-index、标准广告位尺寸、\"广告/Sponsored\" 文案）。
2. 把候选**讲给用户听**（第几条、多大、在哪、为什么判定），让用户挑——不要自己全选。
3. 用户确认后调用 `blockElements {selectors:[…]}`：规则写进 ElementBlockStore，
   **立刻**注入隐藏 CSS，且以后每次打开这个站点都生效。
4. 若某些广告是**请求级**的（候选里的 src 指向广告联盟域名），可以一并传
   `blockRequests:[\"*://ads.example.com/*\"]` 做网络层拦截。
5. 改完让用户刷新确认；若有误伤，用 listBlockedElements / unblockElement 撤掉。
## 规则
- 只屏蔽广告与覆盖层；**不要**屏蔽正文、导航、登录框（用户没确认的一律不删）。
- 候选是启发式的：宁可少而准，报出理由让用户判断。

