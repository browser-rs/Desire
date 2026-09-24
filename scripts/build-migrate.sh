#!/usr/bin/env bash
# 构建 desire-migrate 镜像(迁移执行器,one-shot)。
# 用法: ./scripts/build-migrate.sh [tag] [arch...]
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-latest}"
REGISTRY="${DESIRE_IMAGE_REGISTRY:-registry.cn-shenzhen.aliyuncs.com/pura}"
shift || true
ARCHS=("$@")
if [[ ${#ARCHS[@]} -eq 0 ]]; then
  ARCHS=(arm64 amd64)
fi

IMAGE="desire-migrate:${TAG}"
echo ">>> 构建 ${IMAGE} (arch: ${ARCHS[*]}, registry: ${REGISTRY}) ..."

ARGS=(
  -f docker/Dockerfile.migrate
  --build-arg "REGISTRY=${REGISTRY}"
  -t "${IMAGE}"
  .
)
for a in "${ARCHS[@]}"; do
  ARGS+=(--arch "$a")
done

if command -v container >/dev/null 2>&1; then
  container build --cpus "${DESIRE_BUILDER_CPUS:-4}" --memory "${DESIRE_BUILDER_MEMORY:-6G}" "${ARGS[@]}"
elif command -v docker >/dev/null 2>&1; then
  docker buildx build "${ARGS[@]}"
else
  echo "未找到 container 或 docker CLI" >&2; exit 1
fi
echo ">>> 完成: ${IMAGE}"
