#!/bin/bash
# 封闭启动开发实例（v0.8.76）：文件存储与系统偏好一起隔离，不碰用户的任何数据。
#
# 用法：tools/launch-hermetic.sh [dataDir|--fresh] [--activate]
#       默认 /tmp/desire-e2e/data
#
#   --fresh      每次新建唯一 data-dir（/tmp/desire-e2e-XXXXXX）并把路径打出来；
#                连续跑套件时用它能避免上一次的缩放/标签/阅读进度污染基线。
#                同时清空隔离偏好域（固定域会跨实例继承，例如下载时段窗口）。
#   --activate   启动后立即激活并等 /state.isActive=true（启动指标/190 用）。
#                后台 open -g 会让 firstWindowMs 记成 ~20s（等有人点窗口），
#                这是**测试口径**问题，不是启动回归。
#
#   --data-dir   重定向 Desire 主目录（会话/记忆/档案/技能/工作区）。
#                应用内的全部偏好读写经 AppPrefs 走独立的命名域
#                （~/Library/Preferences/me.siwi.Desire.automation.plist），
#                不进用户自己的偏好；全部密钥读写经 KeychainService 走
#                <dataDir>/keychain/ 文件库，不碰系统钥匙串（连读都不读）。
#                应用在封闭模式下会自检这两点，不成立即拒绝启动
#                （HermeticLaunchGuard）。
#
# 后台启动（open -g），不抢前台。需要浏览器的用例由调用方自行激活；用户正在用
# 机器时不要激活。
#
# 隔离后偏好是全新的一份：依赖既有设置的套件（访问等级、通知策略等）要经桥在
# 实例内设置。启动后用 /state 的 startup 三项断言封闭性：dataDir、
# prefs == "isolated"、secrets == "file"。
# 清理隔离域：defaults delete me.siwi.Desire.automation
set -euo pipefail

DATA=""
ACTIVATE=0
FRESH=0
EXPECT_DATA=0
for arg in "$@"; do
  if [ "$EXPECT_DATA" = "1" ]; then
    DATA="$arg"
    EXPECT_DATA=0
    continue
  fi
  case "$arg" in
    --activate) ACTIVATE=1 ;;
    --fresh) DATA="$(mktemp -d /tmp/desire-e2e-XXXXXX)"; FRESH=1 ;;
    --data-dir) EXPECT_DATA=1 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) [ -z "$DATA" ] && DATA="$arg" ;;
  esac
done
DATA="${DATA:-/tmp/desire-e2e/data}"
case "$DATA" in /*) ;; *) DATA="$PWD/$DATA" ;; esac

APP="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Desire-*/Build/Products/Debug/Desire.app 2>/dev/null | head -1 || true)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "找不到 Debug 构建产物；先执行 xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire build" >&2
  exit 1
fi

mkdir -p "$DATA"

# 只结束开发实例（按 DerivedData 路径匹配）；/Applications 的安装版不受影响。
# 先 SIGTERM（应用会走 NSApp.terminate → 会话 flush）；强杀会跳过退出路径，
# 下一次启动可能没有主窗（2026-10-20 实测）。等不到再 -9 兜底。
pkill -TERM -f "DerivedData/Desire-.*/Build/Products/Debug" 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -f "DerivedData/Desire-.*/Build/Products/Debug" >/dev/null 2>&1 || break
  sleep 0.25
done
pkill -9 -f "DerivedData/Desire-.*/Build/Products/Debug" 2>/dev/null || true
sleep 0.5

# --fresh 也清掉隔离偏好域：固定域会跨实例继承（观察到的真实事故：上一个
# 测试设的下载时段窗口把 190 的下载测试卡在窗口外）。旧实例已结束，清安全。
if [ "$FRESH" = "1" ]; then
  defaults delete me.siwi.Desire.automation 2>/dev/null || true
fi

open -g "$APP" --args --automation "--data-dir=$DATA"

if [ "$ACTIVATE" = "1" ]; then
  for _ in $(seq 1 20); do
    osascript -e 'tell application "Desire" to activate' >/dev/null 2>&1 || true
    if curl -s --max-time 1 http://127.0.0.1:8799/state 2>/dev/null | grep -q '"isActive":true'; then
      break
    fi
    sleep 0.4
  done
fi

echo "dataDir:       $DATA"
echo "prefs domain:  me.siwi.Desire.automation"
echo "app:           $APP"
echo "activated:     $ACTIVATE"
