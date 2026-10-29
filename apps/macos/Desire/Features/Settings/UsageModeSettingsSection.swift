import SwiftUI

/// 设置 ▸ 使用模式（v0.8.23）：三种工作方式的入口与说明。
struct UsageModeSettingsSection: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: AppModeStore

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

            Text("Agent Workspace keeps the browser in the background and reveals it only when needed. Hybrid gives the agent its own window with an isolated container, so your tabs, focus and cookies stay separate.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
