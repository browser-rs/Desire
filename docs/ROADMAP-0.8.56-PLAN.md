# v0.8.56 规划稿（2026-11-13）—— 跑得快·点得准：性能预算闭环 + 视觉操作收口

> 定位：四版功能轰炸（窗口/书签/ImagePro/AI 修图）之后的**工程复利版**——把"快"
> 和"准"变成可测量、可持续的资产。起因有二：① 规划盘点时发现**视觉点击链有个
> 真可靠性缺陷**——`captureScreenshot` 在视口 >1024 CSS px 时按比例缩小，模型
> 读截图报出的坐标系统性漂移（14 寸全屏 1512px 宽时漂 ~1.4x），整个
> screenshot→clickAt 视觉兜底回路在宽窗口下不可信；② "快"没有预算线——
> StartupMetric 分段打点已在、`≤700ms` 口径在案，但 CI 没有断言、慢了没人知道。

## 一、现状核实（2026-11-13，动手前逐项查过；证伪即排除）

**已存在/已建成（不重复造）**：
- **端上模型**：FoundationModelsProvider（FM 文本协议工具调用走共享审批回路）+
  OllamaProvider + RoutingProvider（简单回合优先端上）+ 桥 `/ai/routing`——完整。
- **数据搬运值守**：PageWatch（文本 diff/数值盯梢/AI 分析 opt-in）+ Dataset 采集
  （列表→表格、四种翻页）+ 定时任务/工作流/后台命令/研究简报/死链值守。
- **端上翻译**：Reader 整页翻译已走 Translation.framework（v0.8.43，段落双语对照
  +缓存）——Backlog"翻译引擎可插拔"实质已交付。
- **clickAt 后验**：clickAt 已在 `PostActionVerifier.tools`（指纹比对）。
- **密码多账号**：v0.8.8 chip 展开选账号已落地。
- **下载限速**：WebKit WKDownload 无节流 API——**勿做假 UI**（DownloadStore 注释
  在案），排除。

**真缺口（本版目标）**：
1. **screenshot 坐标漂移**：`captureScreenshot` 的 maxDim=1024 等比缩放在宽视口
   （>1024 CSS px，全屏 1512px 常见）下让"图片像素 ≠ CSS 像素"，模型无从知道
   缩放系数——clickAt 点不准，视觉兜底回路退化。
2. **clickAt 无准星**：DOM 动作有 `highlight`（橙框闪现，用户看得见），坐标点击
   却是"盲点"——用户不知道 Agent 要点哪，Agent 自己也没有落点反馈。
3. **视觉循环无评估**：E1-E19 没有任何用例覆盖 look→clickAt 链；canvas/虚拟列表
   这类"DOM 抓不到、只有视觉能点"的场景没有 fixture。
4. **性能预算无断言**：StartupMetric 打点在 app 内，ci.yml 只有 /state 探活——
   首窗交互 ≤700ms 的口径没有机器看守；LaunchAudit 有面包屑无汇总。
5. **挂起验证两件**：E19 live 跑 + 10/10 强杀首启（v0.8.55 遗留，dev 实例被占用）。
6. **套件时序不稳 5 项**（v0.7.20 记录的旧账）。

## 二、四主题

### ① 浏览器基础（旗舰）＝ 性能预算闭环

1. **`GET /diag/launch`**：启动分段耗时（StartupMetric 各段 + LaunchAudit 面包屑
   时间线）+ 慢段 top3 + 与上次启动对比；设置诊断页加"启动性能"卡（用户可自查）。
2. **预算进 CI**：ci.yml 的 launch+探活步骤扩成预算断言——`首窗交互 ≤700ms`
   警戒线（云端 runner 性能有抖动，超线**标黄不阻塞**，连续两版超线才升级为
   阻塞——先建观测再立铁律）；数字写进 run summary 可比趋势。
3. **流式零卡顿复验**：MarkdownRendererView 120 块退化线既有——复验并留成
   release-smoke 探针（BIGSTREAM 模式假端点 + /state 往返延迟当主线程探针）。
4. **挂起策略护栏复验**：双阈值挂起（内存压力+时长）对音频/固定/Agent 操作的
   豁免矩阵逐项过一遍（已确定性化的断言不再动）。

### ② Agent 基础 ＝ 视觉操作收口（点得准）

