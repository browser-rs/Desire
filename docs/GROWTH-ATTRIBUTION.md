# 归因与转化（v0.8.3）

运营闭环的最后一段：**页面浏览 → 下载点击 → 首次启动** 的匿名漏斗。
设计原则：只回答"哪条内容带来了点击/安装"，不识别任何个人。

## 数据边界

`growth_events` 只存：

| 列 | 说明 |
|---|---|
| `event` | `page_view` / `download_click` / `first_launch` |
| `source` / `medium` / `campaign` / `content` | UTM 标签（空字符串 = 未带） |
| `path` | 页面路径（不含 query） |
| `app_version` | 仅首启事件带 |
| `day` / `occurred_at` / `created_at` | 服务端 UTC 时间 |

**不存**：IP、Cookie、UA、设备指纹、账号 id、邮箱、任何自由文本。
产品页 beacon 不使用 Cookie / 第三方脚本；Do Not Track 或
`localStorage["desire_growth_optout"]="1"` 时完全不发。
App 首启事件默认开，可在运营页「Attribution」里关闭。

## 部署（发版日的手工步）

1. **迁移**：新文件 `crates/common/migrations/0017_growth_events.sql`。
   - 本地 dev 启动 API 自动跑；
   - 生产执行 `cargo run -p desire-common --bin desire-migrate`（或部署流程里的迁移步）。
2. **API**：部署包含 `modules/growth` 的新二进制。公开事件端点
   `POST /v9/growth/event`；聚合读取 `GET /v9/growth/summary?days=30`（登录态）。
   CORS 允许 `https://desire.mankong.icu` 与本地 fixture（`127.0.0.1:8877`）；
   换域名时改 `crates/api/src/routes/growth.rs` 的白名单。
3. **产品页**：部署 `website/growth-beacon.js` 与 `website/index.html`（下载按钮已加
   `data-growth-download`）。beacon 端点可用 `window.DESIRE_GROWTH_ENDPOINT` 覆盖。
4. **App**：设置 › 同步 登录后，运营页「Attribution」加载聚合；首启事件在
   `AppState` 启动末尾发送一次（失败也写标记，避免每次启动都请求）。

## 本地 E2E（已验证）

```bash
# 临时库 + 18091 端口（不要动现有 desire 库）
mysql -e "CREATE DATABASE desire_growth_test ..."
DATABASE_URL=mysql://root:***@127.0.0.1:3306/desire_growth_test \
DESIRE_ENV=dev DESIRE_API_JWT_SECRET=growth-e2e-secret \
DESIRE_API_BIND_ADDR=127.0.0.1:18091 \
MIGRATIONS_DIR=crates/common/migrations ./target/debug/desire-api
python3 /tmp/growth_e2e.py   # 事件/非法事件 422/未登 401/汇总/CORS
```

实测结果：4 条事件入库；`page_view=2 / download_click=1 / first_launch=1`；
campaign `v0.8.3 = 2/1/0`；source `x = 2/1/0`；CORS preflight 返回
`Access-Control-Allow-Origin: https://desire.mankong.icu`；表结构无 IP/UA/Cookie 列。

## 读取端点权限

`/growth/summary` 走 `jwt_auth`（与同步共用账号）。**单 owner 部署**下够用；
公开运营/多用户前应加管理员角色或独立只读 token。聚合是全局匿名计数，不是
按用户隔离的数据。

## 速率与保留

- 事件端点按 IP 滑动窗口 120 次/分钟（进程内；IP 只在内存里用于限流，不落库）。
- 原始事件目前不设 TTL；数据量增长后建议加"按日聚合 + 原始事件 180 天清理"。
