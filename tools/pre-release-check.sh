#!/bin/bash
# 发版前快查（2026-10-19 流程重组）：默认 ~1 分钟——干净树 / 纯逻辑单测 /
# CHANGELOG 结构 / 远端查重 / **套件戳**。完整闸门已内置在 scripts/release.sh
# 的 gates+build 阶段（永远跑在最终提交上）；本脚本只是让你**发版前早点知道**。
# --build 追加 clean Release 零警告构建（~5 分钟；release.sh build 阶段同款）。
# 用法：tools/pre-release-check.sh [版本号] [--build]
set -e
cd "$(dirname "$0")/.."
FAIL=0
WANT_BUILD=0
V=""
for arg in "$@"; do
  if [ "$arg" = "--build" ]; then WANT_BUILD=1; else V="$arg"; fi
done

echo "── 1/5 工作区干净"
if [ -n "$(git status --short)" ]; then
  echo "  ✗ 工作区有未提交变更："; git status --short; FAIL=1
else echo "  ✓"; fi

echo "── 2/5 纯逻辑单测（tests/run.sh）"
if tests/run.sh 2>&1 | tail -2 | grep -q "失败 0 项"; then echo "  ✓"; else
  echo "  ✗ 纯逻辑单测有失败（见上）"; tests/run.sh 2>&1 | tail -6; FAIL=1; fi

echo "── 3/5 套件戳（.git/desire-e2e-stamp——“这套代码跑过完整 E2E 套件”）"
STAMP=".git/desire-e2e-stamp"
if [ ! -f "$STAMP" ]; then
  echo "  ✗ 没有套件戳——先跑完整套件：python3 tests/execution-e2e.py"; FAIL=1
else
  STAMP_SHA=$(awk '{print $1}' "$STAMP")
  STAMP_META=$(awk '{print $2" 于 "$3}' "$STAMP")
  CHANGES=$(git diff --name-only "$STAMP_SHA..HEAD" 2>/dev/null \
    | grep -vE '^(CHANGELOG\.md|website/|docs/|scripts/|tools/|AGENTS\.md|apps/macos/Desire\.xcodeproj/project\.pbxproj)' || true)
  if [ -n "$CHANGES" ]; then
    echo "  ✗ 套件戳之后的提交动了代码——重跑套件："
    printf '%s\n' "$CHANGES" | head -5
    FAIL=1
  else echo "  ✓ ${STAMP_SHA:0:8}（${STAMP_META}）"; fi
fi

echo "── 4/5 CHANGELOG 结构校验"
python3 scripts/changelog.py verify >/dev/null 2>&1 && echo "  ✓" || { echo "  ✗ CHANGELOG 结构问题"; FAIL=1; }

echo "── 5/5 远端 tag/release 查重（传版本号时）"
if [ -n "$V" ]; then
  if git ls-remote --tags origin 2>/dev/null | grep -q "refs/tags/v$V$"; then echo "  ✗ 远端已有 tag v$V"; FAIL=1
  elif gh release view "v$V" >/dev/null 2>&1; then echo "  ✗ 远端已有 release v$V"; FAIL=1
  else echo "  ✓ 远端无 v$V"; fi
else echo "  (跳过——未传版本号)"; fi

if [ "$WANT_BUILD" = 1 ]; then
  echo "── +clean Release 构建（零警告；--build）"
  DD="/tmp/dd-precheck-$(date +%s)"
  if xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire \
      -configuration Release -derivedDataPath "$DD" clean build 2>&1 \
      | tee /tmp/precheck-build.log | grep -qE "BUILD SUCCEEDED"; then
    W=$(grep -E "warning:" /tmp/precheck-build.log | grep -v appintentsmetadataprocessor | wc -l | tr -d ' ')
    if [ "$W" = "0" ]; then echo "  ✓ 零警告"; else
      echo "  ✗ $W 条警告："; grep -E "warning:" /tmp/precheck-build.log | head -5; FAIL=1; fi
  else echo "  ✗ 构建失败"; grep -E "error:" /tmp/precheck-build.log | head -5; FAIL=1; fi
  rm -rf "$DD"
fi

echo ""
if [ "$FAIL" = "0" ]; then echo "✅ 快查全绿——直接发版：scripts/release.sh ${V:-<版本>}（闸门会在最终提交上再跑一遍）"
else echo "❌ 有红——修完再发"; exit 1; fi
