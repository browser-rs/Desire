#!/bin/bash
# 190 全量回归的标准入口（v0.8.83）：fresh data-dir + 启动即激活。
#
# 为什么必须这样跑：`open -g` 后台启动时 firstWindowMs 会等到有人点窗口才记
# （实测 21s），启动预算断言会假失败；fresh 则避免上一轮的缩放/标签/阅读进度
# 污染基线。用户正在用机器时不要跑（套件会抢前台）。
set -euo pipefail
cd "$(dirname "$0")/.."

tools/launch-hermetic.sh --fresh --activate

# 等桥与首个标签页就绪（launcher 只保证激活；这里再把"主窗可用"作为硬门槛）。
for _ in $(seq 1 40); do
  if curl -s --max-time 1 http://127.0.0.1:8799/state 2>/dev/null \
      | grep -q '"isActive":true' \
     && curl -s --max-time 1 http://127.0.0.1:8799/state 2>/dev/null \
      | grep -q '"startup":{[^}]*"firstWindowMs":[0-9]'; then
    break
  fi
  sleep 0.5
done

exec python3 tests/execution-e2e.py "$@"
