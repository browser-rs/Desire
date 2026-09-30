import SwiftUI

/// 输入栏左侧的**访问等级**胶囊：三档 变更前确认 → 自动编辑 → 完全访问。
/// 点击弹出自绘选择面板（锚定胶囊）：每档一行 = 图标章 + 名称 + 一句职责 +
/// 选中态墨底反白；当前档在胶囊上常显图标与名称。
struct AgentFullAccessPill: View {
    @ObservedObject var store: AgentSessionStore
    @State private var showPicker = false

    private var level: AgentSessionStore.AccessLevel { store.accessLevel }

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: level.icon)
                    .font(.system(size: 9, weight: .medium))
                Text(level.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(level == .fullAccess ? Color.orange : Color.secondary)
            .padding(.horizontal, 9)
            // 与输入栏其它控件同高、同描边（此前 20pt 胶囊和 28pt 圆钮混在一起）。
            .frame(height: 26)
            .background(
                Capsule().fill(
                    level == .fullAccess
                        ? Color.orange.opacity(0.15)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.6)
                )
            )
            .overlay(
                Capsule().stroke(
                    (level == .fullAccess ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.4)),
                    lineWidth: 0.5
                )
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Access level — how much the agent may do without asking")
        .animation(.hoverFast, value: store.accessLevel)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            accessPicker
                .padding(10)
                .frame(width: 264)
        }
    }

    // MARK: - 选择面板（自绘）

    private var accessPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Access Level"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.bottom, 2)
            ForEach(AgentSessionStore.AccessLevel.allCases, id: \.self) { option in
                accessRow(option)
            }
        }
    }

    private func accessRow(_ option: AgentSessionStore.AccessLevel) -> some View {
        let isSelected = store.accessLevel == option
        return Button {
            store.accessLevel = option
            showPicker = false
        } label: {
            HStack(spacing: 10) {
                // 图标章：选中档墨底反白，未选中档灰底
                Image(systemName: option.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected
                                ? AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.9))
                                : AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.displayName)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    Text(option.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected
                    ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                    : AnyShapeStyle(Color.clear))
        )
    }
}
