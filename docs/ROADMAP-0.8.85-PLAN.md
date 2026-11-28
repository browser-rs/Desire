# v0.8.85 规划稿（2026-11-29）—— 真功夫：色彩不降级 · 非破坏到底 · 选得准 · 批得动

> **主题叙事**：ImagePro 走过三轮加厚（v0.8.46–47 二十迭代、v0.8.54 专业版、
> v0.8.55 AI 修图闭环），工具面已经够宽——15 个工具、图层/蒙版/图层组、17 种混合、
> 逐通道曲线、液化、内容填充、Agent 共用命令表。但对着代码逐项核实后，"专业"二字
> 还缺的是**底子**，不是更多按钮：全管线 59 处硬编码设备色域、54 处硬编码 8 位——
> 一张 Display P3 的 16 位照片，落一笔再存，就是未标定的 8 位设备色（本机实测：
> 原图往返 16 bpc + P3，现状管线输出 8 bpc + DeviceRGB）；有选区的调整直接烙进像素，
> 调完没法反悔；形状画完不可再改；置入的图层只能在数值框里缩放旋转；保存即压平，
> 图层与参数当场丢；撤销栈存全量位图，超大图只剩 2 步可退；而且这 11k 行编辑器
> **没有一条入库的回归用例**（历次 23/23 工具矩阵等 E2E 都在 /tmp 已丢）。
> 本版把 ImagePro 从"工具很多"做成"底子够硬"：先立护栏，再修地基（色彩与位深），
> 把非破坏做到底（调整图层、矢量形状、工程文件），补专业手感（自由变换、压感画笔、
> 智能选区），最后让 Agent 与批处理吃到的能力跟人工完全一致。
>
> **规模**：20 件（Track A 四主题 18 + Track B 贯穿 2），五批实施。
>
> **规划前核实（HEAD `37e12e25`，v0.8.84 已发布）**——以下**已交付，不进本版**：
> 坐标系统（`ImageCanvasTransform` 三空间唯一真相）、NSView 事件层、文字可再编辑
> （`textSpec`，f6d86df）、图层蒙版绘制/反相（`addMask`/`paintMask`/`invertMask`）、
> 图层组、逐层翻转/缩放/旋转/斜切字段、图层样式（投影/描边/发光）、套索双模式、
> 选区布尔（加/减/交叉/羽化/扩展/收缩）、修饰六模式、液化三模式、透视校正、
> 内容填充（简化版）、原图只读锚点 + 还原全部、自动草稿、会话挂标签的多编辑器路由、
> 超大图显示降采样 + 预缩缓存（96MP 稳态 ~210ms/笔）、网格/参考线/吸附、模板与
> 新建文档、从视频抓帧、EXIF 面板、水印、批量预设管线、直方图、lookImage 五模式
> 视觉通道。**既往"不做"清单里本版重新评估的**：RAW/PSD（ImageIO 本机确认可读，
> 列为 spike，实测通过才进）；其余（钢笔/智能对象/内容感知移动/PatchMatch）维持不做。
>
> **口径纪律**：像素级断言一律读落盘文件（`CGImageSource`），不读内存对象；色彩结论
> 必须带位深与配置文件名两个读数；性能数字 **Debug 与 Release 分开报**，阈值进
> `tests/perf-baseline.json`；Apple 框架的黑箱能力（人脸/主体/超分）只承诺"检出时
> 可用"与方向正确，**不承诺跨版本效果一致**。

## 存量收口（审计实锤，随批 1–5 修）

