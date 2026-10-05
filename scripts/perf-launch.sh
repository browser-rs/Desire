#!/usr/bin/env bash
# 启动性能探针（0.6.4）：启动 app → 轮询桥 /state 就绪 → 输出秒数。
# 用法：scripts/perf-launch.sh [阈值秒，默认 5] [APP 路径，默认当前构建产物]
# 退出码：> 阈值 = 1（供 CI/本地门禁）。桥不可达 = 2。
# 探针口径：进程启动→桥就绪（含进程冷启动）；UI 全就绪看统一日志的三拍
# （首窗相位通常 < didFinish，因首窗走 PresentedWindowContent 装配流）。
set -euo pipefail
THRESHOLD="${1:-5}"
# BUILT_PRODUCTS_DIR 已含 Debug/Release 段——只在不带配置段时补 Debug（老坑：拼出 Debug/Debug）。
PRODUCTS_DIR="$(xcodebuild -project "$(dirname "$0")/../apps/macos/Desire.xcodeproj" -scheme Desire -showBuildSettings 2>/dev/null | grep -m1 "BUILT_PRODUCTS_DIR" | sed 's/.*= //')"
case "$PRODUCTS_DIR" in
  */Debug|*/Release) APP_CFG="$PRODUCTS_DIR" ;;
  *) APP_CFG="$PRODUCTS_DIR/Debug" ;;
esac
APP="${2:-$APP_CFG/Desire.app}"
[ -d "$APP" ] || { echo "app not found: $APP"; exit 2; }

pkill -9 -x Desire 2>/dev/null || true
sleep 2
START=$(python3 -c 'import time; print(time.time())')
open "$APP" --args --automation
for i in $(seq 1 100); do
  if curl -s -m 1 http://127.0.0.1:8799/state >/dev/null 2>&1; then break; fi
  sleep 0.1
done
END=$(python3 -c 'import time; print(time.time())')
READY=$(python3 -c "print(f'{$END-$START:.2f}')")
if ! curl -s -m 2 http://127.0.0.1:8799/state >/dev/null; then
  echo "bridge never came up"; exit 2
fi
echo "launch→bridge ready: ${READY}s (threshold ${THRESHOLD}s)"
# 用统一日志里的分段相位辅助定位（本次启动的三拍）
/usr/bin/log show --last 1m --info --predicate 'process == "Desire" AND category == "app"' --style compact 2>/dev/null | grep "launch phase" | tail -3 || true
python3 -c "import sys; sys.exit(0 if $READY <= $THRESHOLD else 1)"
