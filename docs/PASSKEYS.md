# Passkey（WebAuthn）支持调研与启用指南

**当前状态：暂不支持（代码已移除，等待 Apple 授权后按本文档重建）。**

原因：浏览器的 passkey 能力受 Apple 逐团队授权的 entitlement 门禁控制，未获授权时网站 passkey 登录必然失败。
本文档保留完整调研结论、失败证据与参考实现，拿到授权后照此重建即可。

---

## 一、结论先行

- **WebAuthn 由 WebKit 在 WKWebView 内部实现**，页面调用 `navigator.credentials` 时由 WebKit 处理；
  WebKit 公开的凭证错误码（`WKErrorCredentialNotFound` / `WKErrorDuplicateCredential` /
  `WKErrorMalformedCredential`，macOS 13+）即为证据。
- **为任意网站（任意 RP ID）发起 passkey 请求需要 entitlement**：
  `com.apple.developer.web-browser.public-key-credential`
  （capability `WEB_BROWSER_PUBLIC_KEY_CREDENTIALS_REQUESTS`）。
- 该能力 **不能在 Xcode 中勾选**（能力库 `editable: false`、`isPublic: false`），
  只能通过官方表单申请，由 provisioning profile 下发。
- 申请入口：<https://developer.apple.com/contact/request/macos-browsers-passkeys>
- 未获授权时把键写入 `Desire.entitlements` 会导致**签名失败**：
  `No profiles for 'me.siwi.Desire' were found`。故当前 entitlements 文件中不含该键。

## 二、未授权时的失败现场（实测证据）

在未获 entitlement 的构建中访问支持 passkey 的站点（如 Google 账号），系统日志：

```
Told not to present authorization sheet:
  Error Domain=com.apple.AuthenticationServicesCore.AuthorizationError Code=1
ASAuthorizationController credential request failed with error:
  Error Domain=com.apple.AuthenticationServices.AuthorizationError Code=1004
```

站点侧报：`This browser or device is reporting partial passkey support. Authentication failed.`

解读：

- `AuthorizationError 1004` = `notInteractive`（需要用户交互，但当前不允许）；
- 根因是前一行：**AuthenticationServices 被告知不要弹出授权面板**——进程缺少浏览器 passkey entitlement；
- 面板被压制 → 请求失败 → 站点探测到能力不完整 → 报 "partial passkey support" 并中止。

**这不是应用代码缺陷，而是系统级门禁。** 平台 passkey 与安全密钥同样受限，无绕过方案。
Safari 可登录同一账号，因其持有 Apple 自身授权。

构建时另一类日志（与本问题无关，属正常噪音）：

```
Handle connection with error: Connection invalid
Encountered xpc error for GetSafeBrowsingEnabledState response ...
checkRichAnalysisAvailability XPC failed: ... Sandbox restriction
```

## 三、环境实测数据（macOS 26.5）

脚本探测 `ASAuthorizationWebBrowserPublicKeyCredentialManager`：

```
isDeviceConfiguredForPasskeys: true       // 该 Mac 已配置 passkey
authorizationState raw: 2 (notDetermined) // 尚未向用户请求授权
```

结论：API 可用、设备就绪，缺的只有 entitlement 与用户同意。

同时确认 **`WKPreferences` 没有任何 WebAuthn 开关**（`webAuthnEnabled` / `isWebAuthnEnabled` /
`_webAuthnEnabled` 等命名均不响应），即开关不由应用代码控制。

## 四、启用步骤

1. 提交申请（材料模板见 [PASSKEYS-APPLE-REQUEST.md](PASSKEYS-APPLE-REQUEST.md)）。
2. 授权通过后，Apple Developer 后台给 App ID `me.siwi.Desire` 勾选
   *Web Browser Public Key Credential Requests*，重新生成 provisioning profile。
3. 在 `Desire/App/Desire.entitlements` 中加入：

   ```xml
   <key>com.apple.developer.web-browser.public-key-credential</key>
   <true/>
   ```