| # | 缺口 | 证据 | 影响 |
|---|------|------|------|
| S1 | **全管线 8 位 + 设备色域**：绘制/合成/修饰/合并/压平全部 `CGColorSpaceCreateDeviceRGB()` + `bitsPerComponent: 8` | 59 处设备色域（`ImageEditorRaster.swift` 31、`ImageEditorDocument.swift` 7、`ImageTransforms.swift` 5…）+ 54 处硬编码 8 位；入口 `ImageEditorRaster.swift:27-38` `drawingContext` | P3 / Adobe RGB / 16 位源图一编辑即降质；输出不带 ICC，换台设备颜色就变 |
| S2 | **导出无色彩/位深/元数据选项** | `ImageEditorSession.swift:401-422` `export(format, quality, scale)`；`ImageTransforms.save`（`:207-255`）WebP 走 `CGImageDestination` 不带配置 | 交付物不可控；EXIF 是否随图走全凭编码器默认 |
| S3 | **调整项缺 HSL 分色 / 色阶 / 分离色调 / 去雾**（旧编辑器有，重写时未迁入） | `ImageEditPipelineCore.swift:8` 起 `ImageAdjustParams`：20 个标量 + 渐变映射 + 曲线，无 hsl/levels/splitTone | 专业调色基本功缺失 |
| S4 | **选区内的调整是破坏性的** | `ImageEditorDocument.swift:1024-1050` `applyAdjust`/`applyFilter` 有选区即烙像素 | 局部调色不能反悔、不能微调 |
| S5 | **形状烙像素不可再编辑**（文字已可） | `ImageEditorRaster.swift:499` `drawShape`；图层只有 `textSpec`（`ImageEditorTool.swift:193-211`）；形状仅矩形/椭圆/直线/箭头 | 海报改个圆角要撤销重来 |
| S6 | **自由变换没有画布手柄** | `ImageCanvasView.swift:1146-1218` 只有裁剪手柄；缩放/旋转只在移动工具数值框 | 置入图层无法拖拽缩放旋转斜切 |
| S7 | **检查器一次只能开一个、固定 272pt** | `ImageEditorView.swift:66-69` | 调色时看不到图层/直方图 |
| S8 | **没有分层工程文件：保存 = 压平**；草稿只存合成图 | `ImageEditorSession.swift:252-272` `saveInPlace` → `flattened`；`ImageEditorDraft.swift` | 多图层作品无法二次编辑；崩溃恢复丢图层 |
| S9 | **撤销栈存全量位图** | `ImageEditorDocument.swift:72-73` 两个栈、`:88-98` `Snapshot.bitmaps`、`:79` `maxHistory`（>64MP 仅 2 步）；48 个入栈入口 | 长会话反悔不了 |
| S10 | **画笔无压感、无预设** | `ImageEditorSession.swift:60-62` 仅大小/不透明度/硬度；`ImageEventCatcher.swift` 无 `pressure` | 手绘/精修手感差 |
| S11 | **没有可回放的动作** | 历史存快照不存命令；`ImageBatchEditCore`（112 行）只套预设管线 | 修好一张没法批量套用 |
| S12 | **ImagePro 无入库回归** | `tests/execution-e2e.py` 与 `tests/agent-eval.py` 对 `/image/edit`、`/editor/synthetic` 零引用；`tests/` 只有 `imagepro-contentfill`、`imagepro-liquify` 两个纯逻辑 harness | 改一行都无护栏 |
| S13 | **智能能力只接了抠图，没进选区** | `ImageAICore.swift:13` `subjectMask` 只被 `cutout` 用；`select` 命令无 subject/color-range/luminance | 抠完没法继续羽化/反选/存蒙版 |
| S14 | **缺 8 种专业混合模式** | `ImageEditorBlend` 17 种（CG 原生全集）；CI 侧对应滤镜本机已验证存在 | 教程/协作对不上 |

## 本机能力探测（规划时实测，零第三方依赖）

- **ImageIO 可读 61 种类型**：含 **PSD**、**RAW 全家**（dng/cr2/cr3/nef/arw/rw2/orf/raf/pef…）、
  avif、webp、jxl、exr、jp2、tga；**不含 OpenRaster**。
- **16 位 + Display P3 PNG 往返**：`CGImageSource` 读回 `bpc=16`、`kCGColorSpaceDisplayP3`
  ——没被现状管线碰过的图是完好的，问题全在编辑链路。
- **CoreImage 现成可用**（已验证）：`CIEdgePreserveUpsampleFilter`（超分）、
  `CIFaceBalance` / `CIRedEyeCorrection`（人像）、`CIDocumentEnhancer`（文档增强）、
  `CISaliencyMapFilter`、`CIBokehBlur`、`CIColorCubeWithColorSpace`、`CIColorPolynomial`、
  `CILinearToSRGBToneCurve` / `CISRGBToneCurveToLinear`（线性光混合）、
  `CIColorThreshold`、`CIDither`；**缺失混合模式的 CI 对应**：线性加深/线性减淡/减去/
  划分/亮光/线性光/点光/实色混合（深色/浅色无现成滤镜，需自写颜色核）。
