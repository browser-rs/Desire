# v0.8.37 规划稿（2026-11-02，已发布）—— 接得上：跨设备阅读与同步收口

> 0.8.34–0.8.36 把书架、分页、笔记、翻译、朗读、全库搜索都做成了本地能力；
> 但**读到哪、书签、进度、统计都锁在这台机器上**。本版不是又一次阅读器 UI 改版：
> 旗舰是**电子书同步域**，其余是摘录定位、Agent 同步工具、书架状态与统计合并。
> 服务端只加一行 `DOMAINS` 白名单（无迁移），但**需要重启 API 才生效**；未部署时
> 现有 per-domain 隔离保证只有 ebooks 域失败，其他域照常。

## 一、现状核实（规划前，2026-11-02）

- **同步域 14 类，没有 ebooks**：`SyncDomain` 只有书签/快拨/阅读列表/快捷键/设置/
  记忆/提示词/历史/白板/工作区/运营/任务/摘录/剪贴板；`EbookLibraryStore` 的书架 JSON、
  `EbookBookmark` 的按书文件、`EbookHighlightStore` 都是纯本地，没有墓碑/游标。
- **笔记已经跨设备，但回不去书里**：电子书高亮会写 `ExcerptStore`（第十三同步域），
  但 `Excerpt` 只有 `title/source/content/note`，`source` 是本机书库路径；换设备后
  路径不同，无法定位到书/章。
- **阅读进度/书签/统计不同步**：`ReadingStatsStore` 只写本机 DiskStore；
  书签按 `ebook.bookmarks.<id>` 存本机；`EbookLibraryStore.updateProgress` 只改本地 JSON。
- **服务端白名单**：`crates/api/src/modules/sync/sync_model.rs` 的 `DOMAINS` 14 项，
  无 ebooks；通用 `sync_items` 表不解读 payload，**加域不需要迁移**。
- **客户端域隔离已具备**：`SyncStore.runSyncCycle` 逐域 try/catch，单域失败不影响其他域；
  新增域 = `domainAdapters` 加一行 + 订阅源 store（现有 checklist）。
- **可复用的入口**：`CommandBus.shared.send(.openURL(...))` 可打开
  `desire://books/<id>?chapter=N`；`InternalPages` 已支持 chapter 参数；
  桥 `GET /sync/status`、`POST /sync/now` 已存在；Agent 尚无同步工具。
- **统计合并有重复计数风险**：两台设备同一天都读了 30 分钟，不能简单相加；
  按天/按书取 `max` 是更安全的跨设备口径。

## 二、目标

1. **读到哪都接得上**：书架进度、最后章节、书签跨设备；本机没有的书不凭空建条目，
   导入同 hash 后再接上。
2. **笔记可回跳**：摘录带书 hash + 章节 + 偏移，换设备后右键「在书中打开」。
3. **统计不重复**：按天/按书取最大值合并，统计页与阅读回顾看到的是合并口径。
4. **Agent 能同步**：`syncNow` / `syncStatus`，能回答"另一台设备读到哪了"。
5. **失败可见但不扩散**：服务端未部署 ebooks 域时，只该域失败，其他域继续同步。

## 三、四主题覆盖

| 主题 | 本版内容 |
|---|---|
| ① 浏览器基础 | 书架/继续阅读显示跨设备进度与同步徽标；设备状态入口；未部署时的失败提示 |
| ② Agent 基础 | `syncNow` / `syncStatus` 工具；`openBook` 默认接最远进度；阅读回顾含合并统计 |
| ③ 融合 | 摘录增加书/章/偏移定位；Excerpts「在书中打开」；跨设备笔记回跳 |
| ④ 替人干活 | 电子书同步域（书架/进度/书签/统计）、冲突/孤儿处理、同步诊断 |

## 四、功能设计（10 件）

### 1. 电子书同步域（旗舰）

