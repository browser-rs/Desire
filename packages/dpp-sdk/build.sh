#!/bin/bash
# desire-dpp-sdk 构建：src/core.js → dist/ 两产物，并同步到仓库内两个
# 消费点（website 部署源 + app bundle 资源）。node 无依赖（纯字符串拼接）。
# 跑法：bash packages/dpp-sdk/build.sh
set -euo pipefail
cd "$(dirname "$0")"

node build.mjs

# 同步消费点（产物是手写库的编译结果，允许提交进仓库）：
#   1. website/desire-sdk.js — 产品页静态部署源（线上 CDN）
#   2. apps/macos/Desire/UserScripts/desire-sdk.js — app bundle 内置副本
cp dist/desire-sdk.js ../../website/desire-sdk.js
cp dist/desire-sdk.js ../../apps/macos/Desire/UserScripts/desire-sdk.js
echo "synced: website/desire-sdk.js + apps/macos/Desire/UserScripts/desire-sdk.js"
