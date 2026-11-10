# v0.8.49 规划稿 —— 稳与通：崩溃韧性 + 字幕/音频闭环

> 基线：v0.8.48（2026-11-10，588）。0.8.47–0.8.48 把 VideoPro 从"能剪"推到
> "能交付"（文字烧录/转场/草稿/缩略图/批量/Jobs），也顺带暴露了浏览器本体的
> **韧性债**：本轮开发中多次强杀/崩溃后，标签会话丢失、首启无主窗；桥遇 NaN
> 能把主 actor 钉成僵尸却没有任何崩溃报告。这些不是新功能，是"浏览器每天都要
> 扛住"的地基。本版主题 = **稳（崩溃韧性）+ 通（字幕/音频闭环）**，附带
> 让"出过什么事"看得见（可观测 + 恢复提示）。

## 定位与取舍

- 不做 VideoPro 的下一轮大件（关键帧/色轮/混音台/多机位需要专版），只做
  **字幕与音频两个小闭环**，把已有 SubtitleCore / VideoBatchStore 接起来。
- 表单草稿恢复、passkey、Remote 剪辑面、4K 导入性能专项不在本版。
- 所有验收都走桥/脚本，不依赖手动点 UI；过程遵守"只开发测试，不替用户安装、
  不动用户数据"。

## 旗舰：崩溃韧性（浏览器基础）

### 1. 会话快照 2.0（P0）

现状：`persistSession()` 只在结构变化时调用，落盘走 `DiskStore` 500ms 防抖；
强杀（`pkill -9`）会丢掉最后一次变更，甚至整个窗口状态。

- **周期快照**：有未落盘变更时每 10s 写一次（同步原子写：`.tmp` → rename，
  不走 500ms 防抖），退出路径保持现状。
- **版本化**：快照带 schema 版本与写入时间；启动读取失败时回退到上一份
  （保留最近 2 份）而不是当空会话。
- **归档保留**：关最后一扇窗/退出时的归档（已有）继续保留，作为恢复兜底。

**验收**：加标签 → 打一个不做结构变化的操作 → `pkill -9` → 重开 → 标签数与
URL 一致；连续 3 轮。

### 2. 首启无窗自愈（P0，长期待修项）

现状：强杀后首启偶发"进程活着、无主窗、桥 tabs=0"（0.8.44 修过一轮，只覆盖
"有会话文件"的路径）。

- 启动完成后若 **无窗口**：先尝试恢复 `session-index` 最近会话；失败则建一扇
  新窗口（新标签页），并在日志/诊断里标记 `no-window-recovery`。
- 恢复路径要幂等：正常启动（已有窗口）零副作用。

**验收**：`pkill -9` → `open --automation` → `/state` 在 10s 内 `tabs >= 1`；
连续 5 轮。

### 3. 恢复提示与"上次异常退出"（P1）

- 启动检测：上次退出未走 `applicationShouldTerminate`（有 running 标记）→
  顶部提示条「上次未正常退出，已恢复 N 个标签 / 恢复上次会话」+ 关闭。
- Agent 侧：存在被中断的回合 → 面板提示「上次回合被中断，可继续/放弃」
  （复用 `resumeInterruptedTurn`，现在只有桥能触发）。
- 提示条不阻塞交互，记住"本次已提示"。

**验收**：构造 running 标记 + 强杀 → 启动提示条出现一次；桥 `GET /diag/startup`
返回 `abnormalExit=true`。

### 4. 挂起标签的可恢复性（P1）

- 挂起标签点击恢复时：滚动位置恢复（`scroll-memory` 数据已有，接上挂起路径）、
  保留标题/favicon（已有）。
- 挂起页占位卡显示站点名 + 最后访问时间 + "恢复"按钮（现状只有标题）。
- 不做表单字段草稿（跨站语义复杂，明确挪出）。

**验收**：页面滚到中部 → 挂起 → 点开 → `window.scrollY` 在 ±50px 内。

## Agent 基础：出过什么事，得看得见

### 5. 主线程心跳与僵尸检测（P0）

现状：主 actor 被 ObjC 异常钉死后，应用"看起来正常"——窗口渲染、事件循环都在，
桥全超时、无崩溃报告（本轮遇到两次，靠 `sample` + lldb 手工定位）。

- 新增 `RuntimeHealthMonitor`：后台每 2s 向主队列投一个心跳，超过 10s 未消费
  → 统一日志 `fault`（category `health`，带主线程 sample 摘要）+ 写
  `~/Library/Application Support/Desire/health/last-stall.json`。
- 体检页/诊断包展示最近一次停滞（时间、持续、栈摘要），下次启动提示
  「上次运行出现主线程停滞，已记录诊断」。
