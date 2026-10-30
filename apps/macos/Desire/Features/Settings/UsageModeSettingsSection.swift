import SwiftUI

/// 设置 ▸ 使用模式（v0.8.23）：三种工作方式的入口与说明。
struct UsageModeSettingsSection: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: AppModeStore
    @State private var showShareConfirm = false

    var body: some View {
        SettingsContainer {
            SettingsSection(
                title: "Usage Mode",
                subtitle: "How the agent and your browsing share windows, focus and cookies.",
                icon: "rectangle.split.2x1"
            ) {
                ForEach(Array(AppUsageMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button {
                        AppModeCoordinator.apply(mode)
                    } label: {
                        SettingsRow(
                            mode.title,
                            subtitle: mode.detail,
                            systemImage: store.mode == mode ? "checkmark.circle.fill" : "circle"
                        ) {
                            if store.mode == mode {
                                Text(String(localized: "Current"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(appAccent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    if index < AppUsageMode.allCases.count - 1 {
                        SettingsRowDivider()
                    }
                }
            }

            SettingsSection(
                title: "At a Glance",
                subtitle: "What changes between modes.",
                icon: "tablecells"
            ) {
                comparisonRow(String(localized: "Interface"),
                               String(localized: "Workspace window"),
                               String(localized: "Tabs and page"),
                               String(localized: "Two windows"))
                SettingsRowDivider()
                comparisonRow(String(localized: "Browser"),
                               String(localized: "Background panel"),
                               String(localized: "Your window"),
                               String(localized: "Agent window"))
                SettingsRowDivider()
                comparisonRow(String(localized: "Login state"),
                               String(localized: "Isolated container"),
                               String(localized: "Your profile"),
                               String(localized: "Isolated container"))
                SettingsRowDivider()
                comparisonRow(String(localized: "Interruption"),
                               String(localized: "Peek inline"),
                               String(localized: "Beside you"),
                               String(localized: "Non-activating overlay"))
            }

            SettingsSection(
                title: "Login State",
                subtitle: "How the agent's browser relates to your logins.",
                icon: "key"
            ) {
                SettingsToggleRow(
                    "Share Your Login State",
                    subtitle: "Agent windows use this Mac's browsing profile instead of an isolated container. More convenient, less isolated.",
                    systemImage: "person.badge.key",
                    isOn: Binding(
                        get: { store.agentSharesUserProfile },
                        set: { value in
                            if value {
                                showShareConfirm = true
                            } else {
                                store.setAgentSharesUserProfile(false)
                            }
                        }
                    )
                )
            }
            .alert(String(localized: "Share your login state?"), isPresented: $showShareConfirm) {
                Button(String(localized: "Cancel"), role: .cancel) {}
                Button(String(localized: "Share"), role: .destructive) {
                    store.setAgentSharesUserProfile(true)
                }
            } message: {
                Text(String(localized: "Agent windows will be able to see every site you are signed in to. Only do this on a Mac you trust."))
            }

            Text("Agent Workspace keeps the browser in the background and reveals it only when needed. Hybrid gives the agent its own window with an isolated container, so your tabs, focus and cookies stay separate.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 对比表一行：维度 + 三种模式各一句（第一列是维度名）。
    private func comparisonRow(_ label: String, _ agent: String, _ browser: String, _ hybrid: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Text(AppUsageMode.agentFocus.title + ": " + agent).font(.system(size: 10.5))
                Text(AppUsageMode.browser.title + ": " + browser).font(.system(size: 10.5))
                Text(AppUsageMode.hybrid.title + ": " + hybrid).font(.system(size: 10.5))
            }
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
