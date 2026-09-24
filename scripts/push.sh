#!/usr/bin/env bash
# 打 tag 并推送镜像到仓库。
# 用法: ./scripts/push.sh <api|migrate> [tag]
# 例:   ./scripts/push.sh api              -> 推送 latest + <short-hash>
#        ./scripts/push.sh api v1.0        -> 推送 v1.0 + <short-hash>
set -euo pipefail

cd "$(dirname "$0")/.."

BIN="${1:-}"
TAG="${2:-latest}"
REGISTRY="${DESIRE_IMAGE_REGISTRY:-registry.cn-shenzhen.aliyuncs.com/pura}"
SHORT_HASH="$(git rev-parse --short HEAD)"

if [[ "$BIN" != "api" && "$BIN" != "migrate" ]]; then
  echo "用法: $0 <api|migrate> [tag]" >&2
  exit 1
fi

# 优先用 container CLI（Apple），回退 docker
if command -v container >/dev/null 2>&1; then
  CLI=(container image)
elif command -v docker >/dev/null 2>&1; then
  CLI=(docker image)
else
  echo "未找到 container 或 docker CLI" >&2
  exit 1
fi

# 要推送的 tag 列表：用户指定的 tag + 短 commit hash
TAGS=("${TAG}")
if [[ ! " ${TAGS[*]} " =~ " ${SHORT_HASH} " ]]; then
  TAGS+=("${SHORT_HASH}")
fi

LOCAL="desire-${BIN}:${TAG}"

for t in "${TAGS[@]}"; do
  REMOTE="${REGISTRY}/desire-${BIN}:${t}"

  echo ">>> tag ${LOCAL} -> ${REMOTE}"
  "${CLI[@]}" tag "${LOCAL}" "${REMOTE}"

  echo ">>> push ${REMOTE}"
  "${CLI[@]}" push "${REMOTE}"
done

echo ">>> 完成: ${REGISTRY}/desire-${BIN}:${TAGS[*]}"