- **不做自动重启**（RunLoop 已坏，进程内无法自愈），只做取证与提示。

**验收**：桥注入一个可控的"主线程假死"测试钩子（DEBUG-only：睡眠 15s）→
心跳 fault 日志出现、`last-stall.json` 生成、重启后提示条出现。

### 6. ObjC 异常统一探针（P1）

现状：只有 VideoPro 装了 `NSSetUncaughtExceptionHandler`。

- 全局安装（AppDelegate）：异常 reason + 栈写统一日志（`category "objc"`）与
  诊断包；VideoPro 的局部探针退役，避免双份。
- 覆盖 KVC 错键、NSRange 越界、JSON 序列化这类"穿 async 帧"的已知形态。

**验收**：DEBUG 钩子抛一个 NSException → 日志有 reason，进程仍按系统流程终止。

### 7. 回合中断恢复的可发现化（P1）

- 启动/切换会话时，若 `hasInterruptedTurn`：面板显示可点的「继续上次回合」，
  与桥 `/agent/open` + `resume` 同路径。
- 继续时保留工具结果边界，不重复执行已完成的工具（现状已保证）。

**验收**：构造中断会话（工具执行中强杀）→ 启动 → 面板提示 → 点击 → 回合继续
并产出最终回答（桥断言最终消息）。

## 融合 / 替人干活：字幕与音频两个小闭环

### 8. SRT 字幕 ↔ 文字片段（P0）

现状：`SubtitleCore`（SRT/VTT/ASS 解析）只服务工具箱；VideoPro 的文字片段
只能手打。

- **导入**：VideoPro 工具行「导入字幕…」→ 选 `.srt/.vtt` → 按 cue 时间批量建
  文字片段（落在文字轨，样式用默认白字黑边，cue 文本进 `Clip.text`，可逐条再编辑）。
- **导出**：工具行「导出字幕…」→ 文字轨片段按时间生成 SRT（时间取 start/duration，
  文本取 `text`），空文本片段跳过。
- 命令 API：`addsubtitles {path}` / `exportsubtitles {path}`；Agent 工具描述同步
  （`editVideoPro` 动作面 + 漂移对账脚本要过）。
- 编码：UTF-8 优先，BOM/GB18030 兜底（中文 SRT 常见）。

**验收**：导入 3 条 cue 的 SRT → 状态里 3 个文字片段、时间一致；导出后 round-trip
文本与时间一致；导出视频里首条字幕可见（帧检）。

### 9. 批量音频提取（P1）

- `VideoBatchStore` 加 `audioOnly` 模式：文件夹内 mp4/mov/m4v → `Audio/<name>.m4a`
  （复用离线导出引擎的 m4a 路径）；Agent 工具 `batchTrimVideos` 加 `audioOnly`
  参数；桥 `/video/batch` 同步。
- Jobs 台账同款（进度/产物/失败逐项）。

**验收**：2 个视频 → 2 个 m4a，时长与源一致；Jobs 状态 done。

### 10. 导出预设记忆（P2，可发现性）

- VideoPro 的导出高度/仅音频/目标目录跨会话记忆（UserDefaults），导出面板显示
  上次选择。

**验收**：设置 720p + 仅音频 → 重启编辑器 → 面板仍是该预设。

## 贯穿

- **可靠性**：本版本身就是可靠性版；额外要求每批跑
  `tests/video-pro-e2e.py` + `tests/video-pro-actions.py` + `tests/run.sh`，
  会话/心跳相关进 `tests/release-smoke.py`。
- **可发现性**：恢复提示条、体检页"上次停滞"卡、VideoPro 字幕按钮的 help 文案；
  i18n 三语在提交时补齐（CLI 构建不抽键）。
- **不做**：关键帧动画、色轮调色、混音台、多机位、时间线框选、4K 导出性能、
  表单草稿恢复、Remote 剪辑面、passkey（等 Apple entitlement）、DASH 下载
  （本机 ffmpeg 无 demuxer）。

## 批次

1. **批 1（P0）**：会话快照 2.0 + 首启无窗自愈（最大风险，先做；每步强杀实测）。
2. **批 2（P0/P1）**：主线程心跳 + 全局 ObjC 探针 + 恢复提示条 + 中断回合入口。
3. **批 3（P0/P1）**：SRT 导入/导出 + 批量音频 + 预设记忆。
4. **批 4（收口）**：挂起恢复、i18n/WhatsNew、套件扩展、Release 零警告。

**发版**：用户说「发」才发；本地 Release clean 零警告 + harness + release-smoke
是硬闸门。
