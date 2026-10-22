# 稳定代码签名（Keychain 零反复授权）

## 为什么

Release 目前是 **adhoc/linker-signed**：macOS 的 Keychain ACL 把条目绑定到
designated requirement，而 adhoc 的 requirement 是 **cdhash**——每次发新构建
cdhash 都变，用户升级后第一次读 `app-secrets-v1` 仍可能被要求授权一次。

用一张**固定的代码签名证书**（self-signed 即可）签名后，designated requirement
变成：

```
identifier "me.siwi.Desire" and certificate root = H"…"
```

跨构建稳定。用户第一次点“始终允许”后，后续升级不再弹。它**不改变 Gatekeeper
现状**（仍不是 notarized/Developer ID，安装仍需 `xattr -cr`），只解决 Keychain ACL。

## 一次性生成 + 上传 secrets

```bash
# 在仓库根（或任意目录）生成：证书/私钥/p12/随机口令
bash scripts/setup-signing.sh

# 按输出提示把 4 个 secrets 写入 GitHub（私钥只进 secrets，不进仓库）
gh secret set MACOS_SIGNING_P12 --body "$(base64 < DesireLocalSigning/DesireLocalSigning.p12 | tr -d '\n')" --repo browser-rs/Desire
gh secret set MACOS_SIGNING_PASSWORD --body "$(cat DesireLocalSigning/p12-password.txt)" --repo browser-rs/Desire
gh secret set MACOS_SIGNING_KEYCHAIN_PASSWORD --body "$(cat DesireLocalSigning/keychain-password.txt)" --repo browser-rs/Desire
gh secret set MACOS_SIGNING_IDENTITY --body "Desire Local Signing" --repo browser-rs/Desire
```

上传后删除/移出 `DesireLocalSigning/`（脚本默认输出目录已被 `.gitignore` 忽略）。
**不要**把 p12、key.pem 或口令提交到仓库。

## CI 行为

`release.yml` 的两个架构构建在版本校验后执行 `scripts/sign-app.sh "$APP"`：

- `MACOS_SIGNING_P12` 存在 → 建临时 keychain、导入 p12、`codesign --force --deep
  --options runtime --timestamp=none`，随后 `codesign --verify`；
- secrets 缺失 → 打印 "leaving app unsigned (adhoc)"，保持旧行为，不阻塞发版。

CI（push 触发的零警告构建）不签名，仍用 `CODE_SIGNING_ALLOWED=NO`。

## 本地验证过的事实

- `openssl pkcs12 -export -legacy` 生成的 p12 才能被 macOS `security import` 接受
  （OpenSSL 3 默认的强加密会报 MAC verification failed）；脚本已带 `-legacy`。
- 同一证书对两份 app 副本分别签名，designated requirement 完全一致：
  `identifier "me.siwi.Desire" and certificate root = H"cf7d…"`；`codesign --verify
  --deep --strict` 通过。
- 测试证书只放在 `/tmp`，没有进入登录 keychain 或仓库。

## 回退

删掉 GitHub secrets 后，release.yml 自动回到 unsigned/adhoc 行为；已安装的旧签名
证书不影响现有条目（新构建只是重新走一次 ACL 授权）。
