# v0.8.59 规划稿（2026-11-15）—— 上下文自治：Agent 上下文全链路治理 + 批量下载智能化

> **状态：内容已全部落地**（6 个提交，27d6e48c…4020ceb2，均随本版发布，不单独
> 发热点版）。本稿是发布规划：主题叙事、验收门、发布前清单、遗留项。

## 主题定位

- **Agent 基础（旗舰）= 上下文自治**：会话上下文从"只增不减、超限靠人"变成
  自治理闭环——请求侧压缩（既有）+ **持久化压缩**（超预算自动归档+摘要，
  /compact 同款手动触发）+ **大结果转存**（小说级 HTML 不再挤爆上下文，全文
  可检索）+ **芯片口径修正**（显示"实际发送"而非落盘全文，压缩态不再假红）
  + **流式停摆看门狗**（回合不再永久挂死）。
- **浏览器基础 / 替人干活 = 批量下载智能化与可靠性**：落点智能归并（三种
  路径形态各有明确落位，不再"模型自作主张"）、CF 人工验证窗自愈、一页多视频
  全下、单批 100→500、并发 1-16、面板全量展示、后台任务条移头部。
- **贯穿（可靠性）**：压缩计数器回归修复（记忆学习停摆）、 Physician 体检项、
  45 项新纯逻辑单测（3223→3272）。**贯穿（可发现性）**：/compact、芯片提示、
  空响应文案、Doctor 全部去 /new 化——用户不需要知道"该开新会话"。
- **随版附带的 Rust 后端**：jsonwebtoken 12 适配（crates/api 构建修复，随
  服务端下次部署）。

## 已落地清单（按提交）

| 提交 | 内容 |
|---|---|
| 27d6e48c | BatchLocationResolver 落点智能归并（21 单测）；工具描述短契约；manageBatchDownloads 补 cancel；后台任务条移头部 chip（AgentJobsChip） |
| df36cb20 | jsonwebtoken 12 适配（from_secret 返回 Result） |
| 83685905 | CF 验证窗修复（解析器脚本收窄 + CF 帧跳嗅探 + 卡死挑战自动重载）；单批 500；一页多视频兄弟项（stem+目录亲缘聚类，9 单测）；面板全量展示；并发 1-16（两个死参数接线） |
| 936c1ea5 | 芯片发送侧口径（estimatedSentTotal，4 单测）；ToolResultSpill 大结果转存；getToolResult query 检索（search，8 单测）+ 文件回退；套件汇总移到文件末尾 |
| aaafc9fa | 持久化自动压缩（compactNow：归档伴生文件 + [compacted history] 摘要备注 + 旧摘要并链）；回合末自动触发；/compact 改真压缩；recallConversation 连归档搜；文案去 /new 化；删会话清归档 |
| 4020ceb2 | 请求组装单趟压缩（digest 同趟产出，主线程不再重算）；空响应重试前收紧预算；listBatchDownloads 分级输出（summary/full）；压缩计数器 bug 修复；流式停摆看门狗（六调用点全覆盖）；Doctor 新增压缩/转存体检；digest 无正文回合报工具动作 |

## 验收门（发布前全部过一遍）

1. **纯逻辑套件**：`bash tests/run.sh`（当前 3272/0；发布时重跑，总数必须随
   本版 ≥3272）。
2. **本地 Release 零警告**：`xcodebuild -configuration Release clean build |
   grep -E "warning:"`（Debug 不编译 `#if !DEBUG` 分支——0.8.35 教训）。
3. **release-smoke**：`python3 tests/release-smoke.py`。
4. **探针（按 CHANGELOG 验收项）**，`--automation` 实例 + 假端点：
   - **自动压缩探针**：假端点回大体积对话若干轮 → 落盘超 160k → 回合结束
     断言 `conversation-<id>.archive.json` 出现、芯片回落、/compact 回复
     "无需压缩"（已压过）。
   - **转存探针**：本地 fixture 大页面 → getPageHTML → 工具消息含
     `[desire-spill: 路径]`、文件存在、`getToolResult(query=…)` 对全文命中。
   - **看门狗探针**：假端点只发 keepalive 不发事件 + `defaults write
     agentStreamStallSeconds 30` → 回合 ~35s 内报错（非永久挂起）；测完复位。
   - **Doctor 探针**：`GET /agent/doctor` 包含"上下文压缩""转存目录"两项。
   - **落点归并/多视频聚类**：单测已覆盖（21+9 项）；live 批次由用户实测
     （真实站点行为，不进自动化）。
5. **UI 项用户过目**：后台任务条头部 chip、芯片新形态（压缩态橙色循环）、
   批量设置并发 menu、面板全量明细、验证窗自愈（真实批次）。

## 发布前清单

- [ ] **agent-memory.json 两条事实修正**（需退出 Desire 后改盘上文件，内存态
      会覆盖）：①"批量下载保存位置 = /Volumes/sd"补全语义（=默认根，host 自
      动补）；②correction 改为"不传 directory 走默认链，不是每次重新确认"。
      改完随版本生效。
- [ ] **WhatsNewSheet.highlights 刷成本版亮点**（0.8.26 装上后看到旧内容的
      教训——发布前必做）：候选 = 自动压缩 / 大结果转存检索 / 批量落点智能
      归并 + 多视频全下 / 单批 500·并发 16·CF 自愈 / 芯片新口径 / 看门狗。
- [ ] `scripts/changelog.py verify`（release.sh prep 阶段会自动跑）。
- [ ] 冻结发布内容：本版提交内不混入下一版开发（调度后可继续）。
- [ ] `scripts/release.sh 0.8.59` 触发云端双架构零警告构建 → publish；
      tag 由云端建（本地 `git fetch --tags` 查看）。
- [ ] 产品页部署（手工步）。

## 遗留（不进本版）

- **请求级 token 校准**：芯片/预算按字符口径（160k chars ≈ 未必 token 真
  值）；需先定"模型真实窗口"的产品口径（每模型窗口表 or 用户自填），再接
  promptTokens 实测校准。探针已具备（消息上落了逐条 promptTokens）。
- **归档清理策略**：archive 伴生文件随历史增长，无 GC（会话删除时已联动清
  理）；观察真实使用后再定（按大小/时长）。
- **agent-eval 扩面**：压缩/看门狗探针若稳定，收进 release-smoke 可选档。
- **E2E 全量**：execution-e2e 未跑（190 项 ~15 分钟；本版不改核心浏览/回合
  循环主干，按惯例跳过；下个里程碑跑）。
