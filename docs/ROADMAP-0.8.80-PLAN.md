# v0.8.80「站点会学习」规划稿（2026-11-26）

> 0.8.77/0.8.78 让批量下载变准、变快、有依据（正片识别 / DPP 站点规则 / 分片并发 / 下载方式研判）。
> 这一版让**站点自己记住**：每次任务把实测的速度、连接数、失败原因沉淀回该站点的 DPP 规则，
> 下一次直接采用；适配器从"能跑"变成"能看、能改、能带走"；并把 0.8.77 事故暴露的测试盲区
> 制度化（形态矩阵 + 跨重启续传 + 直播覆盖 + 190 里程碑）。

## 现状依据（规划前核实，2026-11-26）

| 事实 | 核实位置 |
|------|----------|
| 每个 HLS 下载都实测单连接/并发速度（`ParallelTuning`），结果只进日志与任务回执，**站点没有记忆** | `MediaExporter+ParallelHLS.swift`、`ParallelTuning.swift` |
| 用户定调：同一个网站速度变化不大，"不是每个都要测速"，应与 DPP/技能结合 | 本会话用户原话（见 [[desire-v0877-plan]]） |
| DPP `download` 段只有提取/参数/打磨记录，**没有速度或引擎画像字段** | `DPPAdapter+Download.swift` |
| 下载面板列批次、可展开日志；**没有按站点聚合的记录/诊断视图，也没有对应桥端点** | `BatchMediaPanel.swift`、`AutomationServer.swift` |
| DPP Studio 是 JSON 编辑器（有 Load Installed Adapter）；**下载规则没有字段化表单** | `DPPStudioSheet.swift` |
| 适配器只能导入 / 从 URL 安装；**没有导出** | `DPPAdapterStore.swift`（import/installFromURL/remove） |
| 预取工作目录按来源页稳定命名（0.8.78），未完成批次会恢复；**跨重启续传没有测试** | `BatchMediaExportStore.swift`（workKey）、`persistUnfinished` |
| 夹具没有无 ENDLIST 的直播流，**直播路径没有 E2E** | `tests/fixtures/batch-site-server.py` |
| `tests/execution-e2e.py` 没有参数解析，**`--section` 未实现**；190 自 0.8.75 未跑全量 | `tests/execution-e2e.py` |
| v0.8.61 的 DiskStore IO 外移 / ArchiveGC / Doctor 页**已落地**（勿重复规划） | `Storage/DiskStore.swift`（DiskStoreWriter/ioQueue）、`ArchiveGC.swift`、`AgentDoctorView.swift` |
| 翻译 2.0（懒翻/缓存/旁路）**未实施**，v0.8.62 计划仍有效 | `ReaderTranslationCore.swift` 无 cache/lazy/bypass |

## 1. 站点速度证据（DPP `download.measured`）

- **现状**：每次下载测速一次（固定代价：单连接抓第 1 个分片），结果不落站点。
- **增量**：`download` 段新增 `measured`：`singleBytesPerSecond` / `parallelBytesPerSecond` /
  `connections` / `samples` / `lastMeasuredAt`（最多 5 次 EMA）。下载时若命中且"≤7 天且 ≥2 样本"
  → **跳过测速**、直接采用画像连接数（研判行写明"按站点实测 3.2 MB/s，3 天前"）；否则测一次并回写
  （复用 `refineDownloadRules` 的备份 + 修订机制）。`probeDownload` 回执同样引用缓存并注明时间。
- **验收**：同一站点连续两批 → 第二批日志**无** "speed probe"，研判行引用缓存；适配器 JSON 出现
  `measured`；`probeDownload` 回执带"上次实测"；过期/低样本时照常重测。

## 2. 站点画像进回执与说明技能

- **现状**：`downloadVideoList` / `downloadMedia` / `probeDownload` 回执不含站点历史；同步技能只写规则参数。
- **增量**：回执带一行"本站画像：上次引擎 X · 连接 Y · 实测 Z MB/s · 最近失败原因"；
  `SiteDownloadSkillSync` 的说明技能补一行已知参数（只写事实，不写提取细节）。
- **验收**：假模型回合抓回执断言；技能文件含该行；规则变更后技能随指纹更新。

## 3. 下载记录与站点统计

- **现状**：面板列批次 + 日志；没有按站点聚合的视图/端点。
- **增量**：`GET /downloads/history`（按批次与站点：引擎、连接、平均速度、耗时、失败原因计数）+
  设置 → 批量下载下的"下载记录"小节（数据从落盘批次/日志派生，不新增状态；离屏快照可拍）。
