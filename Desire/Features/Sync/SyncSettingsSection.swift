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

    @ViewBuilder
    private var signedOut: some View {
        SettingsSection(
            title: "Sync",
            subtitle: "Sign in to keep your bookmarks up to date across devices.",
            icon: "arrow.triangle.2.circlepath"
        ) {
            VStack(spacing: 0) {
                SettingsRow("Username") {
                    SettingsTextField(placeholder: "username", text: $username, width: 200)
                }
                SettingsRowDivider()
                SettingsRow("Password") {
                    SettingsTextField(placeholder: "••••••••", text: $password, isSecure: true, width: 200)
                }
                SettingsRowDivider()
                SettingsRow("Account", subtitle: formError) {
                    HStack(spacing: 8) {
                        SettingsCapsuleButton(
                            "Sign In",
                            isDisabled: !canSubmit || isWorking
                        ) { submit(register: false) }
                        SettingsCapsuleButton(
                            "Register",
                            style: .secondary,
                            isDisabled: !canSubmit || isWorking
                        ) { submit(register: true) }
                    }
                }
            }
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
            passwordSection
            categoriesSection
            serverSection
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
                SettingsRow("New Password") {
                    SettingsTextField(
                        placeholder: "≥ 6 characters",
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

    private var canChangePassword: Bool {
        !currentPassword.isEmpty && newPassword.count >= 6
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

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 6
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

    private func submit(register: Bool) {
        isWorking = true
        formError = nil
        Task { @MainActor in
            do {
                if register {
                    try await store.register(username: username, password: password)
                } else {
                    try await store.login(username: username, password: password)
                }
                password = ""
            } catch {
                formError = error.localizedDescription
            }
            isWorking = false
        }
    }
}
