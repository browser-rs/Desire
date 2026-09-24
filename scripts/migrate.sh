#!/usr/bin/env bash
# 部署阶段单点执行数据库迁移(执行者镜像只此一个,改迁移不需重建业务服务)。
# 用法: DATABASE_URL=mysql://... [MIGRATIONS_DIR=...] ./scripts/migrate.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DATABASE_URL:-}" ]; then
  echo "缺少 DATABASE_URL" >&2; exit 2
fi
cargo run -q -p desire-common --bin desire-migrate
