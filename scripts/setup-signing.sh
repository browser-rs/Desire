#!/bin/bash
# setup-signing.sh — 生成一个**稳定的本地代码签名 identity**，用于解决
# adhoc 构建每次换 cdhash 导致 Keychain ACL 每次安装都问一次的问题。
#
# 它只生成文件并打印 GitHub secrets 命令，**不会自动上传私钥**；是否把
# .p12 放进 GitHub secrets 由你决定（仓库是公开的，secrets 本身不可读，
# 但任何有 write 权限的人都能触发签名构建）。
#
# 用法：
#   bash scripts/setup-signing.sh                 # 生成到 ./DesireLocalSigning/
#   bash scripts/setup-signing.sh --out /tmp/sg   # 指定目录
#   bash scripts/setup-signing.sh --sign-app /path/to/Desire.app
#       # 额外用临时 keychain 给一个本地 app 签名（测试 identity 是否可用）
#
# 生成物：
#   cert.pem / key.pem                 （证书/私钥；私钥不要进仓库）
#   DesireLocalSigning.p12             （导入 GitHub Actions 的签名身份）
#   p12-password.txt / keychain-password.txt
#   env.sh                             （变量：IDENTITY / P12_PATH / 密码）
#
# 上传 secrets（在仓库根执行，按提示替换路径）：
#   gh secret set MACOS_SIGNING_P12 --body "$(base64 < DesireLocalSigning/DesireLocalSigning.p12 | tr -d '\n')" --repo browser-rs/Desire
#   gh secret set MACOS_SIGNING_PASSWORD --body "$(cat DesireLocalSigning/p12-password.txt)" --repo browser-rs/Desire
#   gh secret set MACOS_SIGNING_KEYCHAIN_PASSWORD --body "$(cat DesireLocalSigning/keychain-password.txt)" --repo browser-rs/Desire
#   gh secret set MACOS_SIGNING_IDENTITY --body "Desire Local Signing" --repo browser-rs/Desire
#
# 上传后删除 p12/key/password 文件（或至少移出仓库并妥善保管：以后换证书要重新上传）。
set -euo pipefail

OUT="DesireLocalSigning"
SIGN_APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --sign-app) SIGN_APP="$2"; shift 2 ;;
    -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

command -v openssl >/dev/null || { echo "openssl not found"; exit 1; }
command -v security >/dev/null || { echo "security not found"; exit 1; }
IDENTITY="Desire Local Signing"

mkdir -p "$OUT"
chmod 700 "$OUT"
cd "$OUT"

if [ -f DesireLocalSigning.p12 ]; then
  echo "DesireLocalSigning.p12 already exists in $PWD — refusing to overwrite."
  echo "Move it away first if you want a new identity."
  exit 1
fi

P12_PASS="$(openssl rand -hex 18)"
KC_PASS="$(openssl rand -hex 18)"

cat > openssl.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = Desire Local Signing
O = Desire
C = US
[ v3 ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout key.pem -out cert.pem -config openssl.cnf >/dev/null 2>&1
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem \
  -name "$IDENTITY" -out DesireLocalSigning.p12 \
  -passout "pass:$P12_PASS" >/dev/null 2>&1

chmod 600 key.pem DesireLocalSigning.p12
printf '%s\n' "$P12_PASS" > p12-password.txt
printf '%s\n' "$KC_PASS" > keychain-password.txt
chmod 600 p12-password.txt keychain-password.txt
cat > env.sh <<EOF
export IDENTITY="$IDENTITY"
export P12_PATH="$PWD/DesireLocalSigning.p12"
export P12_PASSWORD="$P12_PASS"
export KEYCHAIN_PASSWORD="$KC_PASS"
EOF
chmod 600 env.sh

echo "Generated stable identity in: $PWD"
echo "  CN=$IDENTITY"
echo
echo "GitHub secrets (run from repo root, never commit the p12/key/password):"
echo "  gh secret set MACOS_SIGNING_P12 --body \"\$(base64 < \"$PWD/DesireLocalSigning.p12\" | tr -d '\\n')\" --repo browser-rs/Desire"
echo "  gh secret set MACOS_SIGNING_PASSWORD --body \"\$(cat \"$PWD/p12-password.txt\")\" --repo browser-rs/Desire"
echo "  gh secret set MACOS_SIGNING_KEYCHAIN_PASSWORD --body \"\$(cat \"$PWD/keychain-password.txt\")\" --repo browser-rs/Desire"
echo "  gh secret set MACOS_SIGNING_IDENTITY --body \"$IDENTITY\" --repo browser-rs/Desire"
echo
echo "After uploading, delete/move the p12 + key + password files. Keep them if you"
echo "want to sign local builds with the same identity:"
echo "  security create-keychain -p \"\$(cat \"$PWD/keychain-password.txt\")\" desire-signing.keychain-db"
echo "  security import \"$PWD/DesireLocalSigning.p12\" -k desire-signing.keychain-db -P \"\$(cat \"$PWD/p12-password.txt\")\" -T /usr/bin/codesign"
echo "  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \"\$(cat \"$PWD/keychain-password.txt\")\" desire-signing.keychain-db"

if [ -n "$SIGN_APP" ]; then
  [ -d "$SIGN_APP" ] || { echo "app not found: $SIGN_APP"; exit 1; }
  KC="desire-signing-$(date +%s).keychain-db"
  security create-keychain -p "$KC_PASS" "$KC"
  security set-keychain-settings -lut 21600 "$KC"
  security unlock-keychain -p "$KC_PASS" "$KC"
  security import "$PWD/DesireLocalSigning.p12" -k "$KC" -P "$P12_PASS" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null
  codesign --force --deep --options runtime --timestamp=none \
    --keychain "$KC" --sign "$IDENTITY" "$SIGN_APP"
  codesign --verify --deep --strict --verbose=2 "$SIGN_APP"
  echo "Designated requirement:"
  codesign -d -r- "$SIGN_APP" 2>&1 | sed -n '1,3p'
  security delete-keychain "$KC" || true
fi
