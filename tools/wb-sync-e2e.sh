#!/usr/bin/env bash
# 白板同步域（0.6.8 第九类）服务端 E2E：白名单放行 / push applied / tombstone /
# 拉回含两类行（墓碑 payload null）/ 未知域 404。前置 = 本地 dev api（18090）。
set -euo pipefail
BASE="${1:-http://127.0.0.1:18090}"
req() { local m=$1 p=$2 b=${3:-} t=${4:-}; local args=(-sS -X "$m" "$BASE$p" -H 'Content-Type: application/json'); [ -n "$t" ] && args+=(-H "Authorization: Bearer $t"); [ -n "$b" ] && args+=(-d "$b"); curl "${args[@]}"; }
code() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "$BASE$2" -H 'Content-Type: application/json' ${3:+-H "Authorization: Bearer $3"} ${4:+-d "$4"}; }
PASS=0; ok() { PASS=$((PASS+1)); echo "ok $PASS: $1"; }

CAP=$(curl -s "$BASE/auth/captcha")
CID=$(echo "$CAP" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['captcha_id'])")
CCODE=$(echo "$CAP" | python3 -c "import json,sys;print(json.load(sys.stdin)['data'].get('code',''))")
U="wbe2e_$(date +%s)"
REG_BODY="{\"username\":\"$U\",\"password\":\"wbe2e1234a\",\"captcha_id\":\"$CID\",\"captcha_code\":\"$CCODE\"}"
TOK=$(req POST /auth/register "$REG_BODY" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['access_token'])")
[ -n "$TOK" ] && ok "注册+登录"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%S")
HMAC1="hmac-conv-aaa-111"
HMAC2="hmac-conv-bbb-222"
PUSH1="{\"items\":[{\"client_id\":\"$HMAC1\",\"client_updated_at\":\"$NOW\",\"deleted\":false,\"payload\":{\"v\":\"e2e-ct\"}}]}"
R1=$(req POST /sync/whiteboard "$PUSH1" "$TOK")
S1=$(echo "$R1" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['results'][0]['status'])")
[ "$S1" = "applied" ] && ok "whiteboard push 文档 applied"

DEL="{\"items\":[{\"client_id\":\"$HMAC2\",\"client_updated_at\":\"$NOW\",\"deleted\":true,\"payload\":null}]}"
R2=$(req POST /sync/whiteboard "$DEL" "$TOK")
S2=$(echo "$R2" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['results'][0]['status'])")
[ "$S2" = "applied" ] && ok "whiteboard push 墓碑 applied"

PULL=$(req GET /sync/whiteboard "" "$TOK")
N=$(echo "$PULL" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['data']['items']))")
TOMBNULL=$(echo "$PULL" | python3 -c "
import json,sys
items=json.load(sys.stdin)['data']['items']
t=[i for i in items if i.get('deleted')]
print(bool(t) and all(i.get('payload') is None for i in t))")
[ "$N" -ge 2 ] && [ "$TOMBNULL" = "True" ] && ok "全量 pull 含文档+墓碑（墓碑 payload null）"

C404=$(code GET /sync/nonexistent "$TOK")
CWB=$(code GET /sync/whiteboard "" "$TOK")
[ "$C404" = "404" ] && [ "$CWB" = "200" ] && ok "白名单：whiteboard 200 / 未知域 404"

echo "PASS $PASS/4"
