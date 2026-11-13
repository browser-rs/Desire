#!/bin/zsh
# ImagePro 液化画笔探针（v0.8.54 批 7）：独立 swiftc 编译（不依赖 app 实例），
# 用合成黑白条纹图断言三种模式的边界位移方向：
#   push  +delta → 白色边界右移（沿拖拽方向推挤）
#   expand → 白色边界左移（径向外推、黑色区扩大）
#   pinch（圆心在黑区）→ 白色边界左移（径向内聚、白色被吸进来）
# 用法: tests/imagepro-liquify/run.sh   （退出码 0 = 全过）
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap "rm -rf $OUT" EXIT
swiftc -O main.swift ../../apps/macos/Desire/Features/ImagePro/LiquifyBrush.swift \
  -o "$OUT/probe" 2>/dev/null
"$OUT/probe"
