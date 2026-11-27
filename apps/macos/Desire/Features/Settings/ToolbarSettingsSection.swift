import SwiftUI

/// 工具栏布局设置（v0.8.83）：固定位置按钮只开关，右侧一排还能上下移动。
/// 新增按钮默认隐藏，所以未动过设置的用户看到的仍是旧布局。
struct ToolbarSettingsSection: View {
    @ObservedObject private var store = ToolbarCustomizationStore.shared

    var body: some View {
        SettingsContainer {
            SettingsSection(
                title: "Toolbar",
                subtitle: "Choose which buttons appear. The right-side row can also be reordered; new buttons start hidden so the default layout stays the same.",
                icon: "slider.horizontal.3"
            ) {
                VStack(spacing: 0) {
                    ForEach(ToolbarItem.fixedItems) { item in
                        SettingsToggleRow(item.title,
                                          subtitle: fixedSubtitle(for: item),
                                          systemImage: item.icon,
                                          isOn: visibleBinding(for: item))
                        SettingsRowDivider()
                    }
                    ForEach(store.order) { item in
                        SettingsRow(item.title, systemImage: item.icon) {
                            HStack(spacing: 6) {
                                Button {
                                    store.moveUp(item)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .disabled(store.order.first == item)
                                .accessibilityLabel(Text("Move \(item.title) up"))

                                Button {
                                    store.moveDown(item)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .disabled(store.order.last == item)
                                .accessibilityLabel(Text("Move \(item.title) down"))

                                Toggle("", isOn: visibleBinding(for: item))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .accessibilityLabel(Text(item.title))
                            }
                        }
                        SettingsRowDivider()
                    }
                    HStack(alignment: .center, spacing: 12) {
                        Text("Buttons added in this version start hidden; resetting restores the default toolbar.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Reset Toolbar") { store.reset() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!store.isCustomized)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func fixedSubtitle(for item: ToolbarItem) -> String? {
        switch item {
        case .home: "The house button next to reload."
        case .zoom: "The page-zoom percentage next to the address bar."
        case .extensions: "The puzzle-piece button that opens the plugin list."
        case .syncStatus: "The sync indicator between plugins and the right-side buttons."
        default: nil
        }
    }

    private func visibleBinding(for item: ToolbarItem) -> Binding<Bool> {
        Binding(
            get: { store.isVisible(item) },
            set: { visible in
                guard visible != store.isVisible(item) else { return }
                store.toggle(item)
            }
        )
    }
}
