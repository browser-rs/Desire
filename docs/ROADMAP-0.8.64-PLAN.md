# v0.8.64 规划稿（2026-11-19）—— 读以致用：翻译精读旗舰 + 产物上手 + 存量收编

> **主题叙事**：0.8.59-63 六连 Agent 深化（上下文/校准/健康/翻译/产物）后，
> 浏览器基础轮空四版（都是"反馈修复预留"）——本版旗舰回到**读**：翻译读得准
> （术语表）、读获得（双语成书落书架）。同版把 0.8.63 产物卡从"元信息"推进到
> "内容可读"（手机端预览 + 发回再加工预设），并收编 0.8.38 遗留四件（A3/A7/
> B1 剩余/C7）与 0.8.61 遗留一件（--section）。
>
> **规划前核实（2026-11-19）**：① 术语表 `BilingualReadingService.translateBatch`
> 的 glossary 参数**全仓零调用方、零 UI**（真空白，管线已就绪只差接线）；
> ② `/artifacts` 无文件内容读取端点、iOS ArtifactsView 只有元信息（0.8.63 明确
> 不做的 QuickLook 预览 = 本版候选）；③ Agent `writeFile` 直写文件**不走 Job
> → 不进产物中心/Remote 产物卡**（ArtifactIndex 只看 JobStore.artifactURL）；
> ④ 设置诊断区只有 stall/pool 两枚 pill，**模型校准段无 UI**（0.8.63 规划写了
> "设置诊断页"，实况只上了 /diag/health 端点——遗留）；⑤ `tests/agent-eval.py`
> 无 runToolboxTool/analyzeMedia/readBook/searchLibrary/syncStatus/
> saveWebPageToLibrary/addBookNote 用例（0.8.38 A3 六条夹具未做）；⑥ 定时任务
> 错过补偿**已存在**（AgentScheduler 头注释：overdue fire once on launch——
> 勿再列为候选）；⑦ 旁路用量记账**已全覆盖**（title/facts/summary/bilingual/
> readingList/skillDistill/heartbeat/tabDigest 都走 attributeBypassUsage——勿
> 再列为候选）；⑧ execution-e2e 无 --section（0.8.61 未做项）。

## 四主题

### ① 浏览器基础 = 旗舰「翻译精读」
- **术语表（glossary）**：设置页编辑器，全局 + 按站点两级（"原文 → 固定译法"
  行编辑，站点级覆盖全局）；翻译时并入 system 的 Glossary 段（translateBatch
  参数已就绪）。验收：假端点断言术语行真进了翻译请求的 system；译文遵守术语。
- **双语成书**：双语对照完成后"存为双语 EPUB"进书架——`__desireBilingualExport`
  已收集 (原文, 译文) 对，组章节后走 0.8.36 的 EPUB 导出管线（复用，不新写
  打包器）；对照版式 = 段落级"原文 + 译文"。降级路径：EPUB 失败落 HTML 离线书
  （0.8.35 网页成书管线）。
- **「测试连接」修复**（0.8.37 遗留之谜收口）：probe 现发 stream:false 等完整
  生成（AMD 网关非流式慢→假超时）且漏 activeHeaders——改流式首包即判 +
  补档案额外请求头；回归 = 假端点断言请求头与首包计时。
- **历史同步卫生收口**：服务端 tombstone GC（0.7.21）上线后的客户端配合——
  本地历史域 90 天 TTL 落实与墓碑/游标清理（规划批内核字段后细化）。
- **翻译 2.0 / 缓存 / 校准 / 值守真实使用反馈修复**（预留，不预规划具体项；
  0.8.62 上线至今无修复轮）。

### ② Agent 基础
- **Agent 文件产出统一入产物中心**：`writeFile`/`runCommand` 产物等直写文件的
  工具不建 Job → 产物卡与 Remote 产物卡看不到。登记面收口：轻量登记入口
  （JobRecord 短记录或 ArtifactIndex 扩源，批内定案），写文件工具接线；
  产物中心/Remote/iOS 产物卡自动受益。
- **诊断页"模型校准"卡**（0.8.63 遗留 UI）：每模型窗口 tokens / 样本数（<3 标
  gray）/ EMA 字符-token 比率 / 当前生效字符预算 + 清除入口（数据源 = 0.8.63
  已有的 /diag/health calibrations，只补 UI）。
- **A3 评估集六条夹具**（0.8.38 遗留）：runToolboxTool / analyzeMedia /
  readBook·searchLibrary / syncStatus / saveWebPageToLibrary / addBookNote
  （假端点轨迹断言；与 E22-E27 并存）。

### ③ 融合 = 产物上手（0.8.63 旗舰续作）
- **iOS 产物预览 v1**：桥 `POST /artifacts/read`——**安全边界铁律**：路径必须
  ∈ ArtifactIndex 派生清单（防路径穿越/任意读），大小闸 v1 = 文本 ≤256KB、
  图片 ≤5MB 直接回传，其余（PDF/视频/大文件）只回元信息+"在 Mac 上打开"。
  iOS 端：ArtifactsView 点开预览（文本渲染 / NetworkImage），复用 authedSend。
- **发回再加工预设动作**：产物详情页 chips（总结此文件 / 转 Markdown /
  规整重命名）——prompt 模板一键发桌面 Agent，替代手写长指令。
