#!/bin/bash
# 强杀恢复探针（v0.8.8 B3 验收）：N 轮 启动→tabs≥1→pkill -9→重启→恢复断言。
# 用法: bash tools/crash-restore-probe.sh [轮数=20]
# 前提: 屏幕未锁（激活/建窗在锁定进程里不跑，会假阴性——见 release-smoke 同款守卫）。
set -u
APP="${DESIRE_APP:-$(ls -d ~/Library/Developer/Xcode/DerivedData/Desire-*/Build/Products/Debug/Desire.app 2>/dev/null | head -1)}"
ROUNDS="${1:-20}"
[ -d "$APP" ] || { echo "✗ 找不到构建产物（设 DESIRE_APP= 覆盖）"; exit 1; }
PASS=0; FAIL=0
for i in $(seq 1 "$ROUNDS"); do
  # 真·强杀：不先 quit（先 quit 会让退出路径走完，测的就成干净退出了）。
  pkill -9 -x Desire >/dev/null 2>&1; sleep 1
  open "$APP" --args --automation; sleep 6
  TABS=""
  for _ in $(seq 1 24); do   # 最多再等 24×1s
    TABS=$(curl -s --max-time 2 http://127.0.0.1:8799/state 2>/dev/null | python3 -c "import json,sys
try: print(len(json.load(sys.stdin).get('tabs', [])))
except Exception: print(-1)" 2>/dev/null)
    [ "$TABS" -ge 1 ] 2>/dev/null && break
    sleep 1
  done
  if [ "$TABS" -ge 1 ] 2>/dev/null; then
    echo "round $i: PASS (tabs=$TABS)"; PASS=$((PASS+1))
  else
    echo "round $i: FAIL (tabs=$TABS)"; FAIL=$((FAIL+1))
    /usr/bin/log show --last 1m --info --predicate 'process == "Desire" AND eventMessage CONTAINS "restore"' --style compact 2>/dev/null | tail -5
  fi
done
echo "===== crash-restore: $PASS/$ROUNDS 通过 ====="
[ "$FAIL" -eq 0 ]
