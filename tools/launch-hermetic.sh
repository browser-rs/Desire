#!/bin/bash
# 封闭启动开发实例（v0.8.76）：文件存储与系统偏好一起隔离，不碰用户的任何数据。
#
# 用法：tools/launch-hermetic.sh [dataDir]        # 默认 /tmp/desire-e2e/data
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

DATA="${1:-/tmp/desire-e2e/data}"
case "$DATA" in /*) ;; *) DATA="$PWD/$DATA" ;; esac

APP="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Desire-*/Build/Products/Debug/Desire.app 2>/dev/null | head -1 || true)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "找不到 Debug 构建产物；先执行 xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire build" >&2
  exit 1
fi

mkdir -p "$DATA"

# 只结束开发实例（按 DerivedData 路径匹配）；/Applications 的安装版不受影响。
pkill -9 -f "DerivedData/Desire-.*/Build/Products/Debug" 2>/dev/null || true
sleep 1

open -g "$APP" --args --automation "--data-dir=$DATA"

echo "dataDir:       $DATA"
echo "prefs domain:  me.siwi.Desire.automation"
echo "app:           $APP"
