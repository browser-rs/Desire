#!/usr/bin/env bash
# 构建 desire-api 镜像（多架构）。
# 用法: ./scripts/build-api.sh [tag] [arch...]
# 例:   ./scripts/build-api.sh                  -> desire-api:latest (arm64+amd64)
#        ./scripts/build-api.sh v1.0            -> desire-api:v1.0
#        ./scripts/build-api.sh latest arm64    -> 仅 arm64
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-latest}"
REGISTRY="${DESIRE_IMAGE_REGISTRY:-registry.cn-shenzhen.aliyuncs.com/pura}"

shift || true
ARCHS=("$@")
if [[ ${#ARCHS[@]} -eq 0 ]]; then
  ARCHS=(arm64 amd64)
fi

IMAGE="desire-api:${TAG}"

echo ">>> 构建 ${IMAGE} (arch: ${ARCHS[*]}, registry: ${REGISTRY}) ..."

ARGS=(
  -f docker/Dockerfile.api
  --build-arg "REGISTRY=${REGISTRY}"
  -t "${IMAGE}"
  .
)
for a in "${ARCHS[@]}"; do
  ARGS+=(--arch "$a")
done

# 优先用 container CLI（Apple），回退 docker
# builder 资源默认 4C/6G（container build 不带参数时 shim 按默认 2C/2G 重建 builder）
if command -v container >/dev/null 2>&1; then
  container build \
    --cpus "${DESIRE_BUILDER_CPUS:-4}" \
    --memory "${DESIRE_BUILDER_MEMORY:-6G}" \
    "${ARGS[@]}"
elif command -v docker >/dev/null 2>&1; then
  docker buildx build "${ARGS[@]}"
else
  echo "未找到 container 或 docker CLI" >&2
  exit 1
fi

echo ">>> 完成: ${IMAGE}"