4. 按第五节重建代码，构建验证。

## 五、参考实现（已移除，可直接复用）

### 1. Store：`Desire/Features/Passkeys/PasskeySupport.swift`

```swift
import AuthenticationServices
import Combine
import Foundation
import Security

@MainActor
final class PasskeySupport: ObservableObject {
    enum AccessState: Equatable { case notDetermined, authorized, denied }

    @Published private(set) var accessState: AccessState = .notDetermined
    @Published private(set) var isDeviceConfigured = false
    @Published private(set) var isRequesting = false
    @Published private(set) var lastError: String?

    /// 是否携带 Apple 的浏览器 passkey entitlement（ad-hoc/未签名构建恒为 false）。
    let hasBrowserEntitlement: Bool

    private let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()

    init() {
        hasBrowserEntitlement = Self.readBrowserEntitlement()
        refresh()
    }

    func refresh() {
        isDeviceConfigured = ASAuthorizationWebBrowserPublicKeyCredentialManager.isDeviceConfiguredForPasskeys
        accessState = Self.map(manager.authorizationStateForPlatformCredentials)
    }

    func requestAccess() async {
        guard hasBrowserEntitlement else {
            lastError = String(localized: "Passkey access needs Apple's Web Browser Public Key Credential entitlement.")
            return
        }
        isRequesting = true
        defer { isRequesting = false }
        let state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState =
            await withCheckedContinuation { continuation in
                manager.requestAuthorizationForPublicKeyCredentials { state in
                    continuation.resume(returning: state)
                }
            }
        accessState = Self.map(state)
        lastError = nil
    }

    private static func map(
        _ state: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState
    ) -> AccessState {
        switch state {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// 通过代码签名读取自身 entitlement（Security 框架公开 API）。
    private static func readBrowserEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                  task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
              ) else { return false }
        return (value as? Bool) ?? false
    }
}
```

### 2. 设置区段（`Settings → Privacy` 内插入）

`PasskeysSection`：三行状态——设备是否已配置 passkey（`isDeviceConfigured`）、
浏览器授权状态（`accessState` + `requestAccess()` 按钮）、entitlement 状态
（`hasBrowserEntitlement` 为 false 时给出 Apple 申请链接）。
使用现成组件 `SettingsSection` / `SettingsRow` / `SettingsRowDivider` / `StatusPill`（`kind:` 参数）。

关键提示文案（未获授权时必须展示，否则用户只会看到站点报错）：

> Until Apple grants this, passkey sign-in on websites fails with "partial passkey support"
> — macOS suppresses the system authorization sheet for apps without the grant.

### 3. AI 提示词（可选）

在默认系统提示词中加入：

> 遇到 passkey / Touch ID / 指纹 / 面容登录时：系统级弹窗需用户本人在场确认，不要尝试代点，
> 提示用户"请在系统弹窗中确认登录"。

## 六、验证清单（拿到授权后）

- [ ] 设置 → 隐私 → Passkeys：Device 显示 *Ready*
- [ ] entitlement 授予后 *Web browser entitlement* 显示 *Granted*，授权按钮可用
- [ ] 点击 *Allow…* 弹出系统同意框，同意后状态变为 *Authorized*
- [ ] 访问 Google 账号 → 使用 passkey 登录，系统面板出现并可完成
- [ ] AI 面板：让 AI 打开 passkey 登录页，确认它提示用户手动确认而非代点

## 七、其他备注

- WebAuthn 仅在本源为安全上下文（HTTPS）时可用；应用已默认开启 HTTPS 自动升级。
- 容器标签页使用独立 `WKWebsiteDataStore`，但 passkey 是系统级凭据，不随站点数据存储：
  容器隔离不影响 passkey，清站点数据也不会删除系统 passkey。
- Touch ID 提示由系统在 WebAuthn 流程中自行弹出，应用层无法绕过或模拟。
