# v0.8.65 规划稿（2026-11-20）—— 账实相符：同步健康旗舰 + 反馈修复版

> **主题叙事**：0.8.59-64 六版把存量缺口清得很干净——本版规划前核实再次
> **五连"清单≠核实"**（全部已存在，勿再立项）：① Rust sync 三项（pull `>= ts`
> 复合游标 / push IN 批量 / rate_limiter 挂载）**早已落地**（sync_service.rs/
> sync_controller.rs——"随下次服务端发版"的旧记忆过时）；② C7 admin CLI 的
> device list/revoke 已有（0.8.44），仅 remote stats/cleanup 缺；③ **技能导入/
> 导出已存在**（SkillStore.importArchive/exportPackage + 面板按钮）；④ **记忆
> 导出/导入已存在**（v0.7.28 备份导入 + 0.8.20 MemoryImport + exportJSON/
> importFacts）；⑤ JobStore 保留策略已有（trim maxJobs 只淘汰最旧终态）。
> 因此本版定位：**快拨成对重复事故（0.8.64 发版日实测，修复 b10fc03d 已推）
> 的体系化收口**为旗舰（同步健康面），加上三个已核实的真空白小件，其余全部
> 让位给 **0.8.63-64 新面的真实使用反馈修复**。
>
> **规划前核实（2026-11-20）**：SyncHealth 仅 3 态 derive（signedIn/syncing/
> hasError），设置页有 per-domain 开关行但**无条目数/墓碑数/游标/重复检测**；
> /artifacts/read 只支持文本与图片（PDF 回"binary not supported"）；DesireRemote
> 无 PDFKit 使用；admin CLI 无 remote stats/cleanup（inbox [--purge] 已有）。

## 四主题

### ① 浏览器/同步基础 = 旗舰「同步健康面」
- **设置 ▸ Sync 新增"健康"卡**：每个同步域一行——本地条目数、本地墓碑数、
  游标位置（服务端原文）、最后同步时间；**同址重复检测**（quickdials 应为
  0——b10fc03d 自动收敛；书签域显示同 URL 不同 id 组数但**不自动去重**，
  标注"书签语义允许多处收藏"豁免）；数据派生抽纯函数
  `SyncDomainHealth`（Foundation-only 进 run.sh）。
- 桥 `GET /sync/health` 扩面（诊断与自动化入口，数据与设置卡同一份）。
- 浏览器侧真实使用反馈修复（预留，不预规划）。

### ② Agent 基础 = 使用期反馈修复
- 0.8.63-64 新面进入真实使用期：术语表、双语成书、产物登记、校准卡、
  E28 夹具——**反馈修复预留**（不预规划具体项）。
- 已核实存在的分享/导入能力（技能包、记忆备份）不再立项；如使用中暴露
  缺口按反馈处理。

### ③ 融合 = iOS 产物 PDF 预览 v2 + 真机联调反馈
- `/artifacts/read` 支持 PDF：≤10MB 整本 dataURI 回传（iOS PDFKit 渲染——
  DesireRemote 首次引入 PDFKit），>10MB 回 meta only + "在 Mac 上打开"；
  安全面沿用产物索引白名单 + 大小闸。
- 真机联调反馈修复（0.8.63 产物卡 + 0.8.64 预览/再加工/书详情帧——用户
  配对后验收，预留）。

### ④ 替人干活 = admin CLI 补全（服务端小件）
- `desire-admin remote stats <username>`（信箱/设备/推送计数）与
  `remote cleanup <username> [--days N]`（过期远端会话/条目清理，默认
  dry-run）——随下次服务端发版生效（部署手工步）。
- Jobs 保留策略核查记录：trim maxJobs 只淘汰最旧终态、活动作业绝不丢
  ——已健全，记录即收口。

### 工程（贯穿）
- 产品页 0.8.63-65 三轮内容扩充（手工活）+ 部署提醒。
- i18n 三语 / run.sh / smoke / Release 零警告 / WhatsNew 例行。
- 快拨修复（b10fc03d）已在本版 [Unreleased]——随本版发布生效。

## 批次（建议实况更新）

批 1 同步健康卡 + /sync/health（旗舰）→ 批 2 iOS PDF 预览 v2 →
批 3 admin remote stats/cleanup → 批 4 反馈修复预留 + 收口
（i18n/WhatsNew/产品页素材）→ **真机联调（用户）**。

**批 1-3 完成（2026-11-20，a2eee4cc/b155d137/82607e04）**：① 同步完整性卡
+ /sync/health（SyncDomainHealth 7 单测 3369→3376；live：快拨修复首启收敛
17→9 条、8 墓碑入队推送，书签真实检出 1 份同址——检测不自动动的语义正确）；
② PDF 预览双端绿（白名单拒绝实测，渲染待真机）；③ admin remote stats/
cleanup（默认 30 天 dry-run，cargo fmt/test 绿）。**批 4 = 反馈修复预留**
（等 0.8.63-65 新面真实使用反馈）+ 收口（WhatsNew/i18n 已刷）。
**发版时机等用户反馈攒够（用户定）**；产品页扩充是发版手工活。

## 不做

execution-e2e --section（0.8.64 否决维持——依赖图梳理成本高于收益）；passkey
（等 Apple entitlement）；隐私/拦截统计（数据源否决）；网络节流/pixelRatio
（WebKit 无 API）；第三方翻译引擎；书签同址去重（多处收藏是语义不是垃圾）；
新 Agent 大件（0.8.59-64 六版后继续休整等反馈）；服务端大改（C7/Rust 已核
实无遗留——不再为凑主题立项）。

## 风险

- PDF dataURI 回传体积（10MB → base64 ~13.3MB）走 REST 拉取不走 WS 推
  （32KB 帧预算教训）——iOS 端要下载进度与失败兜底。
- 同步健康卡的域统计要区分"本地派生"与"远端事实"（远端只有 stats 接口的
  行数——口径不一致时标注来源，避免"账实不符"变成新的误导）。
- 反馈修复预留批依赖用户真实使用——0.8.65 发版时机可等反馈攒够（用户定）。
