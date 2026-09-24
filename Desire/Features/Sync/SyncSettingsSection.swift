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

    var body: some View {
        SettingsContainer {
            switch store.authState {
            case .signedOut:
                signedOut
            case .signedIn(let account):
                signedIn(account)
            }
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
                }
            }
        }
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 6
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
