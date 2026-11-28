#!/bin/bash
# ImagePro 回归的标准入口（v0.8.85 批 1 第 19 件）：fresh + activate + 全量。
# 为什么 fresh：fixture 每轮新建（随机 workdir），但应用侧的会话/默认工具状态
# 会跨实例继承（偏好域），上一轮留下的工具/缩放会污染下一轮基线。
# 用法：tests/run-imagepro.sh [--section tools] [--require-pending] [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."

tools/launch-hermetic.sh --fresh --activate
exec python3 tests/imagepro-e2e.py "$@"
