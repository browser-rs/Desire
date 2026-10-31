# v0.8.32 规划稿（2026-11-01，诊断先行）—— YouTube 自动播放专项

> 用户定调：自动播放专门做一个版本，主题就是 YouTube 自动播放。要求：
> ① 全链路测试出来、找到真实原因、要可观测（每次遇到的情况都不相同）；
> ② 评估是否重写自动播放逻辑——它跟广告过滤（json-prune/sponsorblock/
>    anti-detect）混在一起，已经很难排查。

## 现状盘点：八层东西搅在一起（这就是"麻烦"的来源）

| 层 | 文件 | 职责 | 与播放的关系 |
|---|---|---|---|
| 1 | Tab.init 咽喉点 | 按**初始 URL host** 烙 mediaTypesRequiringUserActionForPlayback | 决定 consent 底牌 |
| 2 | SiteSettingsStore.effectiveAutoPlay | 站点覆写 > 视频站白名单豁免 > 全局 | 条件判断口径 |
| 3 | re-bake（didFinish 一次性重开） | 白名单站 + 生效 allowAll + 烙成限制 → 重开标签 | 修"空白标签导航进站" |
| 4 | kickStaleAutoplayIfNeeded | 长梯重试 playVideo()/play()（8 拍 30s） | 修"停在起点" |
| 5 | yt-playback-guard.js | 起播补刀 + 海报守卫 + 离屏预览暂停（仅 youtube） | 同上，页面侧 |
| 6 | media-visibility-resume.js | 隐藏前在播→可见后 paused 的补播（全站，0.8.31 热修） | 修"切回卡暂停" |
| 7 | 广告过滤三件：yt-json-prune / sponsorblock / yt-anti-detect | 改播放器数据 / 跳段 / 反检测 | **嫌疑**：可能直接或间接触发暂停 |
| 8 | WebKit PageConsent（macOS 26 运行时层） | 页面级媒体 consent，恢复/续播可被拦 | 终极裁判，之前不可观测 |

**已知症状两形态**：① 一些能自动播；② 播一下马上暂停。历史修复全部围绕
"白名单 + 起播"，**从未有过"谁按的暂停"的第一现场**——每次都在猜。

## 批次① 诊断仪器化（先做，产出真因）

1. **暂停来源 oracle**（media-pause-diag.js，临时→固化）：包装
   `HTMLMediaElement.pause/play` 抓调用栈；**分类器**把栈帧归类为
   `youtube-player / page-js / our-script(列名) / webkit-internal / unknown`。
2. **全链路事件流**（宿主新消息 `mediaPipelineEvent` → os_log `autoplay`
   分类，一条线读完）：policy-baked(reason) → nav(host) → play-attempt(who/
   result) → pause(actor+stack) → consent-blocked(计数) → recovery(action/result)。
3. **复现矩阵**（真站，桥驱动）：{新标签直开 / 首页点进 / 中键后台标签 /
   会话恢复} × {起播 / 播放中切走切回}，每个格子留 os_log + WebKit Media
   日志双份证据。
4. **产出**：真因清单（哪个 actor、哪条路径、哪种策略组合）——写进本文档
   附录，作为批次②的输入。

## 批次② 重写决策与落地（按①的证据定）

- **确定重写**（当前倾向）：新 `media-pipeline.js`（单一页面侧管线：起播
  状态机 + 恢复补播 + 暂停 oracle，**广告过滤不进来**，但会标记来自广告层
  的暂停）+ Swift 侧 `MediaPlaybackController`（每标签单一 owner，替代
  kick/re-bake 的散装条件；决策全走一条 os_log）。
- **广告层解耦**：json-prune/sponsorblock 造成的暂停会被 oracle 标名——
  修复 = 广告脚本对 watch 页播放器的动作走"延迟到 playing 后"或排除，
  不再和播放恢复互相打架。
- **策略层评估**：PageConsent 若被证实是独立于 baked policy 的运行时层，
  评估 WebKit feature flag（defaults 注入）或"consent-blocked 即重开"
  的通用恢复（替代白名单 re-bake）。
- 备选（若①证明八层相安无事、是别的真因）：按真因点修，重写降级为重构。

## 批次③ 回归矩阵 + 收口

- 四路径 × 两形态全绿矩阵（桥驱动，可重复跑）。
- 诊断仪器**固化保留**（默认采样，不只在 debug）——以后再出播放问题
  有第一现场，不再猜。

## 不做

- 不内置 ffmpeg/DRM 相关；不动全局 requireUserAction 的产品决策（用户
  显式选择）；不用私有 WebKit KVC 硬关 consent（崩溃/合规风险），feature
  flag 只用 UserDefaults 公开机制。

## 验证门

os_log 链路一条线可读；矩阵全绿；harness/clean 零警告/三语照旧。
EOF
git add docs/ROADMAP-0.8.32-PLAN.md apps/macos/Desire/UserScripts/media-pause-diag.js apps/macos/Desire/Features/UserScripts/UserScriptLoader.swift && git commit -m "docs(roadmap): v0.8.32 plan — YouTube autoplay deep-dive (observability first, rewrite decision after evidence)" && git push origin main 2>&1 | tail -1
---

## 批次① 诊断结论（2026-11-01，取证完成）

**真因 #1（当场人赃俱获，已修）**：`yt-anti-detect.js` 旧弹窗层误伤。
选择器 `ytd-popup-container ~ *` 把 popup 容器之后的所有兄弟（含主内容）
纳入 `AD_TEXT` 的 textContent 全文匹配 → watch 页正文必命中"广告拦截"类
字样 → `killDialog` 把真 DOM `remove()` 并强制 `play()` 所有 video →
YouTube 播放器状态机 `pauseVideo()` 反杀 = **「播一下马上暂停」**。
诊断栈帧逐行对上（`killDialog@user-script:41:50:21`）。修复 = 弹窗层
三重收窄重写（只认 ENFORCEMENT 结构证据 / 移除后不再强制 play / 不做
全文文案匹配）。

**矩阵结果**：硬路径（地址栏直开 watch 页、无页面激活）修复后 **3/3 干净**
（G2 全开 + A1/A2；A1 连续播放 55s 横跨矩阵）。合成点击路径（B）呈
`PAUSED@0.0` 是取证假象——`a.click()` 非可信激活，真实用户点击可信能播
（=「有一些可以自动播放」的机制解释）。

**遗留一个非确定性样本**：anti-detect 修复后出现过一次 `PAUSED@0.9`
（纯 base.js 内部栈，无脚本帧，单样本不复现）——oracle 已常驻固化
（只记 PAUSE 含栈，`/devtools` 可读），复发即有第一现场，届时按 actor
定点修，不再猜。

**重写决策**：不推翻八层结构——kick/re-bake/visibility-resume 经矩阵
证明与根因无冲突；被重写的是 yt-anti-detect 弹窗层（唯一行凶者）。
oracle 常驻后，若新形态复发再按证据决定是否合并管线。

**附**：诊断方法论沉淀——`/execute` 参数名是 `js` 不是 `code`（用错
静默返回 null，已两次浪费轮次）；A/B 二分用环境门
（`DESIRE_AB_NO_GUARD`）+ loader 注释开关，结论后全恢复启用。
