# DPP 第三方适配包

站点不会都主动接入 DPP。这里是**社区适配包**：按 host 匹配的声明式 JSON，
让 Desire 的 Agent 在没接入的站点上也能结构化读取与执行声明动作。

浏览器侧的加载语义：

- **页面原生声明优先**（L0–L3 任意形态）——适配器只补空白，站点接入后适配包自然失效
- 适配包是**纯 JSON、零代码**：`protocolBody` 与 L3 SDK `expose()` 是同一套协议格式
  （views/signals/actions/sections/ignore/context）；动作的 `run` 步骤由既有 pageAction
  执行器执行，**审批链照常生效**——适配包不引入任何新执行面
- 每包可独立启停（设置 › AI › DPP 协议 › 第三方适配），删除即从目录移除

## 格式

```json
{
  "format": "desire/adapter-1",
  "name": "example",                       // 唯一名（也是存储文件名）
  "hosts": ["example.com", ".example.org"], // 精确 host 或 ".domain" 子域通配
  "pathPrefixes": ["/article/"],            // 可选路径过滤；空 = 全站
  "notes": "一句话说明（来源/校准状态）",
  "protocolBody": {
    "pageType": "article",
    "contentMain": "article",
    "sections": { "article": "article", "comments": ".comments" },
    "ignore": ["nav", "footer"],
    "views": {
      "article": { "item": "article", "fields": { "title": "h1", "body": ".content" } }
    },
    "signals": { "ready": ".content" },
    "actions": [
      { "name": "share", "run": [{ "click": ".share-btn" }], "effects": "local" }
    ],
    "context": { "domain": "…", "rules": "…" }
  }
}
```

字段语义详见仓库 `docs/DPP-PROTOCOL.md`。`protocolBody` 也接受键名 `protocol`
（两种拼写都认）。

## 安装（浏览器内）

- **设置 UI**：设置 › AI › DPP 协议 › 第三方适配 › 导入（选 JSON 文件）
- **目录直放**：`~/Library/Application Support/Desire/DPPAdapters/<name>.json`
  （与 Skill 的 skills 目录同款习惯），设置页重开或调用桥 `POST /dpp/adapters/import`
  前会自动重扫
- **桥**：`GET /dpp/adapters`（列表）/ `POST /dpp/adapters/import {"path":…}` /
  `POST /dpp/adapters/toggle {"name":…,"enabled":false}` / `POST /dpp/adapters/remove {"name":…}`

## 编写守则

1. **selectors 保守多候选**（逗号并列），站点改版有冗余；写完在真实页面用
   DevTools 控制台 `document.querySelector(...)` 逐个核对——适配包不带"自动修复"
2. **只声明你核对过的东西**：没验证过的动作别写（动作会真实执行，虽然要过审批）
3. `ignore` 把导航/推荐流/横幅排掉——Agent 的读取精度主要靠它
4. `signals.ready` 指向**内容确实出现**的标记（不是 spinners）
5. 命名用小写站点名（`juejin.json`），与 `name` 一致
6. 不确定就参考 `juejin.json` 的形状；欢迎提 PR（提交前跑一遍目标站点的真实读取）
