#!/bin/bash
# 白板 React 前端构建：src → Resources/ 根（bundle.js/bundle.css/index.html 平铺，与 mermaid.min.js 同级）。
# 依赖：npm install（本目录内）；产物进仓库（app 构建不依赖 node）。
set -e
cd "$(dirname "$0")"
npx esbuild src/main.tsx \
  --bundle \
  --outfile=../Desire/Features/Whiteboard/Resources/bundle.js \
  --target=safari17 \
  --minify \
  --define:process.env.NODE_ENV='"production"'
cp src/styles.css ../Desire/Features/Whiteboard/Resources/bundle.css
cp index.html ../Desire/Features/Whiteboard/Resources/index.html
echo "whiteboard webapp built: $(ls -la ../Desire/Features/Whiteboard/Resources/ | wc -l) entries"
