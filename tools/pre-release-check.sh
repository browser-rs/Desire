#!/bin/bash
# 发版预检（2026-10-09 立：连续两版在 CI 闸门暴露本应本地发现的问题）。
# 全绿才允许跑 scripts/release.sh。<版本号> 参数仅用于展示。
set -e
cd "$(dirname "$0")/.."
FAIL=0

echo "── 1/5 工作区干净"
if [ -n "$(git status --short)" ]; then
  echo "  ✗ 工作区有未提交变更："; git status --short; FAIL=1
else echo "  ✓"; fi

echo "── 2/5 纯逻辑单测（tests/run.sh）"
if tests/run.sh 2>&1 | tail -2 | grep -q "失败 0 项"; then echo "  ✓"; else
  echo "  ✗ 纯逻辑单测有失败（见上）"; tests/run.sh 2>&1 | tail -6; FAIL=1; fi

echo "── 3/5 本地 clean Release 构建 + 零警告"
DD="/tmp/dd-precheck-$(date +%s)"
if xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire \
    -configuration Release -derivedDataPath "$DD" clean build 2>&1 \
    | tee /tmp/precheck-build.log | grep -qE "BUILD SUCCEEDED"; then
  W=$(grep -E "warning:" /tmp/precheck-build.log | grep -v appintentsmetadataprocessor | wc -l | tr -d ' ')
  if [ "$W" = "0" ]; then echo "  ✓ 零警告"; else
    echo "  ✗ $W 条警告："; grep -E "warning:" /tmp/precheck-build.log | head -5; FAIL=1; fi
else echo "  ✗ 构建失败"; grep -E "error:" /tmp/precheck-build.log | head -5; FAIL=1; fi
rm -rf "$DD"

echo "── 4/5 CHANGELOG 有 [Unreleased] 或已冻结版本段 + 结构校验"
python3 scripts/changelog.py verify >/dev/null 2>&1 && echo "  ✓" || { echo "  ✗ CHANGELOG 结构问题"; FAIL=1; }

echo "── 5/5 远端 tag/release 查重（传版本号时）"
V="${1:-}"
if [ -n "$V" ]; then
  if git ls-remote --tags origin | grep -q "refs/tags/v$V$"; then echo "  ✗ 远端已有 tag v$V"; FAIL=1
  else echo "  ✓ 远端无 v$V"; fi
else echo "  (跳过——未传版本号)"; fi

echo ""
if [ "$FAIL" = "0" ]; then echo "✅ 预检全绿——可发版：scripts/release.sh ${V:-<版本>}"
else echo "❌ 预检有红——修完再发"; exit 1; fi