- **现状**：书架/进度/书签全在本机。
- **增量**：
  - 新增 `SyncDomain.ebooks`（wire `ebooks`），服务端 `DOMAINS` 加一行。
  - 同步三类 item，payload 用 `kind` 区分：
    - `book`：client_id = `book:<sha256>`，payload = title/author/format/collection/
      favorite/progress/lastChapterIndex/chapterProgress/chapterCount/lastOpenedAt。
    - `bookmark`：client_id = `bookmark:<bookHash>:<bookmarkUUID>`，payload = 书签本体。
    - 书签删除 = tombstone（本机待删清单）。
  - **进度不新增独立 item**（放 book payload，减少条目数）。
  - 现有摘录域继续负责高亮/笔记（见 #3），不在 ebook 域重复。
- **验收**：本机改进度/收藏/书签 → 推送到服务端；第二设备（curl 模拟）改同 hash →
  `/sync/now` 拉取后书架/进度/书签一致；tombstone 删除不复活。

### 2. 合并语义与孤儿

- **现状**：没有跨设备合并规则。
- **增量**：
  - `EbookSyncCore`（纯逻辑，进 harness）：
    - 书条目按 **hash** 匹配；元数据（title/author/collection/favorite）LWW。
    - **进度取最远**：`progress` 大者胜；相同则 `lastOpenedAt` 新者胜；不倒退。
    - 书签按 UUID 并集；deleted=true 删本地；本机删除进 pendingDeletions。
    - `orphan`：远端书/书签在本机没有同 hash 时进 `EbookSyncOrphans`（DiskStore），
      **不凭空建书架条目**；用户导入同 hash 书后自动应用并清 orphan。
  - `EbookLibraryStore` 加 `applyRemote`（不触发本地 dirty 回推，走 SyncStore 的
    `applyRemotely` 守卫）。
- **验收**：进度 30% vs 60% → 60%；元数据旧戳不覆盖新戳；本机没有的书进 orphan，
  导入后进度/书签落地；重复 apply 幂等。

### 3. 摘录定位与「在书中打开」

- **现状**：摘录已同步，但 source 是本机路径，不能跳回书。
- **增量**：
  - `Excerpt` 加 optional `bookHash` / `chapterIndex` / `chapterTitle` / `startOffset` /
    `endOffset`（旧数据缺键为 nil，payload 向后兼容）。
  - `EbookReaderView.addHighlight` 写入这些字段；翻译存摘录同样带 locator。
  - Excerpts 面板：有 `bookHash` 且本机书库有同 hash 书 → 显示「在书中打开」，
    经 `CommandBus .openURL("desire://books/<id>?chapter=N")` 跳转；没有书时提示
    "这本书不在本机"。
  - 可选：把远端摘录 upsert 到 `EbookHighlightStore`，让书内正文也显示远端高亮
    （v1 先做跳转；正文回显放 P2/下一版）。
- **验收**：A 设备加高亮 → 同步 → B 设备 Excerpts 出现 → 点「在书中打开」落到同章；
  旧摘录无 locator 不崩；bookHash 不匹配时给明确提示。

### 4. 阅读统计同步

- **现状**：`ReadingStatsStore` 本机。
- **增量**：
  - 同步 `days`（yyyy-MM-dd → seconds）与 `books`（bookHash → seconds/pages）。
  - 合并口径：**按天取 max、按书取 max**（避免两台设备同一天重复计数）；
    连续天数/本周/总量基于合并后的 days 重算。
  - 统计页脚注注明"跨设备按最大值合并，不是相加"。
- **验收**：A 设备 30m / B 设备 20m 同一天 → 合并 30m 而非 50m；不同天累加；
  连续天数按合并 days 正确。

### 5. 书架跨设备状态

- **现状**：书架/继续阅读只显示本机进度。
- **增量**：
  - 同步拉取后，书卡/继续阅读大卡显示"来自另一台设备的进度"徽标（有远端进度且比本机远）；
  - 打开书时若远端进度更远，顶部条提示"已同步到 42%（另一台设备）"，可继续；
  - 书架显示同步状态（同步中/失败/上次同步），失败可点开设置 Sync；
  - 本机没有的 orphan 书不进书架（避免幽灵条目），只在设置诊断里计数。
