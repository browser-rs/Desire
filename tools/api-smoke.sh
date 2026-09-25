#!/usr/bin/env bash
# desire-api 全链路冒烟:前置 = api 已在本机运行(见 AGENTS.md 后端章节)。
# 用法:tools/api-smoke.sh [BASE_URL]   (默认 http://127.0.0.1:18090)
# 覆盖:health / register / 重复注册 409 / login / 错密码 401 / refresh 轮换
#       + 旧 token 重放 401 / me / 改资料 / 改密码+新密码登录 / 设备列表 /
#       吊销设备(吊销后 refresh 401、重新登录恢复) / logout / logout 后 refresh 401
# 注意:macOS 自带 bash 3.2 对 $() 内嵌 \" 的解析有毛病——
#       JSON 一律先入变量,再传给请求函数,别在 $() 里内联带引号的字面量。
set -euo pipefail

BASE="${1:-http://127.0.0.1:18090}"
USERNAME="smoke_$(date +%s)"
PASS1="smoke-pass-123"
PASS2="smoke-pass-456"
DEVICE_ID="smoke-device-$(date +%s)"

PASS_STEPS=0
step() { PASS_STEPS=$((PASS_STEPS+1)); echo "ok $PASS_STEPS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# 从响应 JSON 里按点路径取值:get data.access_token / get data.0.device_id
get() {
  python3 -c '
import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v[int(k)] if isinstance(v, list) else v[k]
print(v)
' "$1"
}

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

expect_code() { # expect_code <want> <method> <path> [json] [token]
  local want=$1
  shift
  local got
  got=$(code "$@")
  [ "$got" = "$want" ] || fail "期望 HTTP $want 实得 '$got'"
}

# ---- health ----
expect_code 200 GET /health
step "GET /health"

# ---- register ----
REG_BODY="{\"username\":\"$USERNAME\",\"password\":\"$PASS1\",\"device\":{\"device_id\":\"$DEVICE_ID\",\"name\":\"Smoke Mac\",\"platform\":\"macOS\"}}"
R=$(req POST /auth/register "$REG_BODY")
ACCESS=$(echo "$R" | get data.access_token)
REFRESH=$(echo "$R" | get data.refresh_token)
[ -n "$ACCESS" ] && [ -n "$REFRESH" ] || fail "register 响应缺 token: $R"
step "register + 发 token"

DUP_BODY="{\"username\":\"$USERNAME\",\"password\":\"$PASS1\"}"
expect_code 409 POST /auth/register "$DUP_BODY"
step "重复注册 → 409"

# ---- 弱口令 → 422（8-72 位且字母+数字）----
WEAK_BODY="{\"username\":\"weak_$USERNAME\",\"password\":\"12345678\"}"
expect_code 422 POST /auth/register "$WEAK_BODY"
step "纯数字弱口令注册 → 422"

# ---- login ----
BAD_LOGIN_BODY="{\"username\":\"$USERNAME\",\"password\":\"wrong-pass\"}"
expect_code 401 POST /auth/login "$BAD_LOGIN_BODY"
LOGIN_BODY="{\"username\":\"$USERNAME\",\"password\":\"$PASS1\",\"device\":{\"device_id\":\"$DEVICE_ID\"}}"
R=$(req POST /auth/login "$LOGIN_BODY")
echo "$R" | get data.access_token > /dev/null || fail "login 失败: $R"
step "错密码 → 401;正确登录 → token"

# ---- refresh 轮换 + 重放拒绝 ----
R=$(req POST /auth/refresh "{\"refresh_token\":\"$REFRESH\"}")
ACCESS2=$(echo "$R" | get data.access_token)
REFRESH2=$(echo "$R" | get data.refresh_token)
[ -n "$ACCESS2" ] && [ "$REFRESH2" != "$REFRESH" ] || fail "refresh 应轮换出新 token 对: $R"
REPLAY_BODY="{\"refresh_token\":\"$REFRESH\"}"
expect_code 401 POST /auth/refresh "$REPLAY_BODY"
step "refresh 轮换;旧 token 重放 → 401"

# ---- me / 资料 ----
ME=$(req GET /auth/me "" "$ACCESS2")
[ "$(echo "$ME" | get data.username)" = "$USERNAME" ] || fail "me.username 不符: $ME"
UPD_BODY="{\"nickname\":\"冒烟昵称\",\"email\":\"${USERNAME}@example.com\"}"
R=$(req PUT /auth/me "$UPD_BODY" "$ACCESS2")
[ "$(echo "$R" | get data.nickname)" = "冒烟昵称" ] || fail "改昵称失败: $R"
step "GET /auth/me;PUT /auth/me 改昵称+邮箱"

# ---- 改密码 + 新密码登录 ----
WRONG_PW_BODY="{\"old_password\":\"wrong\",\"new_password\":\"$PASS2\"}"
expect_code 401 PUT /auth/password "$WRONG_PW_BODY" "$ACCESS2"
req PUT /auth/password "{\"old_password\":\"$PASS1\",\"new_password\":\"$PASS2\"}" "$ACCESS2" > /dev/null
NEW_LOGIN_BODY="{\"username\":\"$USERNAME\",\"password\":\"$PASS2\"}"
R=$(req POST /auth/login "$NEW_LOGIN_BODY")
echo "$R" | get data.access_token > /dev/null || fail "新密码登录失败: $R"
step "改密码:旧密码错 → 401;改后新密码可登录"

# ---- 设备 ----
R=$(req GET /auth/devices "" "$ACCESS2")
[ "$(echo "$R" | get "data.0.device_id")" = "$DEVICE_ID" ] || fail "设备列表缺刚登记的设备: $R"
req POST /auth/devices/revoke "{\"device_id\":\"$DEVICE_ID\"}" "$ACCESS2" > /dev/null
R=$(req GET /auth/devices "" "$ACCESS2")
[ "$(echo "$R" | get "data.0.revoked")" = "True" ] || fail "吊销后 revoked 应为 true: $R"
expect_code 401 POST /auth/refresh "$REPLAY_BODY"
RELOGIN_BODY="{\"username\":\"$USERNAME\",\"password\":\"$PASS2\",\"device\":{\"device_id\":\"$DEVICE_ID\"}}"
R=$(req POST /auth/login "$RELOGIN_BODY")
echo "$R" | get data.access_token > /dev/null || fail "同设备重新登录应恢复: $R"
step "设备列表 / 吊销(其后 refresh 401) / 同设备重登录恢复"

# ---- logout ----
REFRESH3=$(req POST /auth/login "$NEW_LOGIN_BODY" | get data.refresh_token)
req POST /auth/logout "{\"refresh_token\":\"$REFRESH3\"}" > /dev/null
LOGOUT_BODY="{\"refresh_token\":\"$REFRESH3\"}"
expect_code 401 POST /auth/refresh "$LOGOUT_BODY"
step "logout;其后再 refresh → 401"

echo "ALL PASS ($PASS_STEPS steps, user=$USERNAME)"
