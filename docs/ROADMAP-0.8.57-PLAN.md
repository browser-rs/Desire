# v0.8.57 规划稿（2026-11-14）—— 产物闭环：干完的活有地方看、拿着就能继续干

> 定位：**替人干活旗舰**（主题轮换——该主题上次当旗舰是 0.8.40 值守批）。起因：
> 盘点发现"替人干活"的产能面已极厚（批量下载/剪辑/修图/转码/PDF/纯工具/研究简报/
> 死链值守/后台命令，全部走 Job 台账），但**产出物是散的**——Edited/（批量修图）、
> Converted/（水印转换）、下载目录（媒体）、简报 md 各回各家；Jobs 面板随 Job 老化
> 只显近期；想"对着上次批量修图的输出文件夹再跑转码"得手动找路径。**产物没有组织，
> 活就没有连续性**。本版把产出物变成一等公民：有地方看（产物中心）、拿着就能继续干
> （再加工 + 作业链）、手机上也看得见（Remote 产物卡）。

## 一、现状核实（2026-11-14，动手前逐项查过；证伪即排除）

**已存在/已建成（不重复造）**：
- 多窗口 Agent 联动：`focusWindow`/`moveTabToWindow`/`organizeWindows` 0.8.52 已落
  （AGENTS.md"未实现"条目**过时**，本版顺手修正）。
- 回合检查点/恢复：`checkpointSave` + interrupted-resume 已有。
- 标签任务分组：`TaskGroupPlan` + groupTabs 已有。
- 记忆生命周期：decay（`decayOldFacts`）已有；冲突复核向导已有。
- 阅读列表离线缓存：`.webarchive` 已有。
- 提醒事项/备忘录：EventKitBridge/NotesBridge 已有。
- C7 admin CLI：0.8.44 已落。
- 后台命令依赖：`BackgroundCommandStore.dependsOn`（crew 0.8.16 起已有）——但**只覆盖
  runBackgroundCommand**，批量作业族（下载/转码/修图/剪辑）没有链。

**真缺口（本版目标）**：
1. **产物无组织**：`JobRecord.artifactURL` 散落各 Job，无跨 Job 的产物视图；
   `desire://artifacts` 不存在（核实过）。产物行没有"发送到…/再加工"入口。
2. **批量作业族无链**：`JobTemplate` 是单命令模板（runCommand 语义）；"下载→转码→
   加水印"这类连续活每步都要人推。
3. **Remote 只见任务不见产物**：RemoteControlStore 已透 artifact 前缀文本，
   但没有预览/深链/再加工。
4. **长套件尾部退化**（0.8.56 实测四轮失败轮换）：execution-e2e 无分节隔离，
   一跑 15 分钟全量。
5. 响应式模式遗留：pixelRatio 模拟可做；真网络节流维持证伪（WebKit 无 API）。

## 二、四主题

### ① 替人干活（旗舰）＝ 产物中心

1. **`ArtifactIndex`**（纯逻辑进 harness）：从 `JobStore` 派生产物清单——带
   artifactURL 的 Job + 各批量引擎的输出目录约定（Edited/Converted/下载产物/简报）
   归一成 `ArtifactItem {id, kind, path, size, jobID, jobTitle, at, conversationID}`；
   分类规则（image/video/pdf/document/archive/folder）+ 去重（同路径多 Job 取最新）。
2. **`desire://artifacts` 页**（新 desire 页面体系成员）：时间线分组（今天/本周/更早）
   + 类型过滤 + 大小/来源 Job/来源会话；行右键 **发送到…**（白板/摘录/手机/分享卡，
   复用既有 ToolResultDispatch 出口）+ **拿去再加工**（对文件夹：批量修图/转码/
   organizeFiles 预览；对单文件：ImagePro 打开/邮件/Finder 显示）。
3. **Agent 工具 `listArtifacts {kind?, days?}`**：结构化清单（路径/类型/大小/来源），
   模型据此自主发起"再加工"——与工具面既有 batchEditImages 等无缝衔接。
4. Jobs 面板行加"在产物中心显示"跳转（双向可达）。

### ② Agent 基础 ＝ 作业链 2.0

1. **`JobChain`**（纯逻辑进 harness）：steps 数组，每步 = `{tool, params 模板,
   占位符}`；占位符 `{prev.artifact}`（上一步产物路径）/`{prev.artifactDir}`——
   替换后作为下一步的 folder/path 输入。推进引擎复用 `JobEventCenter` 终态事件：
   上一步 `done` → 替换占位符 → 启动下一步；`failed` → 链停 + 汇总（已成功步不回滚）。
