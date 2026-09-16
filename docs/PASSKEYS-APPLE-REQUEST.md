# 向 Apple 申请浏览器 Passkey 权限（申请材料模板）

## 申请入口

<https://developer.apple.com/contact/request/macos-browsers-passkeys>

Capability 名称：**Web Browser Public Key Credential Requests**
Entitlement 键：`com.apple.developer.web-browser.public-key-credential`
适用平台：macOS；团队类型：Apple Developer Program

## 需要准备的信息

| 字段 | 你的值 |
|------|--------|
| App 名称 | Desire |
| Bundle ID | `me.siwi.Desire` |
| Team ID | `F8JZTX6J52` |
| 平台 | macOS |
| 用途 | 浏览器（WebKit/WKWebView 实现）为任意网站提供 passkey 登录 |

## 英文说明模板（可直接粘贴到表单描述栏）

> Desire is a native macOS web browser built on WebKit/WKWebView. It renders
> arbitrary websites for the user, so it must be able to perform WebAuthn
> registration and assertion requests for **any** relying party identifier —
> exactly what the Web Browser Public Key Credential Requests entitlement
> enables.
>
> Without the entitlement, macOS suppresses the system passkey authorization
> sheet for our process (AuthenticationServices returns
> `ASAuthorizationError.notInteractive`, code 1004), and relying parties such
> as Google report "this browser reports partial passkey support". Users
> therefore cannot sign in with passkeys that are already stored on their Mac.
>
> The app is a general-purpose browser, not a credential manager: it does not
> store, export, or transmit passkeys itself. WebAuthn requests are handled by
> WebKit and surfaced through Apple's own system UI; the user's passkeys remain
> in iCloud Keychain / their chosen passkey provider. We ask for the
> entitlement solely so that standard website sign-in works, matching Safari's
> behavior for the same sites.

## 拿到授权后的操作

1. Apple Developer 后台 → Identifiers → App ID `me.siwi.Desire` → 勾选
   *Web Browser Public Key Credential Requests* → 保存。
2. 重新生成 / 更新 Development 与 Distribution provisioning profile。
3. 取消 `Desire/App/Desire.entitlements` 中的注释：

   ```xml
   <key>com.apple.developer.web-browser.public-key-credential</key>
   <true/>
   ```

4. 构建并验证：
   - 设置 → 隐私 → Passkeys：*Web browser entitlement* 显示 **Granted**；
   - 点击 *Allow…* 弹出系统同意框；
   - 访问 Google 账号 → 使用 passkey 登录，系统面板出现且可完成。

## 审核可能的追问与应答要点

- **"为什么不能只用 WebKit 默认行为？"**
  同一份 WebAuthn 流程在 Safari 中可用、在第三方 WKWebView 宿主中不可用，差异就是这个 entitlement；
  它是 Apple 对"哪些应用可以代表用户发起任意 RP 的凭证请求"的控制点。
- **"你们如何处理用户凭据？"**
  不接触。WebAuthn 请求由 WebKit 发起、系统 UI 完成，私钥不离开平台认证器；
  应用不存储、不导出、不转发任何 passkey 材料。
- **"有滥用风险吗？"**
  请求均由页面 `navigator.credentials` 触发，且必须经过用户在场确认（Touch ID / 系统面板）；
  应用无法静默使用凭据。