- **验收**：远端进度更远时提示并接上；本机进度更远不被拉回；离线时状态可见。

### 6. 书签同步 UI 与墓碑

- **现状**：书签只在阅读器可见。
- **增量**：
  - 书签列表标注"已同步/来自另一台设备"（可选）；
  - 删除书签写 pendingDeletions，推送后清除；远端 tombstone 删除本地；
  - 书签同步失败不阻塞阅读（本地先落盘）。
- **验收**：A 删书签 → B 拉取后消失；B 新增 → A 出现；重复同步不产生重复书签。

### 7. Agent 同步工具

- **现状**：Agent 无同步工具。
- **增量**：
  - `syncNow`：触发一次 `SyncStore.syncNow()`，返回各域结果/失败域。
  - `syncStatus`：登录态、上次同步、各域状态、ebooks orphan 计数、各书远端/本机进度摘要。
  - `openBook` 无 chapter 时优先用**最远进度**（合并后）。
  - 阅读回顾 `readingDigest` 使用合并后的统计。
- **验收**：桥/Agent 询问"另一台设备读到哪"→ 返回书名+进度；未登录给明确提示；
  `syncNow` 失败域只列该域。

### 8. 同步诊断与设置

- **现状**：设置 Sync 页已有域开关/日志/冲突；新域自动出现。
- **增量**：
  - ebooks 域显示条目数/待删数/orphan 数/最后同步；
  - 冲突明细显示书名/章节（解密后提取可读标签）；
  - 桥 `GET /sync/status` 已含 domains，补 ebooks 计数；
  - 服务端未部署时显示"服务端不支持 ebooks 域，请更新并重启 API"。
- **验收**：域失败原因可见；orphan 计数正确；设置页不再只有 14 域。

### 9. 服务端白名单与冒烟

- **增量**：
  - `sync_model.rs` `DOMAINS` 加 `"ebooks"`，`is_valid_domain` 测试覆盖；
  - `tools/api-sync-smoke.*` 加 ebooks push/pull/conflict/tombstone 用例（或新脚本）；
  - **部署说明**：迁移无；只需重启 API（`run.sh api --env-file .env.prod`）。
- **验收**：本地/生产服务端 smoke 通过；未更新服务端时客户端只 ebooks 域失败，
  其他域照常（现有逐域隔离）。

### 10. 收口与验证

- i18n 三语；CHANGELOG 用 `scripts/changelog.py add`；WhatsNew 三亮点；
  产品页版本号/特性行同步。
- harness：EbookSyncCore 合并/orphan/进度最远/统计 max；Excerpt optional 编解码。
- E2E：本机 + curl 模拟第二设备（服务端本地）→ `/sync/now` → 断言书架/进度/书签；
  Excerpts 跳书；设置域状态。
- **发版闸门**：本地 **Release** clean build 零警告 + `tests/run.sh`；用户说「发」才发。

## 五、批次

- **批一（地基）**：1 + 2 + 9 —— 域/服务端白名单/合并纯逻辑/orphan 存储/逐域隔离。
- **批二（摘录与书签）**：3 + 6 —— Excerpt locator/在书中打开/书签墓碑与 UI。
- **批三（状态与 Agent）**：4 + 5 + 7 —— 统计合并/书架徽标/Agent 同步工具。
- **批四（诊断与收口）**：8 + 10 —— 设置/桥/冒烟/E2E/i18n/发版候选。

## 六、技术地图

**新增**

- `Features/Ebooks/EbookSyncCore.swift`（纯逻辑：item 结构/合并/进度最远/书签并集/
  orphan 规则，进 harness）