- **CIRAWFilter 可用**（RAW 开发滤镜存在，默认解码质量未评估）。
- **色彩空间**：displayP3 / linearDisplayP3 / extendedLinearSRGB / adobeRGB1998 / itur_709
  / DCIP3 均可构造。
- **不存在**：`CIColorClamped`、`CITiltShift`、`CIStraighten`、`CIColorHistogram`、
  `CIHueSaturationValueAdjust`（HSL 分色需自建 LUT）。

## Track A — 四主题（18 件）

### ① 浏览器基础（旗舰：ImagePro 专业内核，11 件）

**1. 色彩管线与位深**（S1、S2，P0）
- 做法：新增 `ImagePixelFormat`（**唯一入口**）——文档带 `workingSpace`（默认
  extended sRGB）与 `bitDepth`（随源：16 位源 → 16 位工作；设置可强制 8 位），全部
  CGContext 经它创建；CoreImage 侧显式 `workingColorSpace` / `outputColorSpace`，
  混合在线性光里做。保存/导出面板加四项：**目标配置**（保留源 / sRGB / Display P3 /
  Adobe RGB）、**位深**（8/16，仅 PNG/TIFF）、**分辨率**（像素/英寸/厘米 + DPI）、
  **元数据**（EXIF 保留或清除，GPS 单独开关）；输出图像带配置文件，ImageIO 落盘即嵌入。
  色域外溢检查（P1）：转换前统计落在目标色域外的像素比，超 1% 在导出面板提示。
- 验收：探针生成的 16 位 P3 PNG → 画一笔 → 保存 → 读回 `bpc=16`、配置名 = Display P3；
  笔画区域外逐像素与原图相等；导出 JPEG（sRGB）读回配置为 sRGB IEC61966-2.1，已知
  色块 ΔE2000 < 1；`/image/state.color = {workingSpace, bitDepth, sourceProfile,
  outOfGamut}`。

**2. 调整项补齐**（S3，P0）
- 做法：全部进 `ImageAdjustParams`（非破坏，随撤销/预览/LUT 导出/批量管线/Agent
  `adjust` 免费获得）：**HSL 分色**（红/橙/黄/绿/青/蓝/紫/洋红 × 色相/饱和/明度，
  由纯函数生成 `CIColorCube`）、**色阶**（每通道输入黑/白/γ + 输出，折算进既有每通道
  曲线点）、**分离色调**（阴影/高光 色相·饱和度 + 平衡）、**去雾**、**锐化细化**
  （数量/半径/细节/蒙版）、**降噪**（亮度/颜色分离）。新增字段带默认值，旧预设/旧
  工程解码不破。
- 验收：harness——8 个基准色各自移色相 ±30° 时邻色偏移 < 3°、中性灰不动；E2E——
  调"橙色饱和度 −100"后橙色块饱和度下降 ≥ 50% 而蓝色块不变；旧预设 JSON 解码成功。

**3. 调整图层 + 选区转蒙版**（S4，P0）
- 做法：新图层种类 `adjustment`（无像素：参数/滤镜 + 蒙版），作用于其下全部可见层；
  **有选区时"应用调整"不再烙像素**——改为新建调整图层并把选区转成它的蒙版；
  渐变/画笔可直接画在该蒙版上（复用 `paintOnMask`）；显示路径在预缩图上现算。
- 验收：有选区调曝光 → 图层数 +1 且类型 = adjustment、蒙版 bbox = 选区、下层位图
  身份不变（`===`）；选区外像素与原图逐像素相等；撤销/重做；改参数不新增历史以外的
  任何位图。

**4. 矢量形状层**（S5，P0）
- 做法：形状提交为带 `shapeSpec` 的图层（几何、圆角、填充、描边、虚线），随时点回
  再改；降级规则同文字层（位图被落像素工具改写 → 清规格，诚实降级）；形状种类补
  多边形/星形（旧编辑器有）。命中测试复用文字层的 `inkBox` 思路。
- 验收：画矩形 → 改圆角 0→30 → 位图变化且规格仍在；在画笔画到该层 → 规格清空；
  工程往返（件 11）后规格保留。

