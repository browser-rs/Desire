# Desire 后端构建与运行脚本

本机使用 Apple `container` CLI 构建/运行镜像（若有 `docker` CLI 会自动回退）。

## 脚本清单

| 脚本                 | 用途                                    |
| -------------------- | --------------------------------------- |
| `build-api.sh`       | 构建 desire-api 镜像（多架构）          |
| `build-migrate.sh`   | 构建 desire-migrate 迁移执行器镜像      |
| `push.sh`            | 打 tag 并推送镜像到仓库                 |
| `run.sh`             | 运行 desire-api 容器 / 一次性迁移容器   |
| `migrate.sh`         | 本地直接跑迁移（cargo，不起容器）       |
| （cargo bin）`desire-admin` | 运维 CLI：账号管理与注册开关      |
| `../tools/api-smoke.sh`     | auth 全链路冒烟（9 步）          |
| `../tools/api-sync-smoke.sh` | 同步全链路冒烟（9 步）          |

## desire-admin — 运维 CLI

```bash
DATABASE_URL=mysql://... cargo run -q -p desire-api --bin desire-admin -- user list
DATABASE_URL=... cargo run -q -p desire-api --bin desire-admin -- user reset-password <用户名> <新密码>
DATABASE_URL=... cargo run -q -p desire-api --bin desire-admin -- user delete <用户名>
DATABASE_URL=... cargo run -q -p desire-api --bin desire-admin -- user disable <用户名>
DATABASE_URL=... cargo run -q -p desire-api --bin desire-admin -- user enable <用户名>
DATABASE_URL=... cargo run -q -p desire-api --bin desire-admin -- registration status|on|off
DATABASE_URL=... cargo run -q -p desire-api --bin desire-admin -- stats
```

- `reset-password` / `disable` 会吊销该用户全部刷新令牌（已登录设备 access 过期后需重新登录）。
- `delete` 级联删除该用户的同步数据、设备与令牌。
- 注册开关存 DB（server_settings 表，立即生效）；env `DESIRE_API_ALLOW_REGISTRATION`
  显式设置时优先于 DB（强制封死场景），此时 CLI 的 on/off 会被拒绝并提示。

## 部署顺序（铁律）

```
1. build-migrate.sh          # 迁移执行器镜像
2. run.sh migrate --env-file .env.prod   # 一次性容器跑迁移
3. build-api.sh              # 业务镜像
4. run.sh api --env-file .env.prod       # 起服务
```

**迁移永远先于业务服务启动**；改迁移文件只需重建 migrate 镜像，不牵连 api 镜像。

## build-api.sh / build-migrate.sh — 构建镜像

```bash
./scripts/build-api.sh                  # desire-api:latest（arm64+amd64 双架构）
./scripts/build-api.sh v1.0             # 指定 tag
./scripts/build-api.sh latest arm64     # 只构建本机架构（最快）
./scripts/build-migrate.sh              # desire-migrate:latest
```

产物：`desire-api:<tag>` / `desire-migrate:<tag>`。多架构 amd64 走 Rosetta 编译，慢属正常；本地开发用单架构 arm64。

## push.sh — 打 tag 并推送

```bash
./scripts/push.sh api            # 推 latest + 当前 commit 短 hash
./scripts/push.sh api v1.0       # 推 v1.0 + 短 hash
```

目标仓库：`registry.cn-shenzhen.aliyuncs.com/pura/desire-<服务>:<tag>`（可用 `DESIRE_IMAGE_REGISTRY` 覆盖）。**先 build 再 push**（短 hash 取自当前 HEAD，push 前不换 commit）。

## run.sh — 运行容器

```bash
./scripts/run.sh api --env-file .env.prod
./scripts/run.sh migrate --env-file .env.prod   # 一次性迁移
```

容器名 `desire-api` / `desire-migrate`，端口映射 `18090:18090`。日志：`container logs -f desire-api`。

## migrate.sh — 本地迁移（不起容器）

```bash
DATABASE_URL=mysql://... ./scripts/migrate.sh
```

## 环境变量

全集见 `.env.api.example`。容器部署用 `--env-file` 注入：

| 变量                    | 必填 | 说明                                              |
| ----------------------- | ---- | ------------------------------------------------- |
| `DATABASE_URL`          | 是   | MySQL 连接串，如 `mysql://user:pass@host:3306/desire` |
| `DESIRE_ENV`            | 否   | `dev` / `prod`，默认 `dev`（影响日志格式与自动迁移） |
| `DESIRE_API_JWT_SECRET` | 生产必填 | JWT 密钥，默认值在 prod **启动即失败**         |
| `DESIRE_API_BIND_ADDR`  | 否   | 监听地址，默认 `0.0.0.0:18090`                    |
| `DESIRE_REDIS_URL`      | 否   | Redis 地址；空 = 直连 DB                          |
| `MIGRATIONS_DIR`        | 否   | 迁移 SQL 目录；镜像内已冷拷 `/app/migrations`，通常无需设置 |

> `DESIRE_ENV=prod` 时 api **不自动跑迁移**——迁移由 desire-migrate 执行器单点负责；
> 本地 dev 启动自动跑。可用 `DESIRE_MIGRATE_ON_START=1/0` 任何环境强制覆盖。

> 容器内访问宿主机 MySQL：`DATABASE_URL` 的 host 用宿主机局域网 IP（Apple container 不支持 `host.docker.internal`）。

## 客户端对接

 Desire.app 设置 → Sync → 服务器地址填 `https://<域名>`（**生产必须 HTTPS**，
macOS ATS 不吃明文 HTTP）。桥验证：`POST /sync/server {"baseURL":"..."}` 后
`POST /sync/now` 看返回里 `lastError`。

## Dockerfile

`docker/Dockerfile.api` / `Dockerfile.migrate` 多阶段构建：

- **builder**：`rust:1.98-trixie`，`--mount=type=cache` 持久化 cargo target（按架构分 id
  + sharing=locked，防多架构并行构建互踩），`docker/config.toml` 配 rsproxy 镜像源。
- **runner**：`debian:trixie`，api 以非 root 用户 `desire` 运行，仅含 `ca-certificates`。
- migrate 镜像把迁移 SQL 冷拷 `/app/migrations`。

base 镜像源默认 `registry.cn-shenzhen.aliyuncs.com/pura`，build 脚本 `--build-arg REGISTRY` 可改。