- **B1 剩余：Remote 书架高亮列表 + askAboutBook**（0.8.38 遗留）：书详情页补
  最近高亮/笔记列表（Mac 帧 books 扩展）+ "问这本书"预填 Agent。
- **真机联调反馈修复**（0.8.63 用户参与环节，预留）。

### ④ 替人干活
- **A7 Office 文件夹批量队列**（0.8.38 遗留）：选文件夹 → 预览将转换的文件与
  目标格式 → 队列执行（docx/pdf/xlsx/pptx/图片/文本），每项状态/失败原因/重试/
  打开产物，并发上限；结果目录默认同级 `Converted/`，重名加序号不覆盖；
  走 Jobs（自动进值守/产物/简报账本）。验收：混合格式 fixture 全转换、失败可
  重试、原文件未动、取消保留已完成项。
- **C7 admin CLI 扩展**（0.8.38 遗留）：device list/revoke、remote stats/cleanup、
  quota set/reset 子命令（默认 dry-run，危险操作二次确认，JSON 输出可脚本化）；
  与 **Rust sync 三项**（pull `>= ts`→严格增量、push IN 批量、rate_limit 清扫
  ——两轮体检遗留）同批，**随服务端发版（部署手工步）**。

### 工程（贯穿）
- **execution-e2e --section 分节化**（0.8.61 未做项）：190 项按节跑（浏览/Agent
  回合/会话恢复/Jobs/Remote…），`--section name` 只跑相关节——回归从 15 分钟
  全量变成按改动面选段；全量保留为里程碑/发版选项。
- 产品页 v0.8.63/64 内容扩充轮（feature 级发版手工活）+ **部署提醒**（0.8.63
  页面版本号已 sed、页面尚未部署）。
- i18n 三语补全 / run.sh / smoke / Release 零警告 / WhatsNew 例行闸门。

## 批次（实况更新）

**批 1 完成（2026-11-19）**：两处规划前核实在实施中修正——① 术语表并非
"零调用方真空白"：v0.8.8 已有记忆通道（category=translation 记忆事实按
scope 注入 Glossary 段，grep 误判是因为全部引用都在 BilingualReadingService
内部）；本批落成的是**专用结构化编辑器**（设置新增"翻译"区）+ 双源合并注入
（TranslationGlossary 15 单测 3333→3348，live 验证全局/站点术语进请求）；
② 「测试连接」在早前版本已修好（probeChat 流式+档案自定义头+首行即判），
记忆条目过时——慢网关探针实证：30s 慢生成 fixture 上 Connected ✓ 0.0s、
extraHeaders 到达。规划稿由此更正。

批 1 术语表（原计划含「测试连接」修复——核实后该项为零工作量，仅实证）

**批 2 完成（2026-11-20，批 2 前半）**：双语成书落地——TranslateBar 双语态
新增"存入书架"按钮，BilingualBookBuilder（转义/成对/顺序，11 单测 3348→3359）
组装对照 HTML 走既有 importArticle 管线落书架（EPUB = 书架内既有导出，不重写
打包器——规划稿"降级路径"升为主路径的既定简化）；桥 POST /bilingual/save-book
供自动化。live 验证：8 对翻译 → save-book → 书架 1 本 HTML 书。
**新教训进 AGENTS（假端点条目 ⑤）**：旁路类验证触发前必须先切假档案——
本次忘了切，8 段翻译直打用户真实网关烧配额（已停）。历史同步卫生在批内
核实后实施。→ 批 2 双语成书 + 历史同步卫生 →
批 3 Agent 产物登记 + 诊断校准卡 → 批 4 iOS 产物预览 + 再加工 chips + B1 剩余 →
批 5 A7 Office 批量 + C7/Rust 服务端批 → 批 6 --section + A3 夹具 + 收口
（i18n/WhatsNew/产品页素材）→ **真机联调（用户）**。

## 不做

网络节流 / pixelRatio 模拟（WebKit 无 API，勿做假 UI——维持既有否决）；passkey
（等 Apple entitlement，外部依赖）；隐私/拦截统计报告（0.8.63 数据源否决维持）；
新 Agent 能力大件（0.8.60-63 连续五版后休整等反馈）；第三方翻译引擎 / 整本一次性
翻译（0.8.36 否决维持）；iOS QuickLook 全格式预览（v1 只文本+图片，其余在 Mac
打开）；手机端渲染 EPUB（0.8.38 B1 既有边界）。

## 风险

- `/artifacts/read` 安全边界：路径白名单必须严格取自产物索引派生值（绝不接受
  客户端任意路径）；大小闸防中继帧超预算（32KB 帧教训——走 REST 拉取不走 WS 推）。
- 双语 EPUB 依赖网页成书/EPUB 管线对长页与图片本地化的稳定性——先小页验证。
- Rust 服务端改动需部署才生效（明确标注手工步；未部署时客户端行为不变）。
- A7 队列的状态机（重试/取消/并发）复用 Jobs 但 Office 转换是同步 textutil
  调用——并发与超时要单测（纯逻辑进 run.sh）。
- A3 夹具假端点分支按线格式写（E20/E27 教训；新用例先核对函数名唯一）。
