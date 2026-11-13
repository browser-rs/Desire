# v0.8.55 规划稿（2026-11-13）—— AI 修图闭环：让 Agent 看得见、修得好、批量替你修

> 起因：v0.8.54（+ 发版后批 7）把 ImagePro 推到专业级——图层/蒙版/图层组、曲线/色阶/
> 渐变映射、17 混合模式、13 专业滤镜、分离式修复、液化、透视校正、盖章可见、图层导出。
> 但 Agent 用它仍是**盲修**：`editImage` 的 `state` 只回结构化元数据（图层数/尺寸/选区/
> 直方图数字），模型**看不见画布**。图片编辑的核心判断（构图歪不歪、哪里过曝、水印在
> 哪、修完干不干净）恰恰是视觉判断。本版把视觉通道接上，形成
> **看见 → 诊断 → 修 → 自检 → 报告**的完整闭环。
>
> 这是"AI 原生浏览器"差异化最直给的一版：别的浏览器能开图片编辑器，
> **Desire 的 Agent 能替你修图**。

## 一、现状核实（2026-11-13，动手前逐项查过）

- **vision 通道已存在且在用**：工具结果返回 dataURI 即作为 vision input 进模型
  （`screenshot` / `screenshotElement` / PDF 页渲染都走这条；`AgentService.encodeMessage`
  支持 `image_url` parts）。`lookImage` 是纯复用，不需要新协议。
- `editImage` 命令面 40+ action 全齐（brush/liquify/perspective/adjust/curves 数据/
  mask/layer/blend/…），缺的只有"看"。
- `histogram` action 已有（数字诊断）；直方图 UI 已有（曲线编辑器背景实时重算）。
- 右键图片"编辑图片"已有（`PageContextMenu.editImage`）；**"让 Agent 修图"没有**。
- 批量修图引擎已有（`ImageBatchEditStore` + Job 队列 + `batchEditImages` 工具，
  0.8.43）——但**每张图同一参数**，不看内容；AI 逐张定策略的模式没有。
- 大图降采样显示已有（`displayComposite(maxSide: 4096)`）；历史面板已有；蒙版/
  图层组/液化已在 0.8.54+批 7 落地。
- Agent 截图自检在**页面**侧已成惯例（screenshot → 看图 → 修正动作）；**图片编辑**
  侧完全没有等价物。

## 二、四主题

### ① 融合（旗舰）＝ AI 修图闭环

1. **`lookImage` action**（editImage 新增）：把画布渲染成 vision input 返回——
   `{"mode":"canvas|layer|before|after|compare"}`：
   - `canvas`：当前合成（降采样到 ≤1568px 长边——多模态模型的实用分辨率上限，
     防大图烧 token）；
   - `layer`：活动图层独立渲染（透明底）；
   - `before` / `after`：原图锚点 / 当前合成；
   - `compare`：before/after **并排拼一张**（同高、中间 4px 分隔线），自检用一眼对比。
   返回 dataURI + 轻量文本头（尺寸/长边像素/图层摘要），文本防纯图结果被结果预算截断。
2. **修图工作流进工具面**：`editImage` 描述补工作流指引（look → histogram → 修 →
   look compare → 汇报）；`screenshot` 系描述的"自检"措辞统一，`lookImage` 进
   分组索引（`listTools` / `<tools>` 自动跟上——索引是生成的，加进 defs 即可）。
3. **右键"让 Agent 修这张图"**：`PageContextMenu` 图片菜单新增入口——复用
   `editImage` 的 URL 解析打开编辑器，随后把修图任务注入当前/新建 Agent 会话
   （走既有 askAgent/deep-link 通路，不新增系统）。提示词模板落在 skill/常量，
   三语。
4. **修图报告卡**：修完后 Agent 用既有 `whiteboard` render 一张 compare 图 +
   操作清单（"去水印（内容填充）· 曲线提亮 · 直方图见附图"）——不新增卡类型，
   复用白板的 image block；`screenshot`（whiteboard）自检通道天然可看板子渲染效果。
5. **可观测性**：轨迹步骤里 look 次数可从 tool calls 派生（不加新状态）；
   `GET /agent/trace` 现有 steps 已带工具名，验证即可，不改动轨迹结构。

### ② 浏览器基础（ImagePro 收官小件）

1. **选区内容填充（内容感知·简化版）**：套索/矩形选区 → 用周边纹理+亮度融合填充
   （分离式修复的区域化放大：源纹理从选区外环带采样，按分离式 heal 的
   克隆×低频比值融合回填；源区自动选 = 选区外侧同尺寸环带，`sourceRect` 可显式指定）。
   诚实边界：平滑/规则背景（天空、墙面、纯色地面）上去水印/去路人可用；
   复杂纹理不做 PatchMatch 级合成（明确不做）。命令 API `contentfill {useSelection}`，
   UI 挂编辑菜单 + ⌥⌫。
2. **全屏编辑模式**：编辑器窗口支持原生全屏（⌃⌘F），全屏中**保留工具轨/选项栏**
   （可用性取舍按"能不能用"判：全屏编辑不能没有工具）——`isWindowFullScreen`
   只管边距那套既有经验直接适用，编辑器是独立 scene，不碰 ContentView。

