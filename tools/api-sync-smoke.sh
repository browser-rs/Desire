#!/usr/bin/env bash
# desire-api 同步引擎冒烟:前置 = api 已在本机运行。
# 用法:tools/api-sync-smoke.sh [BASE_URL]   (默认 http://127.0.0.1:18090)
# 覆盖:push applied / 全量 pull / LWW conflict(旧改动被拒+回传胜出版本) /
#       新改动覆盖 / tombstone 删除(deleted+payload 置空) / 游标增量拉取 /
#       settings 域 KV / 未知域 404
# 注意:macOS bash 3.2 对 $() 内嵌 \" 解析有毛病——JSON 一律先入变量再传参。
set -euo pipefail

BASE="${1:-http://127.0.0.1:18090}"

API="${2:-http://127.0.0.1:18090}"

fetch_captcha() { # 输出 "captcha_id captcha_code"(dev 回显)
  curl -s "$BASE/auth/captcha" | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
print(d['captcha_id'], d.get('code',''))"
}
USERNAME="syncsmoke_$(date +%s)"

PASS_STEPS=0
step() { PASS_STEPS=$((PASS_STEPS+1)); echo "ok $PASS_STEPS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

get() {
  python3 -c '
import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v[int(k)] if isinstance(v, list) else v[k]
print(v)
' "$1"
}

fetch_captcha() {
  curl -s "$BASE/auth/captcha" | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
print(d['captcha_id'], d.get('code',''))"
}

count() { python3 -c 'import json,sys;print(len(json.load(sys.stdin)["data"]["items"]))'; }

req() { # req <method> <path> [json] [token] → 响应体
  local m=$1 p=$2 b=${3:-} t=${4:-}
  local args=(-sS -X "$m" "$BASE$p" -H 'Content-Type: application/json')
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$b" ] && args+=(-d "$b")
  curl "${args[@]}"
}

code() { # code <method> <path> [json] [token] → HTTP 状态码
  local m=$1 p=$2 b=${3:-} t=${4:-}
  local args=(-s -o /dev/null -w '%{http_code}' -X "$m" "$BASE$p" -H 'Content-Type: application/json')
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$b" ] && args+=(-d "$b")
  curl "${args[@]}"
}

expect_code() {
  local want=$1
  shift
  local got
  got=$(code "$@")
  [ "$got" = "$want" ] || fail "期望 HTTP $want 实得 '$got'"
}

# ---- 登录拿 token(依赖 auth 模块) ----
CAP=$(fetch_captcha)
REG_BODY="{\"username\":\"$USERNAME\",\"password\":\"smoke-pass-123\",\"captcha_id\":\"${CAP%% *}\",\"captcha_code\":\"${CAP##* }\"}"
TOKEN=$(req POST /auth/register "$REG_BODY" | get data.access_token)
[ -n "$TOKEN" ] || fail "register 失败"
step "注册 + token"

# ---- push 2 条书签 ----
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%S)"
PUSH1="{\"items\":[{\"client_id\":\"bm-1\",\"client_updated_at\":\"$NOW_TS\",\"payload\":\"https://example.com/one\"},{\"client_id\":\"bm-2\",\"client_updated_at\":\"$NOW_TS\",\"payload\":\"https://example.com/two\"}]}"
R=$(req POST /sync/bookmarks "$PUSH1" "$TOKEN")
[ "$(echo "$R" | get data.results.0.status)" = "applied" ] || fail "bm-1 push 失败: $R"
[ "$(echo "$R" | get data.results.1.status)" = "applied" ] || fail "bm-2 push 失败: $R"
step "push 2 条 → applied"

# ---- 全量 pull ----
R=$(req GET /sync/bookmarks "" "$TOKEN")
[ "$(echo "$R" | count)" = "2" ] || fail "全量 pull 应 2 条: $R"
[ "$(echo "$R" | get data.items.0.payload)" = "https://example.com/one" ] || fail "payload 不符: $R"
step "全量 pull → 2 条,payload 原样"

