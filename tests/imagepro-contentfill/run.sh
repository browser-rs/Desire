#!/bin/zsh
# ImagePro 选区内容填充探针（v0.8.55 批 3）：独立 swiftc 编译（不依赖 app 实例）。
# 场景 = 蓝色渐变背景 + 白色"水印"矩形，矩形选区盖住水印，源区 = 选区正上方：
#   ① 选区内水印被背景替换（回到蓝）  ② 选区外像素逐像素不动
#   ③ 选区边缘过渡平滑（无硬跳变）    ④ 显式 sourceOrigin 生效（下方源区更亮）
# 附带回归：healedTexture 实参错位修复（heal/contentfill 同一低频融合路径）。
# 用法: tests/imagepro-contentfill/run.sh   （退出码 0 = 全过）
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d)
trap "rm -rf $OUT" EXIT
DIR=../../apps/macos/Desire/Features/ImagePro
swiftc -O main.swift \
  "$DIR/ImageEditorRaster.swift" "$DIR/ImagePipelineRenderer.swift" \
  "$DIR/ImageEditorTool.swift" "$DIR/ImageEditPipelineCore.swift" \
  "$DIR/ImageTransforms.swift" "$DIR/ImageEditorSelection.swift" \
  "$DIR/ImageProFilter.swift" -o "$OUT/probe" 2>/dev/null
"$OUT/probe"