**5. 自由变换**（S6，P0）
- 做法：⌘T 进入——8 个手柄 + 旋转柄 + 中心点；拖角缩放（⇧ 等比）、拖边缩放、
  ⌘ 拖斜切、⌥ 以中心为基准、框内拖动位移；吸附复用既有中心/三分参考线；选项栏
  数值（缩放 % / 旋转 ° / 斜切）；⏎ 应用、Esc 取消；方向键 1px（⇧ 10px）。图层已有
  非破坏 offset/scale/rotation/skew 字段，本件只做交互层与斜切合成核对。
- 验收：合成事件拖右下角 → `scale` 在预期 ±2% 内且 `offset` 不变；Esc 回原值；
  文字/形状层变换后规格仍在；⌘T 在非 key 窗口下也能进入（`acceptsFirstMouse` 已修）。

**6. 画笔引擎**（S10，P1）
- 做法：**压感**（`NSEvent.pressure`：Force Touch 触控板/数位板驱动 → 大小与流量
  曲线，可关、曲线可调）、**笔刷预设**（间距/流量/角度/圆度/硬度，内置 8 支 + 收藏，
  持久化）、**笔画平滑**（稳定器 0–100，纯逻辑进 harness）、**涂抹工具**；光标随压感
  实时变径。
- 验收：注入压力 0.2 与 1.0 两笔，落盘宽度比 ≈ 压力比（±15%）；平滑后锯齿轨迹落点
  方差下降（harness）；涂抹沿笔画方向带出色（采样断言）；真机手感留用户实测。

**7. 混合模式补齐 + 填充不透明度**（S14，P1）
- 做法：17 → 25（CI 合成滤镜 + 自写颜色核补深色/浅色）；图层面板加"填充"滑杆，
  与不透明度分离。
- 验收：两层 50% 灰各模式输出像素 = 公式值 ±1；harness 断言分组与顺序稳定。

**8. 智能选区**（S13，P0）
- 做法：**选择主体**（Vision 前景蒙版 → 选区）、**色彩范围**（吸管取样 + 容差，
  `CIColorCube` 阈值）、**亮度范围**（阴影/中间调/高光）——全部走 `select` 命令，
  结果可继续羽化/加减/反选/存为图层蒙版；Agent 可用。
- 验收：纯色主体 + 异色背景的合成图 → 选择主体 → 选区 IoU ≥ 0.9；色彩范围选红 →
  bbox = 红块；全部合成 fixture，无网络。

**9. 人像工具**（P1）
- 做法：红眼（`CIRedEyeCorrection`）、人脸平衡（`CIFaceBalance`）、磨皮（人脸关键点
  → 皮肤区蒙版 + 保边平滑，强度可调）、亮白牙齿（口内区去黄提亮）——一律落成
  "调整图层 + 自动蒙版"，可反悔可微调。
- 验收：公共授权人像样张入库（`tests/fixtures`，无隐私）；检出人脸 ≥ 1；磨皮后
  皮肤区高频能量下降 ≥ 30% 而眼唇区不变（像素断言）。

**10. 画质增强**（P1）
- 做法：**超分辨率 2×**（`CIEdgePreserveUpsampleFilter`）、**文档增强**
  （`CIDocumentEnhancer`：去阴影/拉对比，扫描件与白板照片）、**输出锐化**（导出时按
  目标尺寸 USM）——命令 + Canvas 菜单 + Agent。
- 验收：细线小字 fixture 2× 后边缘梯度能量高于 Lanczos 且过冲 ≤ 阈值；带阴影的
  文档图增强后背景亮度方差下降 ≥ 50%。

**11. 工程文件与工作区**（S7、S8，P0/P1）
- 做法：`.desimage` **目录包**（`manifest.json` + `layers/*.png` + 蒙版）保存/打开/
  另存；含图层或参数时 ⌘S 提示"存储为工程"；草稿升级为工程快照（崩溃恢复保图层）；
  **工作区**（P1）：检查器多开（图层/调整/直方图/历史同屏）、可拖宽、三套预设
  （修图/设计/简洁）；底部胶片条（同文件夹上一张/下一张）。
- 验收：3 图层 + 调整图层 + 蒙版 + 文字 → 存工程 → 关闭 → 重开：图层数/类型/参数/
  蒙版像素/文字规格逐项相等，合成像素与保存前一致；损坏包报错不崩；格式版本字段
  拒绝未来版本。

### ② Agent 基础（3 件）