2. **模板与工具**：`JobTemplate` 扩 `steps`（向后兼容——单命令模板 = 单步链）；
   Agent 工具 `runJobTemplate` 支持链式模板；`saveJobTemplate` 可存链。
3. 风险对齐：链里含危险工具（runCommand 类）的步骤沿用既有审批/风险分级，链启动时
   整链预览一次。

### ③ 融合 ＝ Remote 产物卡 + 响应式遗留

1. **Remote 产物卡**：任务帧的 artifact 从前缀文本升级为结构化卡（类型图标 + 大小 +
   "在 Mac 上打开"深链 `desire://artifacts`）；手机端发"再加工"指令（复用既有
   remoteTask 通道，参数 = 产物路径 + 动作）。
2. **响应式模式收口**：pixelRatio 模拟（deviceScaleFactor 注入 +
   `window.__desirePixelRatio` 覆写）——遗留清单里唯一可做项；真网络节流维持
   "WebKit 无 API，勿做假 UI"证伪结论。

### ④ 浏览器基础 ＝ 评估分节隔离（测试基建收口）

1. `execution-e2e.py --section <name>`：MUSCLE 分节可独立跑（各自的前置/清理自包含）；
   `--sections fast` 预设快档（CI/日常跑）与 `all`（里程碑）。
2. 0.8.56 实测的轮换失败类（splitView/收件箱/阅读进度）逐节定位：分节内重跑 3 次
   稳定才标绿——尾部退化多半是共享实例状态，分节重启实例即可消。
3. agent-eval 的 E19/E20 归入 release-smoke 可选档（`--eval-e19e20`）。

### 贯穿（可靠性 / 可发现性）

- 纯逻辑（ArtifactIndex 分类/去重、JobChain 占位符替换/推进状态机）进 harness。
- AGENTS.md 过时条目修正（多窗口 Agent 联动）+ 产物中心诊断端点
  （`GET /artifacts`——桥可验）。
- i18n 三语 + WhatsNew 刷本版亮点（发版前）。
- E21 评估（假端点逼 listArtifacts → 对产物文件夹发起 batchEditImages）。

## 三、不做（本版明确）

- 跨设备产物同步（文件体量大——走用户自己的 iCloud/网盘；Remote 只做卡与指令）。
- 新作业类型（产能已够；本版管组织不再管产能）。
- 响应式真网络节流（WebKit 无 API，勿做假 UI——维持证伪）。
- passkey（Apple entitlement 外部依赖，等批复）。
- 产物全文检索/OCR（Spotlight 已索引文件内容，不重复造）。
- 工作流（Workflow）与作业链合并（两者语义不同：回放是确定性脚本，链是异步作业图）。

## 四、批次

- **批 1（产物中心地基）**：ArtifactIndex + `desire://artifacts` 页 + `GET /artifacts`
  + `listArtifacts` 工具 + harness。
- **批 2（作业链）**：JobChain 推进引擎 + JobTemplate steps + runJobTemplate 链式 +
  整链预览审批 + harness + E21。
- **批 3（融合面）**：产物行发送到…/再加工右键 + Jobs 双向跳转 + Remote 产物卡 +
  响应式 pixelRatio。
- **批 4（收口）**：eval 分节隔离 + AGENTS.md 修正 + i18n/WhatsNew + Release 闸门。

## 五、验收

1. **产物可组织**：跑一次批量修图 → `desire://artifacts` 出现 Edited/ 行（类型
   folder、带来源 Job 与会话）→ 右键"再加工 → 转码"直接起 Job，参数带对路径。
2. **链自动推进**：三步链（echo 造产物 → 转码 → 汇总）走 runJobTemplate，
   `{prev.artifact}` 替换正确、失败停链不回滚、汇总含每步状态。
3. **模型自主衔接**：假端点逼 listArtifacts → 对产物文件夹发起批量作业（E21）。
4. **手机可见**：Remote 任务帧出产物卡（类型图标 + 深链）。
5. **分节隔离**：`--section muscle14` 独立跑稳定；`--sections fast` 时长 ≤ 1/3 全量。
6. **闸门**：harness 全绿、Release clean 零警告、双架构 CI 绿、smoke 26/26。

## 六、版本口径

- 版本号 v0.8.57（构建号 597）；发版流程照旧：tests/run.sh + release-smoke +
  Release clean 零警告 + `scripts/release.sh 0.8.57`，云端全绿自动建 tag。