- `Features/Ebooks/EbookSyncStore.swift`（tombstone、orphan、脏通知）
- `Features/Ebooks/EbookSyncAdapter.swift`（或 SyncStore extension：collect/apply/clear）
- `Features/Ebooks/ReadingStatsSyncCore.swift`（纯逻辑：按天/按书 max 合并，进 harness）
- `Features/Sync/SyncEbookBridge.swift`（可选：SyncStore 与 Ebooks 的接线）
- `Features/Ebooks/EbookSyncDiagnosticsView.swift`（设置页区块，可复用 SettingsRow）

**改造**

- `SyncModels.swift`：`SyncDomain.ebooks` + displayName。
- `SyncStore.swift`：domainAdapters 加一行；init 订阅 `EbookLibraryStore` / `EbookSyncStore`；
  ebooks 域失败文案。
- `EbookLibraryStore`：applyRemote、orphan 应用、同步徽标状态。
- `EbookReaderModel`：书签增删通知 EbookSyncStore；openBook 最远进度。
- `Excerpt.swift` / `ExcerptStore` / `ExcerptsPanel`：locator 字段、在书中打开。
- `EbookAgentTools` + Definitions/Execution：`syncNow` / `syncStatus`。
- `crates/api/src/modules/sync/sync_model.rs`：DOMAINS + 测试。
- `tools/api-sync-smoke.*`：ebooks 用例。
- xcstrings / CHANGELOG / WhatsNew / website。

## 七、验证门

1. **harness**：EbookSyncCore 合并（进度最远/元数据 LWW/书签并集+墓碑/orphan/幂等）；
   ReadingStatsSyncCore（同日 max/不同日累加/连续天数）；Excerpt optional 往返。
2. **服务端 smoke**：ebooks push/pull/conflict/tombstone；未知域仍 404 且只影响该域。
3. **客户端 E2E**：本机桥 + curl 模拟第二设备；`/sync/now` 后 `/books`/进度/书签断言；
   Excerpts「在书中打开」跳章。
4. **构建**：本地 Debug + **Release** clean build 零警告；`tests/run.sh` 全绿。
5. **i18n**：新键三语零 null。
6. **手测（用户）**：两台设备/两个档案的进度与书签；服务端未更新时的失败提示。

## 八、不做（本版明确）

- **同步书籍文件本身**：只同步 hash 元数据/进度/笔记；每台设备自行导入同一文件。
- **对话同步**：用户 2026-09-24 的明确决定不改变。
- **多档案同步**（`domain@profile` 后缀）：设计稿已就绪，但服务端解析放宽另开版本，
  避免和 ebooks 白名单同批上线。
- 不做实时设备 presence/逐书"最后在哪个设备读"（设备列表已有，逐书记录后续）。
- 不做云端阅读统计聚合服务（客户端合并即可）。
- 不做 PDF/CBZ 批注同步（PDF 批注走 Excerpts，locator 不含 PDF 页码）。

## 九、风险与取舍

| 风险 | 取舍 |
|---|---|
| 服务端未部署 ebooks | 逐域隔离：仅 ebooks 失败并在设置/工具里明确提示；不阻断其他域 |
| 本机没有书 | 不建幽灵条目；orphan 存 DiskStore，导入同 hash 后应用 |
| 进度冲突 | 取最远，不倒退；重读需要手动重置（后续加"重置进度"入口） |
| 统计重复计数 | 按天/按书取 max，不做相加；页脚注明口径 |
| 摘录旧数据 | optional 字段缺键为 nil；无 locator 只显示原文，不崩溃 |
| 书签 tombstone | 删除先本地落盘 + pendingDeletions；推送成功才清 |
| 服务端时钟/时区 | 元数据 LWW 用客户端戳（现有钳制）；统计按本地日期 key，跨时区可能分桶 |
| 范围膨胀 | 批一先落同步域与合并核心；UI/Agent 随后；任何滑档并入下版 |

## 十、发版口径

CHANGELOG 只用 `scripts/changelog.py add`；WhatsNew 三亮点（跨设备进度/笔记回跳/
统计合并）；产品页同步版本号；**发版前本地 Release clean build 零警告**；
服务端部署是手工步（只需重启 API）；用户说「发」才发。
