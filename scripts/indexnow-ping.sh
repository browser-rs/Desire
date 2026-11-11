#!/bin/bash
# 部署后通知 IndexNow 生态（Bing / Yandex / Seznam / Naver）重新抓取。
# Google 不吃 IndexNow —— 走 Search Console 的“网址检查 → 请求编入索引”。
#
# 前置：website/<32位hex>.txt 已随站点部署（key 文件必须能公开访问）。
# 用法：scripts/indexnow-ping.sh [host]，默认 desire.mankong.icu
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:-desire.mankong.icu}"
SITEMAP="https://${HOST}/sitemap.xml"

KEY_FILE="$(find website -maxdepth 1 -name '*.txt' -type f | grep -E '/[0-9a-f]{32}\.txt$' | head -1 || true)"
if [ -z "${KEY_FILE}" ]; then
  echo "✗ 找不到 website/<32位hex>.txt（IndexNow key 文件）" >&2
  exit 1
fi
KEY="$(basename "${KEY_FILE}" .txt)"

# key 文件必须已经在线（404 会让 IndexNow 整批拒绝）。
if ! curl -fsS -m 15 "https://${HOST}/${KEY}.txt" | grep -q "${KEY}"; then
  echo "✗ https://${HOST}/${KEY}.txt 不可访问或内容不符——先把 website/ 部署上线" >&2
  exit 1
fi

URLS="$(curl -fsS -m 20 "${SITEMAP}" | grep -oE '<loc>[^<]+' | sed 's/<loc>//' | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
if [ "${URLS}" = "[]" ]; then
  echo "✗ sitemap 里没有 URL" >&2
  exit 1
fi

echo "→ ${HOST}: ${URLS}"
curl -sS -m 30 -o /dev/null -w 'HTTP %{http_code}\n' \
  -X POST "https://api.indexnow.org/indexnow" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data "{\"host\":\"${HOST}\",\"key\":\"${KEY}\",\"keyLocation\":\"https://${HOST}/${KEY}.txt\",\"urlList\":${URLS}}"
echo "完成。Bing/Yandex 通常几分钟到几天内抓取；Google 请用 Search Console 请求编入索引。"