# ---- LWW conflict:旧时间戳被拒,回传服务端胜出版本 ----
OLD_PUSH="{\"items\":[{\"client_id\":\"bm-1\",\"client_updated_at\":\"2020-01-01T00:00:00\",\"payload\":\"https://stale.example/old\"}]}"
R=$(req POST /sync/bookmarks "$OLD_PUSH" "$TOKEN")
[ "$(echo "$R" | get data.results.0.status)" = "conflict" ] || fail "旧改动应 conflict: $R"
[ "$(echo "$R" | get data.results.0.item.payload)" = "https://example.com/one" ] || fail "conflict 应回传胜者: $R"
step "旧改动 push → conflict + 回传胜者"

# ---- 幂等重放:同戳重推 → applied(服务端不写库),不产生永久 conflict 噪音 ----
R=$(req POST /sync/bookmarks "$PUSH1" "$TOKEN")
[ "$(echo "$R" | get data.results.0.status)" = "applied" ] || fail "同戳重放应 applied: $R"
[ "$(echo "$R" | get data.results.1.status)" = "applied" ] || fail "同戳重放(第2条)应 applied: $R"
step "同戳重放 → applied(幂等)"

# ---- 新时间戳覆盖 ----
NEW_PUSH="{\"items\":[{\"client_id\":\"bm-1\",\"client_updated_at\":\"2030-01-01T00:00:00\",\"payload\":\"https://example.com/one-v2\"}]}"
R=$(req POST /sync/bookmarks "$NEW_PUSH" "$TOKEN")
[ "$(echo "$R" | get data.results.0.status)" = "applied" ] || fail "新改动应 applied: $R"
R=$(req GET /sync/bookmarks "" "$TOKEN")
FOUND=$(echo "$R" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next(i["payload"] for i in d["data"]["items"] if i["client_id"]=="bm-1"))')
[ "$FOUND" = "https://example.com/one-v2" ] || fail "bm-1 应为新值: $FOUND"
step "新改动 push → applied,pull 到新值"

# ---- tombstone 删除 ----
DEL_PUSH="{\"items\":[{\"client_id\":\"bm-2\",\"client_updated_at\":\"2030-01-01T00:00:00\",\"deleted\":true}]}"
R=$(req POST /sync/bookmarks "$DEL_PUSH" "$TOKEN")
[ "$(echo "$R" | get data.results.0.status)" = "applied" ] || fail "删除应 applied: $R"
R=$(req GET /sync/bookmarks "" "$TOKEN")
DELETED=$(echo "$R" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next(i["deleted"] for i in d["data"]["items"] if i["client_id"]=="bm-2"))')
[ "$DELETED" = "True" ] || fail "bm-2 应为 tombstone: $R"
HAS_PAYLOAD=$(echo "$R" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(any("payload" in i for i in d["data"]["items"] if i["client_id"]=="bm-2"))')
[ "$HAS_PAYLOAD" = "False" ] || fail "tombstone 不应带 payload"
step "tombstone:deleted=true,payload 置空"

# ---- 游标增量拉取 ----
CURSOR=$(req GET /sync/bookmarks "" "$TOKEN" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["data"]["items"][-1]["updated_at"])')
PUSH3="{\"items\":[{\"client_id\":\"bm-3\",\"client_updated_at\":\"$NOW_TS\",\"payload\":\"https://example.com/three\"}]}"
req POST /sync/bookmarks "$PUSH3" "$TOKEN" > /dev/null
R=$(req GET "/sync/bookmarks?since=$CURSOR" "" "$TOKEN")
[ "$(echo "$R" | count)" = "1" ] || fail "增量拉取应恰 1 条: $R"
[ "$(echo "$R" | get data.items.0.client_id)" = "bm-3" ] || fail "增量拉取应只含 bm-3: $R"
step "游标增量 pull → 只含新增的 bm-3"

# ---- settings 域(KV:client_id=键,payload=值) ----
KV_PUSH="{\"items\":[{\"client_id\":\"homePage\",\"client_updated_at\":\"$NOW_TS\",\"payload\":\"https://example.com/home\"}]}"
req POST /sync/settings "$KV_PUSH" "$TOKEN" > /dev/null
R=$(req GET /sync/settings "" "$TOKEN")
[ "$(echo "$R" | get data.items.0.client_id)" = "homePage" ] || fail "settings 拉取失败: $R"
step "settings 域 KV roundtrip"

# ---- 未知域 404 ----
expect_code 404 GET /sync/nonsense "" "$TOKEN"
step "未知域 → 404"

echo "ALL PASS ($PASS_STEPS steps, user=$USERNAME)"