1. **screenshot 坐标自描述**：截图缩放后在图内烧一条底部 caption
   （`viewport 1512×850 · image 1024×576 · scale 0.677`；≤1024 时标 `1:1`）——
   模型读图即知换算，宽窗口也能点准。协议零改动（仍是裸 dataURI）。
2. **clickAt 准星**：派发真实鼠标事件前，在落点闪一圈准星环（~0.6s，强调色描边
   +十字线）——用户看得见 Agent 要点哪（与 DOM highlight 同一可见性哲学），
   诊断截图也能拍到。
3. **工具面决策规则**：getPageSnapshot（DOM 优先）↔ screenshot+clickAt（视觉兜底）
   的切换时机写成反盲修句式（canvas/shadow DOM/虚拟列表三类典型场景点名）；
   clickAt 描述补"读 caption 换算坐标"指引。
4. **评估 E20（canvas fixture）**：本地 fixture 页用 `<canvas>` 画一个按钮
   （DOM 无对应元素）→ 假端点逼 look→clickAt→verify 三拍 → 断言命中坐标换算
   正确 + 后验通过。EVAL_E20=1 本地门控（同 E19 惯例）。

### ③ 融合 ＝ 准星可视化（用户看见 Agent 的手）

- 准星环即融合件：Agent 的视觉操作从"黑盒点击"变成"看得见的落点"——配合既有
  highlight/审批卡，构成第三层可观测（DOM 高亮 / 坐标准星 / 审批现场）。
- 诊断手法补进 AGENTS.md：`/panel/snapshot` 与 screencapture 拍准星环的姿势。

### ④ 替人干活 ＝ 挂起验证收口（欠账清零）

- **E19 live 跑**（修图闭环端到端）+ **10/10 强杀首启**（无窗自愈）——v0.8.55
  挂起项，dev 实例可用即跑。
- **套件时序 5 项确定性化**（v0.7.20 旧账）：逐项过 page-watch/预算段断言，
  能转确定性的转（fixture 时间窗/轮询口径），不能的显式 SKIP 并记录原因。

### 贯穿

- i18n 三语（caption 是图内绘制不用翻译；准星/诊断卡/评估措辞要补键）+ WhatsNew。
- 换算系数计算进 harness（纯逻辑：viewport/图片尺寸 → scale + 坐标换算公式）。
- AGENTS.md 记档：视觉点击链的坐标纪律（caption 机制 + 拍准星手法）。

## 三、不做（本版明确）

- 下载限速（WebKit 无 API，勿做假 UI）；翻译引擎可插拔（端上已交付）。
- 端上模型深化（FM/Ollama 已建成； guided generation 无需求场景）。
- 数据搬运/监视新形态（PageWatch/Dataset 已覆盖；不做"采集市场"）。
- ImagePro 大图性能（96MP 两轮已做过；本版只复验不重做）。
- 密码字段容错（非常规字段名）——**批 4 开始前重新核实**，仍在才做，已修则记账。
- 启动预算"阻塞化"（先观测两版再议；本版只标黄不红）。

## 四、批次

- **批 1（点得准）**：screenshot caption + clickAt 准星 + 换算纯逻辑进 harness
  + 工具面决策规则。
- **批 2（评估与欠账）**：E20 canvas fixture + E19 live + 10/10 强杀 + 套件时序
  确定性化。
- **批 3（跑得快）**：/diag/launch + 设置诊断卡 + CI 预算断言 + 流式/挂起复验。
- **批 4（收口）**：密码字段容错（批前核实）+ i18n/WhatsNew + Release 闸门。

## 五、验收

1. **宽窗口点得准**：1512px 全屏视口，canvas fixture 按钮 → look（caption 在图）
   → clickAt → 命中（E20 断言换算后坐标与按钮实际位置一致）。
2. **准星可见**：clickAt 前 0.6s 内 screencapture 能拍到落点准星环。
3. **预算有看守**：CI run summary 出现启动分段数字；人为注入慢启动时超线标黄。
4. **/diag/launch**：分段耗时 + 慢段 top3 + 设置诊断卡可见。
5. **欠账清零**：E19 live 过、10/10 强杀出主窗（tabs≥1）、套件时序项 3 连跑全绿
   或显式 SKIP 带原因。
6. **闸门**：harness 全绿、Release clean 零警告、双架构 CI 绿。

## 六、版本口径

- 版本号 v0.8.56（构建号 596）；发版流程照旧：tests/run.sh + release-smoke +
  Release clean 零警告 + `scripts/release.sh 0.8.56`，云端全绿自动建 tag。
