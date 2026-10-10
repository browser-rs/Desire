#!/bin/bash
# desire-dpp-sdk npm 发布（等 npm 账号就绪后执行）：
#   bash packages/dpp-sdk/publish.sh            # 正式发布
#   bash packages/dpp-sdk/publish.sh --dry-run  # 只打包预览不发布
# 前置：npm 登录（npm login）或 CI 里 NPM_TOKEN；版本号在 package.json 改。
set -euo pipefail
cd "$(dirname "$0")"

node build.mjs
node test/smoke.mjs

if [[ "${1:-}" == "--dry-run" ]]; then
    npm pack --dry-run
    echo "— dry run 完成（未发布）。确认产物后去掉 --dry-run 重跑。"
    exit 0
fi

npm publish
echo "已发布 desire-dpp-sdk@$(node -p "require('./package.json').version")"