### ③ Agent 基础（vision 工具面规范化）

1. `lookImage` 进工具 defs（随 editImage 的 action，不新增独立工具——避免工具面
   再膨胀）；描述里**显式反盲修**："never adjust/filter/crop blind — look first,
   look compare after"。
2. 自检措辞统一：screenshot/whiteboard/editImage 三处描述的 self-check 指引对齐
   同一句式（看 → 修 → 看 → 汇报），弱模型也能跟。
3. 评估：agent-eval 加一条 fixtures（假端点逼 look → edit → look 序列，断言
   两次 vision 调用与中间的编辑 action）。

### ④ 替人干活 ＝ AI 批量修图值守

- 文件夹 → Job 队列逐张处理：**每张先 look 缩略图（长边 512）→ Agent 按
  同一风格策略定参数 → batchEditImages 的既有单图管线执行**；
  完成 = 既有 Job 通知 + 汇总（成功/失败/每张操作摘要）。
- 复用清单：`ImageBatchEditStore`（队列/重试/汇总）、Jobs 面板、
  `watchBackgroundTask`、通知分级。新增的只有"逐张 AI 定参"这一层
  （新工具 `aiBatchEditImages {folder, style prompt, outputDir}`）。
- 成本诚实：逐张 look 烧 vision token——工具描述写明"每张一次 look，预算
  = 张数 × 单图调用"，不静默放大。

### 贯穿（可靠性 / 可发现性）

1. **强杀/崩溃后首启无主窗收口**（v0.7.26 老条目，缓解已交付 2026-10-21 但
   2026-10-25 又一天三次复发）：`LaunchWindowHealer` 已有 heal/relaunch——
   本版排查残余路径（healer 判定窗口的时点 vs SwiftUI scene 建立的竞态、
   无窗但桥已活的分支），给出确定性收口：**首启探测到无窗且 index 采纳失败
   → 必 mint 主窗 + 恢复 index 最近标签**，10/10 强杀重启验证。
2. i18n 三语 + WhatsNew 刷本版亮点（发版前）。
3. 探针/测试：compare 拼图（同高并排）纯逻辑进 harness；lookImage 通道用
   假端点抓请求体断言 `image_url` part 真进模型（沿用 AI 端点验证手法）；
   contentfill 探针走命令 API（合成图 + 像素断言）；全屏/首启无窗 E2E 手测项。

## 三、不做（本版明确）

- RAW 解码管线、PSD、调整图层（adjustment layer）、通道级蒙版运算、矢量图形系统。
- PatchMatch 级纹理合成（contentfill 只做简化版，诚实标注适用边界）。
- 把白板改造成独立报告系统、新增卡类型。
- Agent 无确认自动修图（destructive 动作仍走既有审批/接管锁）。
- 视频剪辑大件、iPad 编辑器、第三方编辑器插件。
- 视觉通道协议改动（完全复用 dataURI 工具结果，不碰 encodeMessage 协议）。

## 四、批次

- **批 1（地基）**：`lookImage` 全模式渲染 + dataURI 通道 + 文本头 + `editImage`
  描述反盲修指引 + 分组索引跟上。
- **批 2（工作流面）**：右键"让 Agent 修这张图" + 修图提示词模板（三语）+
  报告卡措辞 + agent-eval fixture。
- **批 3（ImagePro 小件）**：选区内容填充（命令 API + 编辑菜单/快捷键 + 探针）+
  全屏编辑模式。
- **批 4（值守 + 收口）**：`aiBatchEditImages` + 汇总报告 + 首启无窗确定性收口 +
  i18n/WhatsNew + Release 闸门。

## 五、验收

1. **闭环**：Agent 一句话"把这张图调亮、去掉左下角水印"——look → 选区+填充 →
   调节 → look compare 自检 → 白板报告，全程不碰编辑器 UI。
2. **通道**：假端点抓请求体，`lookImage` 的结果以 `image_url` part 进模型；
   compare 是同一高度并排图。
3. **右键入口**：任意网页图片 → "让 Agent 修这张图" → 编辑器打开 + 任务注入会话。
4. **contentfill**：合成图（纯色背景 + 覆盖水印文字）选区填充后像素断言无残留；
   复杂纹理区域返回诚实说明。
5. **全屏编辑**：⌃⌘F 进出，工具轨/选项栏全程可见可用。
6. **批量值守**：fixture 文件夹 5 张 → Job → 完成通知 + 汇总含每张操作摘要；
   每张恰好一次 look（日志计数）。
7. **首启无窗**：pkill -9 → 重启 10/10 出主窗（含 tabs≥1）。
8. **闸门**：harness 全绿、Release clean 零警告、双架构 CI 绿。

## 六、版本口径

- 版本号 v0.8.55；已落盘的批 7（液化/透视）随本版一起发。
- 发版流程照旧：`bash tests/run.sh` + `python3 tests/release-smoke.py` +
  Release clean 零警告 + `scripts/release.sh 0.8.55`，云端双架构全绿自动建 tag。
