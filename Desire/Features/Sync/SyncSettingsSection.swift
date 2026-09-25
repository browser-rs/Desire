import AppKit
import SwiftUI

/// 设置 → Sync：登录/注册 + 同步状态 + 立即同步/退出。
/// 组合根（SettingsView）注入共享 SyncStore；本视图零业务逻辑，认证与同步
/// 全部走 store 方法，错误展示用 store.lastError（登录失败是同步态的属性）。
struct SyncSettingsSection: View {
    @ObservedObject var store: SyncStore

    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var formError: String?
    @State private var serverURL = ""
    @State private var serverSaved = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var pwWorking = false
    @State private var pwError: String?
    @State private var pwSaved = false
    @State private var importedKey = ""
    @State private var keyWorking = false
    @State private var captchaInput = ""
    @State private var captchaLoading = false
    @State private var keyError: String?
    @State private var keyCopied = false

    var body: some View {
        SettingsContainer {
            switch store.authState {
            case .signedOut:
                signedOut
            case .signedIn(let account):
                signedIn(account)
            }
            serverSection
        }
        .onAppear {
            serverURL = store.serverBaseURL
        }
    }

    // MARK: - 未登录：登录 / 注册表单

    enum AuthMode { case signIn; case register }

    @State private var mode: AuthMode = .signIn
    @State private var confirmPassword = ""
    @State private var showPassword = false