**12. editImage 契约同步 + 能力自发现**（P0）
- 做法：全部新能力进命令表（hsl/levels、adjustmentlayer、transform、select 的
  subject/color/luminance、portrait、upscale、enhance、project save/open、actions）；
  `/image/state` 暴露 `capabilities` 列表，描述里只保留索引与一句语义（描述预算纪律
  沿用 v0.8.74）。
- 验收：假端点抓请求——`tools` 里 editImage 描述含全部新动作名；`/image/state.capabilities`
  与命令表 `allCases` 一一对应（harness 级对账，防止手写漂移）。

**13. 修图评估 E45–E48**（P0）
- 固定假端点 + 合成图，桥级断言：① 选区→调整图层闭环（look → 选择主体 →
  调整图层 → compare）；② 色彩不降级（保存后读 bpc/ICC）；③ 动作序列回放；
  ④ 自然语言选区（"选中衣服"→ 色彩范围 ∩ 主体）。

**14. 修图技能模板**（P1）
- 做法：人像精修 / 商品图白底 / 文档扫描增强 / 社媒封面——说明 + 推荐命令序列，
  走既有技能加载机制（使用追踪、重复指令自动加载）。
- 验收：E2E 里带技能时 Agent 走到预期命令序列（不要求模型质量，只验接线）。

### ③ 融合（2 件）

**15. 自然语言选区与局部调整**（P0）
- 做法：编辑器 AI 弹窗或 Agent 面板里说"把天空调蓝一点""只磨皮人脸" → Agent 组合
  `select` + 调整图层 + 蒙版；选区结果回显画布（蚂蚁线闪现 + 会话备注）。
- 验收：E48 即本件；画布回显经 `/image/state.selection` 断言。

**16. lookImage 新增 mask 模式**（P1）
- 做法：把选区/图层蒙版渲染成 vision 输入，让模型"看见自己选得准不准"再修；
  compare 自检沿用。
- 验收：假端点断言 vision part 存在且为蒙版灰度图（尺寸 = 画布）。

### ④ 替人干活（2 件）

**17. 动作录制与回放**（S11，P0）
- 做法：历史栈每步带 `replay`（动作名 + 参数），从 48 个入栈入口里给可回放的步骤
  补参数（笔画给点列；液化这类慢的标注"仅记录不回放"）；"导出动作"得 JSON 序列；
  **对文件夹回放**（复用 ImageBatchEdit 与 Job 队列、进度/通知）；定时任务可挂。
- 验收：录 4 步（裁剪/曝光/HSL/导出 WebP）→ 对 5 张 fixture 回放 → 每张输出与手工
  单张执行**逐像素相等**。

**18. 批量管线升级**（P1）
- 做法：`batchEditImages` 接受动作序列，与既有"逐张看图定参"并存；批量前后出
  对比图（contact sheet）进产物中心。
- 验收：Job 产物含对比图且尺寸 = 行列数 × 单元格。

## Track B — 收口与贯穿（2 件）

**19. ImagePro 回归套件入库**（S12，贯穿·可靠性，**批 1 第一件**）
- 做法：`tests/imagepro-e2e.py`——封闭实例、合成事件链（`/editor/synthetic` +
  `catcherRect`）+ 命令 API + **保存后读落盘像素**；`--section tools`（重建丢失的
  23 项工具矩阵）`color` `layers` `transform` `brush` `select` `project` `agent`
  （含多编辑器路由 15 项、文本 14 项、还原 13 项）；`tests/run-imagepro.sh` 全量入口，
  190 的 browser 节加 8 项冒烟。**每批动手前先把该节的用例写绿**。
- 验收：套件自身——对当前代码跑 `tools` 节全绿（基线），后续每批新增节全绿。

**20. 撤销内存模型 + 大图手感**（S9，贯穿·可靠性，P1）
- 做法：撤销快照改**脏矩形补丁**（笔画/橡皮/修饰/蒙版/形状只存触及块的旧像素；
  参数类步骤本来就不带位图）→ `maxHistory` 不再随画布面积腰斩；显示合成按脏矩形
  增量（只重采样触及区域）；笔画渲染移出主线程。
- 验收：96MP 连续 40 笔 RSS 峰值 < 2GB 且 40 步全可撤销（现 2 步）；像素结果与
  全量快照逐像素相等（同一脚本两条路径对跑）；Release 基线
  `perf-baseline.json: imagepro.strokeMs96MP ≤ 80`。

