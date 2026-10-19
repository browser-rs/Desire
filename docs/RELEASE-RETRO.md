# 发版复盘（Release Retro）

**用途**：每次发版记录**耗时与问题**，发版后补充反思与改进；改进落到
`scripts/release.sh` / `tools/pre-release-check.sh` / AGENTS.md，避免同一个坑付两次学费。

**规则**
1. 每次发版后在本文件追加一条：日期、版本、各阶段耗时、遇到的问题、改进动作。
2. `release.sh` 会在**退出时自动追加**一条阶段耗时记录（成功/失败都记），
   发版后把"问题与反思"补在该条下面。
3. 改进必须落成机制（脚本闸门/自动化），不靠"记得"。

**当前目标**：日常发版（含套件）≤ 35 分钟；`release.sh` 本体（不含套件）≤ 15 分钟。

---

## 历史记录

### v0.7.25（2026-10-20）

**耗时（release.sh 本体，两次中断续跑累计）**：约 25 分钟
（gates+prep ~2m → 首轮 clean build 在零警告闸门中止 ~7m → 修复后重建 ~7m →
ci local 失败 ~3m → 续跑 ci/package/publish/verify ~6m）

**问题与反思**
0. **启动无主窗竞态**（发版过程中暴露）：快速 `pkill -9 → open` 后偶发"桥起来了但
   主窗不建"（SwiftUI 场景恢复竞态，Debug/Release 都中；隔久一点启动或重开一次即
   恢复）。此前的 verify/smoke 只查桥——**窗口缺失也会假装通过**。已改：新增
   `launch_wait_window`（等 /state tabs ≥ 1，失败重启一次），run_local_suite 与
   verify 都用它。
1. **套件 15 分钟是发版日最大固定成本**：本版 app 代码改动多（弹窗/OAuth、划词卡、
   同步域、工具），套件必须重跑。结论：套件留在发版日，但 `release.sh` 本体要压到
   ~15 分钟；在"套件戳已覆盖 HEAD"时，本地评估套件与之高度冗余 → 跳过。
2. **零警告闸门在 build 阶段逮到 `SyncWireItem` 隔离警告**（`WorkspaceSync` 是
   nonisolated）：闸门按设计工作，但代价是整轮 clean build 白跑 + 重建。改进：
   提交前跑 `tools/pre-release-check.sh --build`（或在开发期收尾时跑一次），把
   警告扫在发版日之前。
3. **ci local 报 `no live agent session`**：`bridge_wait` 只等桥响应，窗口/会话
   还没注册完。已修：评估前轮询 `/agent/windows` 直到出现注册会话。
4. **smoke 阶段与 verify 冗余**：两者都是"非 DerivedData 路径启动 + 桥探活"；
   verify 从打包产物启动，覆盖面更全。**已删 smoke 阶段**。
5. **手工冻结 CHANGELOG 是多余步骤**：已改为 prep 自动冻结（`[Unreleased]` 有
   条目即自动改名 `## [vX.Y.Z] - 日期` 并提交）。
6. **发布中断不可怕，但续跑要清晰**：`--from ci` 等续跑正常；本版因用户中断
   进程被杀两次，靠状态检查（ps/tag/日志）确认断点后续跑。

**改进（已落地）**
- 删 `smoke` 阶段（verify 覆盖）；`ORDER` 七段 → `gates prep build ci package publish verify`。
- `ci` 在**套件戳覆盖 HEAD** 时自动跳过（`--force-ci` 可强制）。
- `prep` 自动冻结 CHANGELOG。
- `release.sh` 增加阶段计时 + 退出时自动追加本文件（成功/失败都记）。

### v0.7.24（2026-10-19）

**耗时**：~40+ 分钟（含套件 15 分钟；release.sh 本体 ~25 分钟 + verify 两次 CDN 超时等待）

**问题**
1. **预检跑在修复前的旧提交**（修复后未重跑）→ 用户指正"严重违反发版原则"。
2. verify 的 `gh release download` 反复 CDN 超时，每次拖 10–20 分钟仍需手工收口。
3. ci 等 GitHub 全程 14m35s（macOS runner 排队 + 全量构建）。
4. 首次发版内容太薄被用户否决，中止重开（changelog 只 4 条）。

**改进（已落地）**
- **gates 阶段内置**到 `release.sh`（永远跑最终提交）+ **套件戳**
  `.git/desire-e2e-stamp`（白名单校验），从机制上关死"忘跑预检"。
- `ci` 默认改 **local**；远端 CI 降为 `--ci gh` 抽查。
- `verify` 默认**快档**：GitHub 资产 digest 三方比对 + 本地包启动冒烟；
  `--verify-download` 才真实重下载。
- `tools/pre-release-check.sh` 瘦身为 ~1 分钟快查（`--build` 可选）。

### v0.7.23（2026-10-19）

**问题**：verify 从 release 重新下载资产时 CDN read-timeout（发布本身已成功）。
**改进**：digest 等效收口成为常规做法（后并入 verify 快档）。

### v0.7.22 / v0.7.21 / v0.7.20（2026-10-17 ~ 10-18）

**问题**：v0.7.20 内容清单过薄（4 条）导致发版中止返工；rustfmt 闸门两次因
未跑 `cargo fmt` 在 CI 翻红；CI 等待长。
**改进**：版本内容 ≥7 条实质变更；推送前 `cargo fmt`；后续引入 ci local / 流程脚本化。

---

## 阶段耗时基准（用于发现回归）

| 阶段 | 目标 | 说明 |
| --- | --- | --- |
| gates | ≤ 1.5m | 干净树/结构/单测/查重/套件戳（单测 ~40s） |
| prep | ≤ 10s | 自动冻结 + 版本号 + 推送 |
| build | ≤ 9m | clean arm64 + x86_64 交叉 |
| ci | 0（戳覆盖时跳过）/ ≤ 3m | 本地评估套件 |
| package | ≤ 1m | zip + SHASUMS |
| publish | ≤ 2m | 禁工作流→tag→release（含 408 资产重试） |
| verify | ≤ 2m | digest 三方 + 解包启动冒烟 + 恢复工作流 |
| **合计（不含套件）** | **≤ 15m** | |

### v0.7.25 — 成功（2026-10-20 01:35）

| 阶段 | 耗时 |
| --- | --- |
| ci | 0s |
| package | 4s |
| publish | 241s |
| verify | 19s |

**结果**：ci 按新规则自动跳过（戳覆盖 HEAD）、package 4s、publish 4m（84MB 资产
上传，网络为主）、verify 19s——**续跑段合计 ~4.5 分钟**。问题与改进见本文件上方
「v0.7.25」主条目（启动无主窗竞态 / 零警告闸门 / 评估会话就绪 / 删 smoke 等）。
**发布前状态**：套件 189/189（戳在最终提交 7091138）、Release 产物主窗 2 秒就绪、
优雅退出——开发与验证完成之后才启动发版。