    @ViewBuilder
    private var signedOut: some View {
        SettingsSection(
            title: "Sync",
            subtitle: "Sign in to keep your bookmarks up to date across devices.",
            icon: "arrow.triangle.2.circlepath"
        ) {
            VStack(spacing: 0) {
                SettingsRow("Mode") {
                    Picker("", selection: $mode) {
                        Text(localizedSettingText("Sign In")).tag(AuthMode.signIn)
                        Text(localizedSettingText("Register")).tag(AuthMode.register)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }
                .onChange(of: mode) {
                    formError = nil
                    confirmPassword = ""
                    if mode == .register && store.captcha == nil {
                        captchaLoading = true
                        Task { @MainActor in
                            await store.loadCaptcha()
                            captchaLoading = false
                        }
                    }
                }
                SettingsRowDivider()
                SettingsRow("Username", subtitle: mode == .register ? localizedSettingText("Usernames start with a letter and use 3-32 letters, digits or underscores.") : nil) {
                    SettingsTextField(placeholder: "username", text: $username, width: 200)
                }
                SettingsRowDivider()
                SettingsRow("Password", subtitle: mode == .register ? localizedSettingText("At least 8 characters with letters and numbers.") : nil) {
                    HStack(spacing: 6) {
                        SettingsTextField(
                            placeholder: "••••••••",
                            text: $password,
                            isSecure: !showPassword,
                            width: 170
                        )
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if mode == .register {
                    SettingsRowDivider()
                    SettingsRow("Confirm Password", subtitle: confirmError) {
                        SettingsTextField(
                            placeholder: "••••••••",
                            text: $confirmPassword,
                            isSecure: true,
                            width: 170
                        )
                    }
                    SettingsRowDivider()
                    captchaRow
                    if !password.isEmpty {
                        SettingsRowDivider()
                        strengthRow
                    }
                }
                SettingsRowDivider()
                SettingsRow("Account", subtitle: formError) {
                    SettingsCapsuleButton(
                        mode == .signIn ? "Sign In" : "Register",
                        isDisabled: !canSubmit || isWorking
                    ) { submit() }
                }
            }
        }
    }

    // MARK: - 表单校验（镜像服务端规则，提前给出反馈；服务端仍是权威）

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespaces)
    }

    private var usernameValid: Bool {
        let t = trimmedUsername
        guard (3...32).contains(t.count), let first = t.first, first.isASCII, first.isLetter else {
            return false
        }
        return t.dropFirst().allSatisfy {
            ($0.isASCII && $0.isLetter) || ($0.isASCII && $0.isNumber) || $0 == "_"
        }
    }

    private var passwordValid: Bool {
        guard (8...72).contains(password.count) else { return false }
        return password.contains(where: { $0.isLetter }) && password.contains(where: { $0.isNumber })
    }

    private var confirmMatches: Bool {
        !confirmPassword.isEmpty && confirmPassword == password
    }

    private var confirmError: String? {
        guard mode == .register, !confirmPassword.isEmpty, confirmPassword != password else {
            return nil
        }
        return localizedSettingText("Passwords do not match.")
    }

    private var canSubmit: Bool {
        guard !isWorking else { return false }
        switch mode {
        case .signIn:
            return !trimmedUsername.isEmpty && !password.isEmpty
        case .register:
            return usernameValid && passwordValid && confirmMatches && captchaInput.count >= 4
        }
    }

    @ViewBuilder
    private var captchaRow: some View {
        SettingsRow("Verification Code") {
            HStack(spacing: 8) {
                if captchaLoading {
                    ProgressView().controlSize(.small)
                } else if let png = store.captcha?.pngData, let nsImage = NSImage(data: png) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 36)
                        .cornerRadius(4)
                } else {
                    Text(localizedSettingText("Failed to load"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button {
                    captchaLoading = true
                    Task { @MainActor in
                        await store.loadCaptcha()
                        captchaLoading = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var strengthRow: some View {
        let score = strengthScore(password)
        return SettingsRow("Password strength") {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index < score ? strengthColor(score) : Color.secondary.opacity(0.18))
                        .frame(width: 18, height: 4)
                }
                Text(localizedSettingText(strengthLabel(score)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 0-3：长度 ≥8 / 字母数字混用 / 长度 ≥12。仅提示用，服务端仍是权威。
    private func strengthScore(_ password: String) -> Int {
        var score = 0
        if password.count >= 8 { score += 1 }
        let hasLetter = password.contains(where: { $0.isLetter })
        let hasDigit = password.contains(where: { $0.isNumber })
        if hasLetter && hasDigit { score += 1 }
        if password.count >= 12 { score += 1 }
        return score
    }

    private func strengthColor(_ score: Int) -> Color {
        switch score {
        case 0: .red
        case 1: .orange
        case 2: .yellow
        default: .green
        }
    }

    private func strengthLabel(_ score: Int) -> String {
        switch score {
        case 0: "Weak"
        case 1: "Fair"
        case 2: "Good"
        default: "Strong"
        }
    }

    private func submit() {
        isWorking = true
        formError = nil
        Task { @MainActor in
            do {
                switch mode {
                case .signIn:
                    try await store.login(username: username, password: password)
                case .register:
                    try await store.register(username: username, password: password,
                                             captchaCode: captchaInput)
                }
                password = ""
                confirmPassword = ""
                captchaInput = ""
            } catch {
                formError = error.localizedDescription
                if mode == .register { await store.loadCaptcha() } // 验证码已被消费或作废
            }
            isWorking = false
        }
    }

    // MARK: - 已登录：状态 + 操作

    @ViewBuilder
    private func signedIn(_ account: String) -> some View {
        SettingsContainer {
            SettingsSection(
                title: "Sync",
                subtitle: "Bookmarks sync automatically every 5 minutes and at launch.",
                icon: "arrow.triangle.2.circlepath"
            ) {
                VStack(spacing: 0) {
                    SettingsRow("Account", subtitle: account) {
                        if store.isSyncing {
                            StatusPill(text: localizedSettingText("Syncing…"), kind: .info)
                        } else {
                            StatusPill(text: localizedSettingText("Signed in"), kind: .success)
                        }
                    }
                    SettingsRowDivider()
                    SettingsRow("Last Sync", subtitle: lastSyncText) {
                        SettingsCapsuleButton(
                            "Sync Now",
                            isDisabled: store.isSyncing
                        ) {
                            isWorking = true
                            Task {
                                await store.syncNow()
                                isWorking = false
                            }
                        }
                    }
                    if let error = store.lastError {
                        SettingsRowDivider()
                        SettingsRow("Sync Error", subtitle: error) {
                            EmptyView()
                        }
                    }
                    SettingsRowDivider()
                    SettingsActionRow(
                        "Device",
                        subtitle: "Sign out on this Mac. Synced data stays on the server.",
                        buttonTitle: "Sign Out",
                        isDestructive: true
                    ) {
                        store.logout()
                        password = ""
                        currentPassword = ""
                        newPassword = ""
                        pwSaved = false
                    }
                }
            }
            keySection
            passwordSection
            categoriesSection
            serverSection
        }
    }

    // MARK: - 同步密钥（E2E 加密）

    @ViewBuilder
    private var keySection: some View {
        SettingsSection(
            title: "Sync Key",
            subtitle: "End-to-end encrypted: your data is encrypted with this key before it leaves this Mac. The server can never read it.",
            icon: "key.fill"
        ) {
            VStack(spacing: 0) {
                if store.hasSyncKey {
                    SettingsRow("Key Fingerprint", subtitle: store.syncKeyFingerprint) {
                        SettingsCapsuleButton("Copy Sync Key", style: .secondary) {
                            if let key = store.revealSyncKey() {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(key, forType: .string)
                                keyCopied = true
                            }
                        }
                    }
                    SettingsRowDivider()
                    SettingsRow("Copy Sync Key", subtitle: keyCopied ? localizedSettingText("Copied") : nil) {
                        EmptyView()
                    }
                } else {
                    SettingsRow("Sync Key") {
                        SettingsTextField(
                            placeholder: "Paste the base64 key from another device.",
                            text: $importedKey,
                            width: 240
                        )
                    }
                    SettingsRowDivider()
                    SettingsRow("Sync Key", subtitle: keyError) {
                        HStack(spacing: 8) {
                            SettingsCapsuleButton(
                                "Generate New Key",
                                isDisabled: keyWorking
                            ) { runKeyFlow(importText: nil) }
                            SettingsCapsuleButton(
                                "Import Key",
                                style: .secondary,
                                isDisabled: importedKey.trimmingCharacters(in: .whitespaces).isEmpty || keyWorking
                            ) { runKeyFlow(importText: importedKey) }
                        }
                    }
                }
            }
        }
    }

    private func runKeyFlow(importText: String?) {
        keyWorking = true
        keyError = nil
        keyCopied = false
        Task { @MainActor in
            do {
                if let importText {
                    try store.importSyncKey(importText)
                } else {
                    let key = try store.generateSyncKey()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    keyCopied = true
                }
                try await store.uploadKeyCheck()
            } catch {
                keyError = error.localizedDescription
            }
            keyWorking = false
        }
    }

    // MARK: - 同步类目

    @ViewBuilder
    private var categoriesSection: some View {
        SettingsSection(
            title: "Sync Categories",
            subtitle: "Choose what to sync across devices. Turning one off keeps its server data.",
            icon: "checklist"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(SyncDomain.allCases.enumerated()), id: \.element) { index, domain in
                    if index > 0 { SettingsRowDivider() }
                    SettingsToggleRow(
                        localizedSettingText(domainTitle(domain)),
                        isOn: Binding(
                            get: { store.isEnabled(domain) },
                            set: { store.setEnabled(domain, $0) }
                        )
                    )
                }
            }
        }
    }

    private func domainTitle(_ domain: SyncDomain) -> String {
        switch domain {
        case .bookmarks: "Bookmarks"
        case .quickDials: "Quick Dial"
        case .readingList: "Reading List"
        case .keyboardShortcuts: "Keyboard Shortcuts"
        case .settings: "Settings"
        case .agentMemory: "Agent Memory"
        case .agentPrefs: "Agent Prompt"
        }
    }

    // MARK: - 修改密码

    @ViewBuilder
    private var passwordSection: some View {
        SettingsSection(title: "Change Password", icon: "key") {
            VStack(spacing: 0) {
                SettingsRow("Current Password") {
                    SettingsTextField(
                        placeholder: "••••••••",
                        text: $currentPassword,
                        isSecure: true,
                        width: 200
                    )
                }
                SettingsRowDivider()
                SettingsRow("New Password", subtitle: localizedSettingText("At least 8 characters with letters and numbers.")) {
                    SettingsTextField(
                        placeholder: "At least 8 characters",
                        text: $newPassword,
                        isSecure: true,
                        width: 200
                    )
                }
                SettingsRowDivider()
                SettingsRow(
                    "Change Password",
                    subtitle: pwError ?? (pwSaved ? localizedSettingText("Saved") : nil)
                ) {
                    SettingsCapsuleButton(
                        "Change Password",
                        isDisabled: !canChangePassword || pwWorking
                    ) { submitPasswordChange() }
                }
            }
        }
    }

    private var newPasswordValid: Bool {
        let n = newPassword
        guard (8...72).contains(n.count) else { return false }
        return n.contains(where: { $0.isLetter }) && n.contains(where: { $0.isNumber })
    }

    private var canChangePassword: Bool {
        !currentPassword.isEmpty && newPasswordValid
    }

    private func submitPasswordChange() {
        pwWorking = true
        pwError = nil
        pwSaved = false
        Task { @MainActor in
            do {
                try await store.changePassword(current: currentPassword, new: newPassword)
                pwSaved = true
                currentPassword = ""
                newPassword = ""
            } catch {
                pwError = error.localizedDescription
            }
            pwWorking = false
        }
    }

    // MARK: - 服务器地址

    @ViewBuilder
    private var serverSection: some View {
        SettingsSection(
            title: "Sync Server",
            subtitle: "Where your sync account lives.",
            icon: "server.rack"
        ) {
            VStack(spacing: 0) {
                SettingsRow("Server", subtitle: store.serverBaseURL) {
                    SettingsTextField(
                        placeholder: "http://127.0.0.1:18090",
                        text: $serverURL,
                        width: 240
                    )
                }
                SettingsRowDivider()
                SettingsRow("Apply", subtitle: serverSaved ? localizedSettingText("Saved") : nil) {
                    SettingsCapsuleButton("Apply", style: .secondary) {
                        store.setServerBaseURL(serverURL)
                        serverSaved = true
                    }
                }
            }
        }
    }

    private var lastSyncText: String {
        guard let lastSyncAt = store.lastSyncAt else {
            return localizedSettingText("Never")
        }
        return lastSyncAt.formatted(date: .abbreviated, time: .shortened)
    }

}

struct SyncSettingsSection_Previews: PreviewProvider {
    static var previews: some View {
        SyncSettingsSection(store: SyncStore(
            bookmarkStore: BookmarkStore(),
            quickDialStore: QuickDialStore(),
            readingListStore: ReadingListStore(),
            shortcutStore: KeyboardShortcutStore(),
            settings: Settings(),
            agentPreferenceStore: AgentPreferenceStore()
        ))
        .appAccent(.blue)
    }
}
