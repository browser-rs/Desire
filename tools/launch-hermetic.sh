#!/bin/bash
# 封闭启动开发实例（v0.8.76）：文件存储与系统偏好一起隔离，不碰用户的任何数据。
#
# 用法：tools/launch-hermetic.sh [dataDir]        # 默认 /tmp/desire-e2e/data
#
#   --data-dir        重定向 Desire 主目录（会话/记忆/档案/技能/工作区）
#   CFFIXED_USER_HOME 把系统偏好也隔离出去——写入既不进用户真实域也不落盘，
#                     只在本进程内有效。应用在带 --data-dir 却没有它时会拒绝启动
#                     （HermeticLaunchGuard）。
#
# 后台启动（open -g），不抢前台。需要浏览器的用例由调用方自行激活；用户正在用
# 机器时不要激活。
#
# 隔离后偏好是出厂默认值：依赖非默认设置的套件（如访问等级）要经桥在实例内设置。
set -euo pipefail

DATA="${1:-/tmp/desire-e2e/data}"
case "$DATA" in /*) ;; *) DATA="$PWD/$DATA" ;; esac
ISOLATED_HOME="$DATA/home"

APP="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Desire-*/Build/Products/Debug/Desire.app 2>/dev/null | head -1 || true)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "找不到 Debug 构建产物；先执行 xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire build" >&2
  exit 1
fi

mkdir -p "$DATA" "$ISOLATED_HOME"

# 只结束开发实例（按 DerivedData 路径匹配）；/Applications 的安装版不受影响。
pkill -9 -f "DerivedData/Desire-.*/Build/Products/Debug" 2>/dev/null || true
sleep 1

open -g "$APP" --env "CFFIXED_USER_HOME=$ISOLATED_HOME" --args --automation "--data-dir=$DATA"

echo "dataDir:       $DATA"
echo "isolated home: $ISOLATED_HOME"
echo "app:           $APP"
