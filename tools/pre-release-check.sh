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
  # 固定 DD（2026-10-20）：预检的 clean 构建**留作发版复用**——release.sh 的 build
  # 阶段发现构建戳覆盖 HEAD 时改为"增量重链接"（版本号变化只需重链接），不再重复
  # clean 构建（发版动作因此 ~8 分钟）。零警告与产物启动都在这一阶段付一次。
  DD="/tmp/dd-precheck"
  DD86="/tmp/dd-precheck-x86"
  rm -rf "$DD" "$DD86"
  if xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire \
      -configuration Release -derivedDataPath "$DD" clean build 2>&1 \
      | tee /tmp/precheck-build.log | grep -qE "BUILD SUCCEEDED"; then
    W=$(grep -E "warning:" /tmp/precheck-build.log | grep -v appintentsmetadataprocessor | wc -l | tr -d ' ')
    if [ "$W" = "0" ]; then echo "  ✓ arm64 零警告"; else
      echo "  ✗ $W 条警告："; grep -E "warning:" /tmp/precheck-build.log | head -5; FAIL=1; fi
  else echo "  ✗ 构建失败"; grep -E "error:" /tmp/precheck-build.log | head -5; FAIL=1; fi
  if [ "$FAIL" = "0" ]; then
    echo "  ── x86_64 clean 构建 ──"
    if xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire \
        -configuration Release -derivedDataPath "$DD86" -destination 'platform=macOS' \
        ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO clean build 2>&1 \
        | tee /tmp/precheck-build86.log | grep -qE "BUILD SUCCEEDED"; then
      W86=$(grep -E "warning:" /tmp/precheck-build86.log | grep -v appintentsmetadataprocessor | wc -l | tr -d ' ')
      if [ "$W86" = "0" ]; then echo "  ✓ x86_64 零警告"; else
        echo "  ✗ x86_64 $W86 条警告："; grep -E "warning:" /tmp/precheck-build86.log | head -5; FAIL=1; fi
    else echo "  ✗ x86_64 构建失败"; grep -E "error:" /tmp/precheck-build86.log | head -5; FAIL=1; fi
  fi
  # 产物启动验证（2026-10-20 反思落地）：非 DerivedData 路径启动 + **主窗就绪** +
  # 优雅退出。零警告只证明"编得出来"，主窗竞态/Keychain ACL 这类问题只有真启动才暴露。
  if [ "$FAIL" = "0" ]; then
    APP="$DD/Build/Products/Release/Desire.app"
    if [ -d "$APP" ]; then
      echo "  ── 产物启动验证（主窗 + 优雅退出）──"
      pkill -9 -x Desire 2>/dev/null || true; sleep 2
      open "$APP" --args --automation
      READY=0
      for _ in $(seq 1 40); do
        N=$(curl -s -m 2 http://127.0.0.1:8799/state 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("tabs",[])))
except Exception: print(0)' 2>/dev/null || echo 0)
        if [ "${N:-0}" -ge 1 ]; then READY=1; break; fi
        sleep 1
      done
      if [ "$READY" != 1 ]; then
        echo "  （主窗未就绪——优雅退出后重开一次）"
        osascript -e 'quit app "Desire"' >/dev/null 2>&1 || true
        sleep 3
        pkill -9 -x Desire 2>/dev/null || true; sleep 1
        open "$APP" --args --automation
        for _ in $(seq 1 40); do
          N=$(curl -s -m 2 http://127.0.0.1:8799/state 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("tabs",[])))
except Exception: print(0)' 2>/dev/null || echo 0)
          if [ "${N:-0}" -ge 1 ]; then READY=1; break; fi
          sleep 1
        done
      fi
      if [ "$READY" = 1 ]; then echo "  ✓ 启动后主窗就绪"
      else echo "  ✗ 启动后主窗未就绪（重开一次仍无）"; FAIL=1; fi
      osascript -e 'quit app "Desire"' >/dev/null 2>&1 || true
      sleep 3
      if pgrep -x Desire >/dev/null 2>&1; then
        echo "  ✗ 优雅退出失败（进程仍在）"; pkill -9 -x Desire 2>/dev/null || true; FAIL=1
      else echo "  ✓ 优雅退出"; fi
    else
      echo "  ✗ 找不到 Release 产物：$APP"; FAIL=1
    fi
  fi
  # 构建戳（全绿才写）：release.sh 的 build 阶段据此复用上面的 clean 构建。
  if [ "$FAIL" = "0" ]; then
    printf '%s %s\n' "$(git rev-parse HEAD)" "$(date '+%Y-%m-%dT%H:%M:%S')" > .git/desire-build-stamp
    echo "  ✓ 构建戳已写（$(git rev-parse --short HEAD)）——发版将增量复用"
  else
    rm -f .git/desire-build-stamp
  fi
fi

echo ""
if [ "$FAIL" = "0" ]; then echo "✅ 快查全绿——直接发版：scripts/release.sh ${V:-<版本>}（闸门会在最终提交上再跑一遍）"
else echo "❌ 有红——修完再发"; exit 1; fi
