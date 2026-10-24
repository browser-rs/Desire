import SwiftUI

/// 隐私与安全面板（v0.8.6 旗舰）：三段合一——拦截统计（AdBlockStatsStore）、
/// 保护开关与过滤列表（ContentBlockerStore / VideoAdBlocker / FilterListStore）、
/// 站点权限矩阵（PermissionStore + PermissionMatrix）。
/// Panel 例外：直接持有 store。入口：设置 ▸ 隐私。
struct PrivacyDashboardView: View {
    @ObservedObject var permissions: PermissionStore
    @ObservedObject var contentBlocker: ContentBlockerStore
    @ObservedObject var videoAdBlocker: VideoAdBlocker
    @ObservedObject private var stats = AdBlockStatsStore.shared
    @ObservedObject private var filterLists = FilterListStore.shared

    @Environment(\.dismiss) private var dismiss
    @State private var showResetAllConfirm = false

    private var matrixRows: [PermissionMatrix.Row] {
        PermissionMatrix.build(from: permissions.rules)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.tint)
                Text("Privacy & Security")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    statsSection
                    protectionSection
                    matrixSection
                }
                .padding(16)
            }
        }
        .frame(width: 620, height: 660)
        .confirmationDialog(
            "Reset All Permissions",
            isPresented: $showResetAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { permissions.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear every saved camera, microphone, and location decision for all websites.")
        }
    }

    // MARK: - 拦截统计

    private var statsSection: some View {
        dashboardSection(
            title: "Blocked Content",
            subtitle: "Counted from the video-ad rules; community filter lists run inside WebKit without per-hit callbacks.",
            icon: "shield.lefthalf.filled"
        ) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    statCard(value: "\(stats.total)", label: "All time")
                    statCard(value: "\(stats.todayCount)", label: "Today")
                    statCard(
                        value: "\(stats.perDomain.filter { $0.key != "other" }.count)",
                        label: "Sites"
                    )
                }

                let top = stats.perDomain
                    .filter { $0.key != "other" && $0.value > 0 }
                    .sorted { $0.value > $1.value }
                    .prefix(8)
                if !top.isEmpty {
                    let maxValue = top.first?.value ?? 1
                    VStack(spacing: 5) {
                        ForEach(Array(top.enumerated()), id: \.element.key) { _, item in
                            HStack(spacing: 8) {
                                Text(AdBlockStatsStore.displayName(forSite: item.key))
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                                    .frame(width: 110, alignment: .leading)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.tint.opacity(0.55))
                                    .frame(width: max(6, CGFloat(item.value) / CGFloat(maxValue) * 250), height: 9)
                                Text("\(item.value)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(.tint)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    // MARK: - 保护开关

    private var protectionSection: some View {
        dashboardSection(
            title: "Protection",
            subtitle: "Switches apply to new page loads.",
            icon: "checkmark.shield"
        ) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    "Block Ads",
                    subtitle: "Built-in content-blocker rules.",
                    systemImage: "rectangle.slash",
                    isOn: $contentBlocker.isBlockingEnabled
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Tracking Protection",
                    subtitle: "Block known trackers and analytics.",
                    systemImage: "eye.slash",
                    isOn: $contentBlocker.isTrackingEnabled
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Video Ad Blocking",
                    subtitle: "Site-specific rules for streaming platforms.",
                    systemImage: "play.slash",
                    isOn: Binding(
                        get: { videoAdBlocker.isEnabled },
                        set: { videoAdBlocker.setEnabled($0) }
                    )
                )
                SettingsRowDivider()
                filterListRow
            }
        }
    }

    private var filterListRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Community Filter Lists")
                    .font(.system(size: 12.5))
                Text(filterSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var filterSummary: String {
        let enabled = filterLists.lists.filter { $0.isEnabled }
        let rules = enabled.compactMap(\.ruleCount).reduce(0, +)
        if filterLists.lists.contains(where: { $0.isUpdating }) {
            return String(localized: "Updating…")
        }
        guard !enabled.isEmpty else { return String(localized: "No lists enabled") }
        return String(localized: "\(enabled.count) lists · \(rules) rules")
    }

    // MARK: - 权限矩阵

    private var matrixSection: some View {
        dashboardSection(
            title: "Site Permissions",
            subtitle: "Click a cell to cycle: not set → allow → deny.",
            icon: "hand.raised"
        ) {
            let rows = matrixRows
            return VStack(spacing: 0) {
                if rows.isEmpty {
                    Text("No site permissions yet — sites appear here after you answer a camera, microphone, or location prompt.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    matrixHeader
                    SettingsRowDivider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        matrixRow(row)
                        if index < rows.count - 1 {
                            SettingsRowDivider()
                        }
                    }
                    SettingsRowDivider()
                    HStack {
                        Spacer()
                        Button {
                            showResetAllConfirm = true
                        } label: {
                            Text("Reset All")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.red.opacity(0.12)))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var matrixHeader: some View {
        HStack(spacing: 0) {
            Text("Website")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(PermissionMatrix.columns, id: \.rawValue) { type in
                Image(systemName: Self.columnIcon(type))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 52)
                    .help(Self.columnName(type))
                    .contextMenu {
                        Button(String(localized: "Reset This Column")) {
                            permissions.removeAll(type: type)
                        }
                    }
            }
            Color.clear.frame(width: 28)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func matrixRow(_ row: PermissionMatrix.Row) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.host)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(row.decisions.count) rule\(row.decisions.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(PermissionMatrix.columns, id: \.rawValue) { type in
                permissionCell(host: row.host, type: type, state: row.decisions[type])
            }

            Button {
                permissions.remove(host: row.host)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Revoke all permissions for this site")
            .frame(width: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func permissionCell(host: String, type: PermissionType, state: PermissionDecision?) -> some View {
        Button {
            permissions.cycle(host: host, type: type)
        } label: {
            Group {
                switch state {
                case .allow:
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                case .deny:
                    Image(systemName: "xmark")
                        .foregroundStyle(.red)
                case nil:
                    Image(systemName: "minus")
                        .foregroundStyle(.quaternary)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 22, height: 22)
            .background(
                Circle().fill(cellColor(state).opacity(state == nil ? 0.05 : 0.12))
            )
        }
        .buttonStyle(.plain)
        .frame(width: 52)
        .help("\(Self.columnName(type)) — \(helpText(state))")
    }

    private func cellColor(_ state: PermissionDecision?) -> Color {
        switch state {
        case .allow: .green
        case .deny: .red
        case nil: .secondary
        }
    }

    private func helpText(_ state: PermissionDecision?) -> String {
        switch state {
        case .allow: String(localized: "Allowed")
        case .deny: String(localized: "Denied")
        case nil: String(localized: "Not set")
        }
    }

    private static func columnIcon(_ type: PermissionType) -> String {
        switch type {
        case .camera: "video"
        case .microphone: "mic"
        case .cameraAndMicrophone: "video.badge.ellipsis"
        case .geolocation: "location"
        }
    }

    private static func columnName(_ type: PermissionType) -> String {
        switch type {
        case .camera: String(localized: "Camera")
        case .microphone: String(localized: "Microphone")
        case .cameraAndMicrophone: String(localized: "Camera & Microphone")
        case .geolocation: String(localized: "Location")
        }
    }

    // MARK: - 通用段容器

    private func dashboardSection(
        title: String, subtitle: String, icon: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                content()
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.12)))
        }
    }
}

#Preview {
    PrivacyDashboardView(
        permissions: PermissionStore(),
        contentBlocker: ContentBlockerStore(),
        videoAdBlocker: VideoAdBlocker()
    )
}
