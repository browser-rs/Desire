import AppKit
import SwiftUI

/// 设置 → Sync：登录/注册 + 同步状态 + 立即同步/退出。
/// 组合根（SettingsView）注入共享 SyncStore；本视图零业务逻辑，认证与同步
/// 全部走 store 方法，错误展示用 store.lastError（登录失败是同步态的属性）。
struct SyncSettingsSection: View {
    @ObservedObject var store: SyncStore
    /// 冲突明细 sheet（v0.7.23）。
    @State private var showsConflicts = false
    /// 接入引导 sheet（v0.7.23）：首次登录后自动弹一次，之后走 syncSection 入口。
    @State private var showsOnboarding = false
    private static let onboardingShownKey = "sync.onboardingShown"

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
    @State private var captchaInput = ""
    @State private var captchaLoading = false

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
        .sheet(isPresented: $showQRLogin) {
            SyncQRLoginSheet(store: store)
        }
        .sheet(isPresented: $showsOnboarding) {
            SyncOnboardingSheet(store: store)
        }
        .onChange(of: store.authState, initial: true) {
            // 首次进入已登录态自动弹一次接入引导（此前的账号也补弹一次）。
            guard case .signedIn = store.authState,
                  !UserDefaults.standard.bool(forKey: Self.onboardingShownKey) else { return }
            UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
            showsOnboarding = true
        }
        .onAppear {
            // 内置默认地址不在界面露出：只有用户设过覆盖才显示值
            serverURL = store.hasServerOverride ? store.serverBaseURL : ""
        }
    }

    // MARK: - 未登录：登录 / 注册表单

    enum AuthMode { case signIn; case register }

    @State private var mode: AuthMode = .signIn
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @State private var showQRLogin = false

    @ViewBuilder
    private var signedOut: some View {
        SettingsSection(
            title: "Sync",
            subtitle: "Sign in to keep your bookmarks up to date across devices.",
            icon: "arrow.triangle.2.circlepath"
        ) {
            VStack(spacing: 0) {
                // 会话失效横幅（v0.7.24）：自愈登出时此前只写 lastError，
                // 未登录表单不展示——用户不知道"为什么退了、要不要重登"。
                if let sessionNote = store.lastError {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(sessionNote, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                        Text(localizedSettingText("Sign in again to resume syncing. Your key and cloud data are unaffected."))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    SettingsRowDivider()
                }
                // 模式：整行分段（原来挤在右上角，与下方表单没有任何对齐关系）
                HStack {
                    Picker("", selection: $mode) {
                        Text(localizedSettingText("Sign In")).tag(AuthMode.signIn)
                        Text(localizedSettingText("Register")).tag(AuthMode.register)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .onChange(of: mode) {
                    formError = nil
                    confirmPassword = ""
                    captchaInput = ""
                    if mode == .register && store.captcha == nil {
                        captchaLoading = true
                        Task { @MainActor in
                            await store.loadCaptcha()
                            captchaLoading = false
                        }
                    }
                }

                SettingsRowDivider()
                SettingsFieldRow(
                    "Username",
                    subtitle: mode == .register
                        ? localizedSettingText("Usernames start with a letter and use 3-32 letters, digits or underscores.")
                        : nil
                ) {
                    SettingsTextField(placeholder: "username", text: $username)
                }
                SettingsRowDivider(leading: SettingsMetrics.fieldDividerLeading)
                SettingsFieldRow(
                    "Password",
                    subtitle: mode == .register
                        ? localizedSettingText("At least 8 characters with letters and numbers.")
                        : nil
                ) {
                    SettingsTextField(
                        placeholder: "••••••••",
                        text: $password,
                        isSecure: true,
                        secureToggle: true
                    )
                }
                if mode == .register {
                    SettingsRowDivider(leading: SettingsMetrics.fieldDividerLeading)
                    SettingsFieldRow("Confirm Password", subtitle: confirmError) {
                        SettingsTextField(
                            placeholder: "••••••••",
                            text: $confirmPassword,
                            isSecure: true,
                            secureToggle: true
                        )
                    }
                    SettingsRowDivider(leading: SettingsMetrics.fieldDividerLeading)
                    SettingsFieldRow("Verification Code") {
                        captchaField
                    }
                    if !password.isEmpty {
                        SettingsRowDivider(leading: SettingsMetrics.fieldDividerLeading)
                        SettingsFieldRow("Password strength") {
                            strengthBars
                        }
                    }
                }

                // 提交：整行宽主按钮（原来是右上角小胶囊，整页没有视觉焦点）
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSubmitButton(
                        mode == .signIn ? "Sign In" : "Register",
                        isDisabled: !canSubmit,
                        isWorking: isWorking
                    ) { submit() }
                    if let formError {
                        Label(formError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        }

        // 扫码登录独立成卡：原来夹在表单中间，打断了"填表 → 提交"的视线顺序
        SettingsSection(
            title: "扫码登录",
            subtitle: "用已登录的 iPhone App 扫码，免密码登录本机。",
            icon: "qrcode"
        ) {
            SettingsRow("iPhone 扫码") {
                SettingsCapsuleButton(
                    "扫码登录",
                    systemImage: "qrcode.viewfinder",
                    style: .secondary
                ) {
                    showQRLogin = true
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

    /// 验证码字段（图形码 + 换一张 + 输入框），由 `SettingsFieldRow` 承载。
    @ViewBuilder
    private var captchaField: some View {
        HStack(spacing: 8) {
            if captchaLoading {
                ProgressView().controlSize(.small)
                    .frame(width: 100, height: 32)
            } else if let png = store.captcha?.pngData, let nsImage = NSImage(data: png) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 100, height: 32)
                    .cornerRadius(4)
                    .contentShape(Rectangle())
                    .onTapGesture { refreshCaptcha() }
                    .help(localizedSettingText("Get a new one"))
            } else {
                Text(localizedSettingText("Failed to load"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 100, height: 32)
            }
            Button {
                refreshCaptcha()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(localizedSettingText("Get a new one"))

            SettingsTextField(
                placeholder: "Enter the characters shown",
                text: $captchaInput,
                width: 120
            )
            Spacer(minLength: 0)
        }
    }

    private func refreshCaptcha() {
        captchaLoading = true
        Task { @MainActor in
            await store.loadCaptcha()
            captchaLoading = false
        }
    }

    /// 强度条（由 `SettingsFieldRow` 承载）。
    private var strengthBars: some View {
        let score = strengthScore(password)
        return HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < score ? strengthColor(score) : Color.secondary.opacity(0.18))
                    .frame(width: 18, height: 4)
            }
            Text(localizedSettingText(strengthLabel(score)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
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
                // 注册失败后验证码已被消费/作废 → 换新码供重试
                if mode == .register { await store.loadCaptcha() }
            }
            isWorking = false
        }
    }

    // MARK: - 已登录：状态 + 操作

    /// 各区块直接作为 body 级 SettingsContainer 的兄弟子视图（勿再套
    /// SettingsContainer——双层容器会让本区块被双重内边距挤窄，宽度不一致）。
    @ViewBuilder
    private func signedIn(_ account: String) -> some View {
        syncSection(account)
        keySection
        passwordSection
        categoriesSection
        diagnosticsSection
    }

    /// 同步日志（0.6.8）：逐域累计 推送/拉取/冲突 与最近一次冲突记号。
    /// 冲突 = LWW 输掉（服务端胜者已自动回写落地）——这里只是让它**可见**。
    private var diagnosticsSection: some View {
        SettingsSection(
            title: String(localized: "Sync Log"),
            subtitle: String(localized: "Per-domain totals. Conflicts are cases where the server had newer data — the server copy was applied automatically."),
            icon: "list.bullet.rectangle"
        ) {
            ForEach(SyncDomain.allCases, id: \.self) { domain in
                SettingsRow(domain.displayName,
                            subtitle: diagText(store.diagnostics[domain],
                                               tombstones: store.pendingTombstoneCounts[domain] ?? 0)) { }
                if domain != SyncDomain.allCases.last {
                    SettingsRowDivider()
                }
            }
        }
    }

    private func diagText(_ diag: SyncDomainDiag?, tombstones: Int) -> String {
        guard let diag, diag.pushed > 0 || diag.pulled > 0 || tombstones > 0 else {
            return "尚无同步流量"
        }
        var text = "推送 \(diag.pushed) 条 · 拉取 \(diag.pulled) 条"
        if diag.conflicts > 0 {
            let when = diag.lastConflictAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            let mark = diag.lastConflictMark ?? ""
            text += " · 冲突 \(diag.conflicts) 条（最近 \(when) #\(mark)）"
        }
        if tombstones > 0 {
            text += " · 待删墓碑 \(tombstones)"
        }
        return text
    }

    private func syncSection(_ account: String) -> some View {
        SettingsSection(
            title: "Sync",
            subtitle: "Changes sync within seconds. A full check runs every 5 minutes.",
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
                SettingsRow(
                    "Device Setup",
                    subtitle: "Walk through account, key, categories and the first sync."
                ) {
                    SettingsCapsuleButton("Open", style: .secondary) {
                        showsOnboarding = true
                    }
                }
                SettingsRowDivider()
                SettingsRow("Last Sync", subtitle: lastSyncText) {
                    SettingsCapsuleButton(
                        "Sync Now",
                        isDisabled: store.isSyncing || store.needsSecretMigration
                    ) {
                        isWorking = true
                        Task {
                            await store.syncNow()
                            isWorking = false
                        }
                    }
                }
                if store.needsSecretMigration {
                    SettingsRowDivider()
                    SettingsRow(
                        "Resume Sync",
                        subtitle: "Sync is paused once after this update so macOS doesn't prompt for every saved secret. Re-authorize reads the existing sync credentials once and stores them in a single Keychain item — later updates ask at most once."
                    ) {
                        SettingsCapsuleButton(
                            "Re-authorize",
                            style: .secondary,
                            isDisabled: isWorking
                        ) {
                            isWorking = true
                            Task {
                                await store.migrateSyncSecrets()
                                isWorking = false
                            }
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
    }

    // MARK: - 同步密钥（E2E 加密）

    /// 密钥由账号密码经 KDF 派生并托管在服务器（包裹形态），换设备登录即自动恢复;
    /// 不再提供手工生成/导入——忘记密码即无法解密既有服务端数据(标准 E2E 取舍)。
    @ViewBuilder
    private var keySection: some View {
        SettingsSection(
            title: "Sync Key",
            subtitle: "End-to-end encrypted with your account password. The server stores only scrambled data and cannot read it.",
            icon: "key.fill"
        ) {
            SettingsRow("Key Fingerprint",
                        subtitle: store.syncKeyFingerprint
                            ?? (store.hasSyncKey ? "••••••••" : localizedSettingText("Not set"))) {
                EmptyView()
            }
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
                        domain.displayName,
                        subtitle: domainStatusCaption(domain),
                        isOn: Binding(
                            get: { store.isEnabled(domain) },
                            set: { store.setEnabled(domain, $0) }
                        )
                    )
                }
            }
        }

        ConflictsSection(store: store)
        DevicesSection(store: store)
    }

    /// 相对时间文案（系统本地化，"3 分钟前"），随 app 语言走。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// 逐域状态副标题：✓ + 相对时间 / ⚠ + 错误文案。禁用的域不显示（状态无意义）。
    private func domainStatusCaption(_ domain: SyncDomain) -> String? {
        guard store.isEnabled(domain), let status = store.domainStatus[domain] else { return nil }
        var caption: String
        switch status {
        case .ok(let date):
            caption = "✓ " + Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        case .failed(let message):
            caption = "⚠ " + message
        }
        // 待删墓碑计数（v0.8.17 基础件 13）：正常应在裁决后归零，
        // 长期非零 = 该域同步持续失败的信号。
        if let pending = store.pendingTombstoneCounts[domain], pending > 0 {
            caption += " · " + String(localized: "\(pending) pending delete")
        }
        return caption
    }

    // MARK: - 修改密码

    @ViewBuilder
    private var passwordSection: some View {
        SettingsSection(title: "Change Password", icon: "key") {
            VStack(spacing: 0) {
                SettingsFieldRow("Current Password") {
                    SettingsTextField(
                        placeholder: "••••••••",
                        text: $currentPassword,
                        isSecure: true
                    )
                }
                SettingsRowDivider(leading: SettingsMetrics.fieldDividerLeading)
                SettingsFieldRow(
                    "New Password",
                    subtitle: localizedSettingText("At least 8 characters with letters and numbers.")
                ) {
                    SettingsTextField(
                        placeholder: "At least 8 characters",
                        text: $newPassword,
                        isSecure: true
                    )
                }
                SettingsRowDivider()
                HStack(spacing: 8) {
                    if let pwError {
                        Label(pwError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if pwSaved {
                        Label(localizedSettingText("Saved"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    SettingsCapsuleButton(
                        "Change Password",
                        isDisabled: !canChangePassword || pwWorking
                    ) { submitPasswordChange() }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
                SettingsFieldRow("Server", subtitle: "留空使用内置默认地址（修改后需重新登录）。") {
                    SettingsTextField(
                        placeholder: String(localizedSettingText("Default: built-in server")),
                        text: $serverURL
                    )
                }
                SettingsRowDivider(leading: SettingsMetrics.fieldDividerLeading)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if serverSaved {
                        Label(localizedSettingText("Saved"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    SettingsCapsuleButton("Apply", style: .secondary) {
                        store.setServerBaseURL(serverURL)
                        serverSaved = true
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    /// 上次完整同步：相对时间为主（"3 分钟前"），绝对时间挂 tooltip。
    private var lastSyncText: String {
        guard let lastSyncAt = store.lastSyncAt else {
            return localizedSettingText("Never")
        }
        return Self.relativeFormatter.localizedString(for: lastSyncAt, relativeTo: Date())
    }

}

struct SyncSettingsSection_Previews: PreviewProvider {
    static var previews: some View {
        SyncSettingsSection(store: SyncStore(
            bookmarkStore: BookmarkStore(),
            quickDialStore: QuickDialStore(),
            readingListStore: ReadingListStore(),
            historyStore: HistoryStore(),
            shortcutStore: KeyboardShortcutStore(),
            settings: Settings(),
            agentPreferenceStore: AgentPreferenceStore()
        ))
        .appAccent(.blue)
    }
}

/// 冲突明细小节（v0.7.23）：本机 LWW 输掉的最近条目（解密后可读标签）——
/// 单看逐域 ✓ 不知道"到底哪几条被服务端胜出"，这里给明细 + 清空。
private struct ConflictsSection: View {
    @ObservedObject var store: SyncStore
    @State private var shows = false

    var body: some View {
        SettingsSection(
            title: "Conflict Details",
            subtitle: "Entries where another device's copy won last-write-wins (decrypted locally for readability).",
            icon: "arrow.triangle.branch"
        ) {
            SettingsRow(
                "Recent Conflicts",
                subtitle: store.recentConflicts.isEmpty
                    ? String(localized: "None — every device is in sync.")
                    : String(localized: "\(store.recentConflicts.count) entr(y/ies) — tap to review."),
                systemImage: "exclamationmark.triangle"
            ) {
                if !store.recentConflicts.isEmpty {
                    SettingsCapsuleButton("Review", style: .secondary) { shows = true }
                }
            }
        }
        .sheet(isPresented: $shows) {
            ConflictDetailsSheet(store: store) { shows = false }
        }
    }
}

private struct ConflictDetailsSheet: View {
    @ObservedObject var store: SyncStore
    let onClose: () -> Void

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Conflict Details"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "Clear")) {
                    store.clearConflictNotes()
                    onClose()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button(String(localized: "Done")) { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("These local changes lost LWW against another device's newer copy — the newer copy is now on this device too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(store.recentConflicts) { note in
                HStack(spacing: 8) {
                    Text(domainName(note.domain))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(note.label)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                    Text(Self.formatter.localizedString(for: note.at, relativeTo: Date()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private func domainName(_ raw: String) -> String {
        SyncDomain(rawValue: raw)?.displayName ?? raw
    }
}

/// 设备面板小节（v0.7.23）：账号下的设备清单 + 各自拉取游标；90 天没拉过的
/// 标灰（GC 的活跃窗口同口径），吊销设备红字。
private struct DevicesSection: View {
    @ObservedObject var store: SyncStore

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        SettingsSection(
            title: "Devices",
            subtitle: "Every device on this account and how far it has synced. Grey = no pull for 90+ days.",
            icon: "ipad.and.iphone"
        ) {
            VStack(spacing: 0) {
                if store.devices.isEmpty {
                    SettingsRow(
                        "No device data yet",
                        subtitle: store.devicesError ?? String(localized: "Tap Refresh to load from the server."),
                        systemImage: "questionmark.circle"
                    ) {}
                } else {
                    ForEach(Array(store.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { SettingsRowDivider() }
                        SettingsRow(
                            device.name.isEmpty ? device.deviceID : device.name,
                            subtitle: caption(device),
                            systemImage: device.revoked ? "xmark.circle" : "desktopcomputer"
                        ) {}
                    }
                }
                SettingsRowDivider()
                SettingsRow(
                    "Refresh",
                    subtitle: store.devicesError.map { "⚠ " + $0 } ?? " ",
                    systemImage: "arrow.clockwise"
                ) {
                    SettingsCapsuleButton("Refresh", style: .secondary) {
                        Task { await store.refreshDevices() }
                    }
                }
            }
        }
        .task { if store.devices.isEmpty { await store.refreshDevices() } }
    }

    private func caption(_ device: SyncDeviceInfo) -> String {
        var parts: [String] = []
        if !device.platform.isEmpty { parts.append(device.platform) }
        if let seen = device.cursorSeenAt ?? device.lastSeenAt {
            parts.append(String(localized: "last pull ") + Self.formatter.localizedString(for: seen, relativeTo: Date()))
        } else {
            parts.append(String(localized: "never pulled"))
        }
        if device.revoked { parts.append(String(localized: "revoked")) }
        return parts.joined(separator: " · ")
    }
}