- **验收**：端点在 E2E 断言；快照宽/窄各一张；统计口径与 `BatchMediaLog` 一致。

## 4. 站点历史只提示、不自动换路

- **现状**：无站点历史；0.8.78 的原则是"方式定下就按它执行，失败不偷偷换"。
- **增量**：auto 时若本站同一引擎近期失败 ≥2，研判回执与批次日志提示"建议 method=…"（不改路径）。
- **验收**：纯逻辑单测（阈值/措辞）+ 回执断言。

## 5. DPP Studio 的下载规则表单

- **现状**：只有 JSON 编辑器（可载入已有适配器）。
- **增量**：download 段字段化编辑——`detail`（正则/选择器）、`perPage`、`engine`、`connections`、
  `tokenMinutes`、`exclude` 列表增删、`measured` 只读展示；校验复用 `saveDPPAdapter` 的同一套；
  JSON 高级模式保留，表单↔JSON 往返一致。
- **验收**：往返单测（表单改 → JSON → 再解析 → 相等）；快照；手动走查。

## 6. 适配器导出

- **现状**：只能导入/URL 安装，无法把自己的站点规则带走。
- **增量**：`POST /dpp/adapters/export {name}` → 本地 JSON 文件（**剥离打磨记录** measured/revisions/
  lastXxx，保留规则与协议体）；设置行加"导出"。
- **验收**：导出→重新导入→规则与协议体一致（round-trip 断言）。

## 7. E2E 形态矩阵

- **现状**：加密流是 0.8.78 才补的（事故驱动）；直播/字节切片/SAMPLE-AES/跨重启续传没有覆盖。
- **增量**：`docs/TEST-MATRIX.md` 列出"线上必然出现"的输入形态，逐项映射到断言位置
  （夹具页/套件/用例名），缺项清零；新增：直播（无 ENDLIST）、字节切片、SAMPLE-AES（探测口径）、
  跨重启续传、适配器导入/徽标。
- **验收**：矩阵每行有断言；套件对应项全绿。

## 8. 跨重启续传

- **现状**：workKey 按来源页稳定（0.8.78），未完成批次恢复为暂停态；续传路径没有测试。
- **增量**：恢复后从预取目录续传（已抓分片不再请求）；面板与批次卡显示"可续传 N 片"；
  新增 `tests/resume-after-restart-e2e.py`（起批 → 中途 quit → 重启 → resume → 夹具 `/stats`
  断言已抓分片只请求过 1 次）。
- **验收**：新 E2E 全绿；190 里的恢复用例不回归。

## 9. 直播流收尾

- **现状**：直播走"并发预取当前窗口 + 内置拼接"，没有 E2E，停止条件只在代码注释里。
- **增量**：明确停止条件（用户停止 / 可选时长上限）、回执与面板写明"只导出当前可用分片"；
  夹具加无 ENDLIST 的直播播放列表并覆盖（含"窗口滑动后再导"）。
- **验收**：夹具 E2E；探测回执对 live 的事实与规则明确。

## 10. execution-e2e 分节化 + 190 全量里程碑

- **现状**：套件无参数解析，`--section` 未实现；190 自 0.8.75 后未跑全量。
- **增量**：`--section browser|agent|media|sync|ops` 分节（按用例名前缀/分组表），默认全量；
  本版跑一次全量并归档到 `docs/TEST-REPORTS/`。
- **验收**：分节运行与全量运行均 ALL PASS；报告入库。

## 批次

1. **可证明性**：7（矩阵 + 缺项夹具/断言）+ 8（跨重启续传 E2E）。
2. **画像闭环**：1 + 2 + 3 + 4。
3. **适配器完整化**：5 + 6。
4. **直播与里程碑**：9 + 10 + 收口（What's New / Release 零警告 / 190）。

## 不做

- 翻译 2.0（下一版旗舰，v0.8.62 计划保留）。
- Remote 新能力、passkey、动态成本路由、第三方机翻引擎、网络节流 / pixelRatio。

## 风险

- 画像缓存可能让"变慢的站点"沿用旧参数：TTL（7 天）+ 样本门槛（≥2）+ 失败计数（≥2 提示）兜底。
- Studio 表单与 JSON 双入口的一致性：以 JSON 为唯一真相，表单只做受控字段的读写与 round-trip 测试。
- 直播语义边界（窗口滑动、停止条件）容易含糊：先写清口径再实现，E2E 以"只导出当前分片"为准。