## 批次

1. **护栏与地基**：19 回归套件（先立，重建工具矩阵）→ 1 色彩管线与位深 →
   2 调整项补齐 → 7 混合模式补齐 + 填充不透明度。
2. **非破坏深度**：3 调整图层 + 选区转蒙版 → 4 矢量形状层 → 11a 工程文件。
3. **专业手感**：5 自由变换 → 6 画笔引擎 → 20 撤销内存模型 + 脏矩形显示。
4. **智能与工作区**：8 智能选区 → 9 人像 → 10 画质增强 → 11b 工作区。
5. **Agent·批处理·收口**：12 契约同步 → 15 自然语言选区 → 16 lookImage mask 模式 →
   17 动作录制回放 → 18 批量升级 → 13 评估 E45–E48 → 14 技能模板 →
   可发现性（快捷键/What's New/i18n）→ 可选 spike → 闸门（harness + 全量 190 +
   imagepro-e2e 全量 + Release clean 零警告 + perf-probe --strict）。

**只做一半的建议**：批 1–3 是"专业内核"（护栏、色彩、调整项、调整图层、矢量、
工程文件、自由变换、画笔、撤销），单独可发；批 4–5（智能、Agent、批处理）可整体
滑到下一版而不留半成品。

## Spike（实测通过才进，放批 5）

- **PSD 导入**：ImageIO 类型表里有 PSD，但需真实样本验证解出的是合成图还是空图；
  通过则加入可打开类型（压平打开，不承诺图层）。
- **RAW 导入**：`CIRAWFilter` 可用，但默认解码的观感（对比/饱和）未评估；只有当
  "默认解码 + 件 1 的色彩管线 + 自动色阶"能达到可接受观感才进本版，且**不做 RAW
  开发面板**。

## 不做（已核实，别再当缺口）

- PSD / OpenRaster **写入**互通；Camera RAW 开发面板（白平衡/配置文件/镜头校正）。
- 钢笔与贝塞尔路径系统、智能对象、3D/视频图层/动画帧、切片工具。
- **生成式填充 / 扩图**：需要扩散模型——端上 1–2GB 且转换环境难配平，云端取决于
  档案是否提供图像编辑模型。**这条需要你拍板**（见下），默认不做。
- PatchMatch 级纹理合成、内容感知缩放/移动（维持 v0.8.55 决定）。
- CMYK / 专色印刷；浮点（16 位以上）工作；iPad 编辑器。
- App 菜单集成（维持 v0.8.47 暂缓：要动 `BrowserCommand` 与 `CommandDispatcher`，
  且与编辑器窗口级键监听有双重触发风险）。

## 需要你拍板的三件事

1. **生成式填充/扩图做不做**：做的话走端上模型还是你现有的 AI 档案网关。
2. **PSD/RAW 导入**：本版只跑 spike，还是直接不做。
3. **版本规模**：全做（20 件，约等于前两版之和）还是先发批 1–3"专业内核"。

## 风险

- **16 位让内存翻倍**：件 1 与件 20 必须同一版落地，否则超大图在批 1–2 之间会更紧；
  批 1 先把"像素格式入口唯一"钉死（harness 断言 ImagePro 源码里不再出现
  `CGColorSpaceCreateDeviceRGB()` 硬编码）。
- **调整图层改变合成顺序**：效果缓存键要带"下方层聚合身份"，失效面变大——靠件 20
  的脏矩形显示兜底；批 2 的性能读数必须对比批 1 基线。
- **压感事件造不出来**：E2E 走注入曲线（调试钩子），真机手感只能用户实测。
- **人脸/主体模型需要真样张**：合成图骗不过检测器，fixture 用公共授权样张入库。
- **动作回放遇自由手绘/液化**：手绘给点列可回放；液化标注"仅记录"，不假装能回放。
- **ImagePro 是 11k 行单模块，五批都动它**：批 1 先立套件，每批收尾跑全量
  imagepro-e2e；动像素管线的批次当天跑全量 190（v0.8.84 的下载闸教训）。
- **What's New / i18n**：新文案手工补 `zh-Hans`/`zh-Hant`（v0.8.84 语言码事故已加
  白名单闸门，`tests/run.sh` 当场拦）。
