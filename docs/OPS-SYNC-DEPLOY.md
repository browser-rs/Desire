# 同步服务端部署清单（2026-10-29，v0.8.17/0.8.18 服务端增量）

> 本机无 docker daemon，镜像构建在部署机做。铁律照旧（scripts/README）：
> **build-migrate → migrate → build-api → run.sh** 四步不许跳。

## 待部署的服务端增量（都在仓库 main）

| 增量 | 迁移 | 说明 |
|---|---|---|
| 0017 growth_events（v0.8.3 归因，**当时欠账**） | 0017 | 归因 v1 事件表 |
| excerpts 第十三同步域（v0.8.17） | 无迁移 | 纯 DOMAINS 白名单加行 |
| 多档案域键 `bookmarks@<profileUUID>`（v0.8.18 方案 A） | **0018** sync_domain_widen | `sync_items`/`sync_pull_cursors` 的 domain varchar(32)→(64)；应用层 is_valid_domain 校验 base 域 + 后缀 charset |
| ebooks 第十五同步域（v0.8.37） | 无迁移 | `DOMAINS` 白名单加行；未部署时客户端只有 ebooks 域失败，其他域照常 |
| 同步日配额 + API 2.0（v0.8.38） | **0019** sync_usage | 按用户/日/域记账；`/sync/usage`、`/meta/capabilities`、`/health` 细分、`/metrics`、`x-request-id`、remote ack/stats/cleanup |
| 查询索引审计（v0.8.38） | **0020** query_indexes | 同步拉取复合游标索引、remote inbox device/id 与 created_at 索引 |
| API 账号安全与运营面（v0.8.80） | **0021** session_versions_audit_quota | users/devices token_version、恢复码列、audit_events、sync_quota_daily；`sync_history_items.domain` 加宽到 64 并把误落 `sync_items` 的 `history@<uuid>` 搬进历史表 |
| API 存储上限与可信来源（v0.8.81 批 1） | **0022** sync_user_storage | 按用户同步存储字节计数（含历史表回填），push 事务内锁行/超限拒绝；配合 `DESIRE_API_TRUST_PROXY` / `DESIRE_API_USER_STORAGE_BYTES` |

## 部署机步骤

```bash
cd <repo> && git pull
./scripts/build-migrate.sh          # 迁移执行器镜像
./scripts/migrate.sh                # 跑迁移（0019→0022，幂等可重放）
./scripts/build-api.sh              # API 镜像（双架构；内含 /app/desire-admin）
./scripts/run.sh api                # 滚动重启 API
```

## 新增环境变量（v0.8.81 批 1）

| 变量 | 默认 | 说明 |
|---|---|---|
| `DESIRE_API_TRUST_PROXY` | `false` | 前面是自己可信反代时才设 `true`，才读 `x-forwarded-for`；否则只用 TCP 对端（防伪造/限流共享）。 |
| `DESIRE_API_USER_STORAGE_BYTES` | `268435456` | 每用户同步 payload 总字节上限；`0` = 不限。超限 push 返回 413，提示清理旧数据。 |

## 部署后验证（真端点）

```bash
python3 tools/api-remote-smoke.py        # 既有人点对账 10 步
# 摘录域（应 200，不再是 404）：
curl -s https://api.mankong.icu/v9/sync/excerpts -H "Authorization: Bearer <token>"
# 多档案域（应 200）：
curl -s "https://api.mankong.icu/v9/sync/bookmarks@00000000-0000-0000-0000-000000000000" -H "Authorization: Bearer <token>"
# ebooks 域（应 200，不再是 404）：
curl -s https://api.mankong.icu/v9/sync/ebooks -H "Authorization: Bearer <token>"
# v0.8.38：能力声明 / 配额 / 可观测（健康应 200 且 db=true；metrics 需 token）：
curl -s https://api.mankong.icu/v9/meta/capabilities
# v0.8.80 运维 CLI 已在 API 镜像里：
docker exec desire-api /app/desire-admin user list
# v0.8.81：DB 级账号安全 E2E（需要 dev 环境明文验证码 + 已跑 0022）
python3 tests/api-db-e2e.py --base http://127.0.0.1:18090
curl -s https://api.mankong.icu/v9/health
curl -s https://api.mankong.icu/v9/sync/usage -H "Authorization: Bearer <token>"
# v0.8.80：能力声明应含 tokenVersioning/accountRecovery/auditLog/atomicSyncQuota；
# 登出后旧 access token 立即 401（不再等 2h），恢复码/审计流程见 docs/ROADMAP-0.8.80-PLAN.md
curl -s https://api.mankong.icu/v9/meta/capabilities
curl -s https://api.mankong.icu/v9/metrics -H "Authorization: Bearer $DESIRE_API_METRICS_TOKEN"
# 任一响应头应带 x-request-id
```

## 客户端依赖

- excerpts 域：0.8.17+ 客户端（旧客户端不发该域，部署先后无影响）。
- 多档案：0.8.18+ 客户端在**非默认档案**下才发 `@` 后缀域——默认档案用户
  完全不受部署影响（域键与存量一致）。
