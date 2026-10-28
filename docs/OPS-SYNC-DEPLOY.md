# 同步服务端部署清单（2026-10-29，v0.8.17/0.8.18 服务端增量）

> 本机无 docker daemon，镜像构建在部署机做。铁律照旧（scripts/README）：
> **build-migrate → migrate → build-api → run.sh** 四步不许跳。

## 待部署的服务端增量（都在仓库 main）

| 增量 | 迁移 | 说明 |
|---|---|---|
| 0017 growth_events（v0.8.3 归因，**当时欠账**） | 0017 | 归因 v1 事件表 |
| excerpts 第十三同步域（v0.8.17） | 无迁移 | 纯 DOMAINS 白名单加行 |
| 多档案域键 `bookmarks@<profileUUID>`（v0.8.18 方案 A） | **0018** sync_domain_widen | `sync_items`/`sync_pull_cursors` 的 domain varchar(32)→(64)；应用层 is_valid_domain 校验 base 域 + 后缀 charset |

## 部署机步骤

```bash
cd <repo> && git pull
./scripts/build-migrate.sh          # 迁移执行器镜像
./scripts/migrate.sh                # 跑迁移（0017→0018，幂等可重放）
./scripts/build-api.sh              # API 镜像（双架构）
./scripts/run.sh api                # 滚动重启 API
```

## 部署后验证（真端点）

```bash
python3 tools/api-remote-smoke.py        # 既有人点对账 10 步
# 摘录域（应 200，不再是 404）：
curl -s https://api.mankong.icu/v9/sync/excerpts -H "Authorization: Bearer <token>"
# 多档案域（应 200）：
curl -s "https://api.mankong.icu/v9/sync/bookmarks@00000000-0000-0000-0000-000000000000" -H "Authorization: Bearer <token>"
```

## 客户端依赖

- excerpts 域：0.8.17+ 客户端（旧客户端不发该域，部署先后无影响）。
- 多档案：0.8.18+ 客户端在**非默认档案**下才发 `@` 后缀域——默认档案用户
  完全不受部署影响（域键与存量一致）。
