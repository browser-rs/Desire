#!/usr/bin/env bash
# 运行 desire 服务容器。
# 用法: ./scripts/run.sh <api|migrate> [--arch amd64|arm64] [--env-file 路径]
#      migrate 为一次性迁移容器:docker/container run --rm(跑完即删),无端口映射。
# 例:   ./scripts/run.sh api
#        ./scripts/run.sh api --arch amd64
#        ./scripts/run.sh api --env-file .env.prod
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="${1:-}"
ARCH=""
ENV_FILE=""

if [[ "$BIN" != "api" && "$BIN" != "migrate" ]]; then
  echo "用法: $0 <api|migrate> [--arch amd64|arm64] [--env-file 路径]" >&2
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      ARCH="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
        echo "env-file 不存在: $ENV_FILE" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "未知参数: $1" >&2
      exit 1
      ;;
  esac
done

# migrate 一次性迁移:--rm 跑完即删;如无 --env-file,需确保 DATABASE_URL 已在 shell 环境
if [[ "$BIN" == "migrate" ]]; then
  if command -v container >/dev/null 2>&1; then
    RUN_MIGRATE=(container run --rm --name "desire-migrate")
    [[ -n "$ARCH" ]] && RUN_MIGRATE+=(--arch "$ARCH")
    [[ -n "$ENV_FILE" ]] && RUN_MIGRATE+=(--env-file "$ENV_FILE")
    RUN_MIGRATE+=("desire-migrate:latest")
    echo ">>> 执行迁移: ${RUN_MIGRATE[*]}"
    "${RUN_MIGRATE[@]}"
  elif command -v docker >/dev/null 2>&1; then
    RUN_MIGRATE=(docker run --rm --name "desire-migrate")
    [[ -n "$ENV_FILE" ]] && RUN_MIGRATE+=(--env-file "$ENV_FILE")
    RUN_MIGRATE+=("desire-migrate:latest")
    echo ">>> 执行迁移: ${RUN_MIGRATE[*]}"
    "${RUN_MIGRATE[@]}"
  else
    echo "未找到 container 或 docker CLI" >&2; exit 1
  fi
  exit 0
fi

PORT=18090

# 优先 container CLI（Apple），回退 docker
if command -v container >/dev/null 2>&1; then
  RUN_CMD=(container run -d --name "desire-api" -p "${PORT}:${PORT}")
  [[ -n "$ARCH" ]] && RUN_CMD+=(--arch "$ARCH")
  [[ -n "$ENV_FILE" ]] && RUN_CMD+=(--env-file "$ENV_FILE")
  RUN_CMD+=("desire-api:latest")
elif command -v docker >/dev/null 2>&1; then
  RUN_CMD=(docker run -d --name "desire-api" -p "${PORT}:${PORT}")
  [[ -n "$ENV_FILE" ]] && RUN_CMD+=(--env-file "$ENV_FILE")
  RUN_CMD+=("desire-api:latest")
else
  echo "未找到 container 或 docker CLI" >&2
  exit 1
fi

echo ">>> 启动 desire-api (容器端口 ${PORT}) ..."
"${RUN_CMD[@]}"
echo ">>> 已启动。日志: container logs -f desire-api"
