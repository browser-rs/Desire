# v0.8.48 规划稿（2026-11-10）—— VideoPro 收官：剪辑软件补全 + 可靠性贯穿

> 0.8.47 后的延续批。视频剪辑已升级为独立模块 VideoPro（对齐 ImagePro 架构：
> 命令 API / 桥 / Agent 工具 / 弱引用活动会话），本版把"剪辑软件"的差距补齐
> 并清掉 E2E 暴露的已知限制。四主题框架（浏览器基础 / Agent 基础 / 融合 /
> 替人干活）+ 两条贯穿（可靠性 / 可发现性）。

## 旗舰：VideoPro 剪辑软件补全（6 件）

1. **P0 · 文字烧录导出崩溃修复**（0.8.48 前已知限制：addtext 后 export 必崩）。
   `setVideoComposition:` 对文字 animationTool + Configuration 组合的拒绝路径
   独立深挖（候选：兼容 AVMutableVideoComposition 老路径 / 预检参数 / 文字轨
   改导出后置烧录）。验收：addtext → export 产出 mp4 且字幕可见；无文字直出
   回归不破。

2. **多标签会话 + 命令路由**（对齐 ImagePro）：VideoEditorStore 挂工程标识
   （title / 工程路径），`/video/edit` 与 `editVideoPro` 支持
   `file=<工程路径>` / `session=<id>` 定向，`/video/state` 带 sessions 清单；
   显式目标未匹配报错（不静默回落 active）。验收：双编辑器定向互不串扰。

3. **视频片段缩略图条**：AVAssetImageGenerator 按片段时间轴抽帧，视频轨
   lane 内渲染缩略图条（缓存按片段身份；显示路径只取可见区间）。音频已有
   波形（WaveformOverlay），视频对齐。验收：导入素材后视频轨可见画面预览，
   拖动/裁边不闪烁。

4. **导出看门狗**：导出挂起（进度 0 停滞 >60s）→ 终态 failed + 可重试
   （此前挂起无终态，桥 300s 超时、UI 永转）。进度回执进 exportState。

5. **工程自动草稿**：编辑后 3s 防抖写 .dtl 草稿（Application
   Support/Desire/VideoProDrafts/，按工程来源键），崩溃/强杀后重开可恢复
   （对齐 ImagePro drafts 的 save/restore/discard 语义 + 命令 API）。

6. **导出产物直达**：导出完成行内「显示于 Finder / 播放」+ 历史列表（cap 8
   已有）补入 Jobs 中心可见（对齐媒体导出任务的聚合体感）。

## 融合（1 件）

7. **媒体池增强**：双击插入到对应轨道（现状=按钮插入）、按名称过滤、
   每条素材显示时长/分辨率徽标。

## 替人干活（1 件）

8. **batchTrimVideos**：批量 trim/concat Agent 工具走 Jobs 台账（对齐
   batchProcessPDFs 模式：立即返回 job id、逐文件结果、失败可见），底层复用
   TimelineCore + VideoEditorStore.export 离线路径（editTimeline 引擎）。

## Agent 基础（1 件）

9. **editVideoPro 进桥评估**：固定用例进 E2E（addclip/split/trim/setclip/
   state 断言），防命令面回归；工具描述与命令实现漂移对账。

## 贯穿

- **可靠性**：导出看门狗（第 4 件）；`MainActor.assumeIsolated` 余量清查
  （PluginStore/PeekOverlay 等剩余调用点审计，0.8.47 后修了三处同类 PAC 崩溃）。
- **可发现性**：VideoPro 空态引导（空工程"添加素材"空态卡 + 快捷键速查卡
  J/K/L/S/⌘Z…）；工具箱 videoEditor 卡片描述更新为"多轨剪辑"。

## 不做（本版明确）

多机位、色轮调色、混音台、关键帧动画（音量包络已有）、字幕轨编辑器
（文字片段已有）、4K 导出性能专项、时间线框选（⌘/⇧ 多选已有）、
Remote 剪辑面、音频降噪/变调。

## 批次

- 批 1（P0）：文字烧录修复 + 导出看门狗（先清已知崩溃）
- 批 2：会话路由 + 自动草稿 + 缩略图条
- 批 3：媒体池增强 + batchTrimVideos + 桥评估 + 空态引导 + assumeIsolated 审计
- 发版：本地 Release clean 零警告 + harness + release-smoke；用户说「发」才发。

## 验收（每批过桥）

- 批 1：addtext→export 出片且字幕可见；无文字直出回归；挂起注入 watchdog
  触发 failed 终态。
- 批 2：双编辑器 file 定向互不串扰；强杀后重开恢复草稿；视频轨缩略图可见。
- 批 3：batchTrimVideos 出 Jobs 台账与产物；评估用例进 tests；assumeIsolated
  审计清单归档。

## 附录：`MainActor.assumeIsolated` 审计（2026-11-10 归档）

本轮实测崩溃点（`Timer` 回调 + assumeIsolated = SerialExecutor PAC 崩溃）已全部改为
`Task { @MainActor }` 跳帧：

- `FeedFetcher.scheduleTimer()`（本轮崩溃报告点名）
- `EbookReaderModel.startReadingSession()` 的统计计时器
- `EbookPDFReaderView.startStatsTimer()`
- `PeekOverlayController` 的 didBecome/didResignActive 观察者

此前已修（同形态，见 CHANGELOG）：ClipboardHistoryStore 轮询、TabManager 自动刷新、
ReadingProgressTracker 采样。

**保留 assumeIsolated 的调用点及理由**（再遇同类崩溃先看这张表）：

| 位置 | 形态 | 为什么保留 |
|---|---|---|
| `PluginStore.liveBuiltInAdGuardEnabled` | 同步取值 | 返回值必须可同步消费（webview 创建期） |
| `VideoAdBlocker:61` | 同步取值 | 同上（开关同步） |
| `AutomationServer:9204` | 同步取值 | 路由响应内联取数 |
| `TabManager:1471` | willTerminate、queue .main | 终止路径，跳帧可能来不及执行 |
| `TabManager:395` | DispatchSource、queue .main | 主队列事件源 |
| `EbookReaderModel:195/203` | 通知、queue .main | 主队列通知 |
| `ReaderSpeechService:40` | 通知、queue .main | 主队列通知 |
| `PeekOverlayController`（其余） | 通知、queue .main | 主队列通知 |
| `PluginsWindowController:56` | 通知、queue .main | 主队列通知 |
| `MediaPlayerModel:78` / `VideoEditorStore:139` | 周期观察者、queue .main | 0.2–0.25s 热路径，跳帧会积压 |

**结论**：`Timer.scheduledTimer` + assumeIsolated 这一对在本机是事故形态，
禁止新增；主队列通知/观察者可用，但性能敏感回调优先避免每帧创建 Task。
