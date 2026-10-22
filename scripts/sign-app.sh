#!/bin/bash
# sign-app.sh — 在 CI 里用稳定的 self-signed identity 给 Desire.app 重新签名。
#
# 目的：adhoc 构建的 designated requirement 是 cdhash，每次发布都变，Keychain
# ACL 认不出当前构建 → 每次安装读 app-secrets-v1 都要授权一次。用固定证书
# 签名后 designated requirement 变成
#   identifier "me.siwi.Desire" and certificate root = H"…"
# 跨版本稳定，用户点一次"始终允许"后后续升级不再弹。
#
# 输入（GitHub Actions secrets，缺省则跳过签名、保持现有 adhoc 行为）：
#   MACOS_SIGNING_P12                 base64 的 .p12（identity + 私钥）
#   MACOS_SIGNING_PASSWORD            .p12 口令
#   MACOS_SIGNING_KEYCHAIN_PASSWORD   临时 keychain 口令（随机即可）
#   MACOS_SIGNING_IDENTITY            证书 CN，默认 "Desire Local Signing"
#
# 用法：bash scripts/sign-app.sh /path/to/Desire.app
set -euo pipefail

APP="${1:?usage: sign-app.sh /path/to/Desire.app}"
[ -d "$APP" ] || { echo "::error::app not found: $APP"; exit 1; }

if [ -z "${MACOS_SIGNING_P12:-}" ]; then
  echo "No MACOS_SIGNING_P12 secret — leaving app unsigned (adhoc) as before."
  exit 0
fi
: "${MACOS_SIGNING_PASSWORD:?MACOS_SIGNING_PASSWORD missing}"
: "${MACOS_SIGNING_KEYCHAIN_PASSWORD:?MACOS_SIGNING_KEYCHAIN_PASSWORD missing}"
IDENTITY="${MACOS_SIGNING_IDENTITY:-Desire Local Signing}"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
KC="$TMP/desire-signing.keychain-db"
P12="$TMP/desire-signing.p12"

cleanup() {
  security delete-keychain "$KC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

security delete-keychain "$KC" >/dev/null 2>&1 || true
security create-keychain -p "$MACOS_SIGNING_KEYCHAIN_PASSWORD" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$MACOS_SIGNING_KEYCHAIN_PASSWORD" "$KC"

printf '%s' "$MACOS_SIGNING_P12" | base64 -D > "$P12"
security import "$P12" -k "$KC" -P "$MACOS_SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$MACOS_SIGNING_KEYCHAIN_PASSWORD" "$KC" >/dev/null

codesign --force --deep --options runtime --timestamp=none \
  --keychain "$KC" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signed with identity: $IDENTITY"
codesign -d -r- "$APP" 2>&1 | sed -n '1,3p'
