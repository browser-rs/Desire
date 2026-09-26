import SwiftUI

/// 能力与工具（Agent Tab → 工具与技能）：把 Mac 上 Agent 能调用的全部工具
/// 按风险分级列出来，外加技能库。
///
/// 风险分级直接来自 Mac 的 `ToolRisk.classify`，是**执行时的真实闸门**
/// （只读自动执行、改状态需确认、执行代码每次都确认），不是说明性文案。
struct AgentCapabilitiesView: View {
    @EnvironmentObject var client: RemoteClient

    private static let groupOrder: [(String, String)] = [
        ("执行代码", "dangerous"),
        ("改变状态", "sideEffect"),
        ("只读安全", "readonly"),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let caps = client.capabilities {
                    if caps.tools.isEmpty && caps.skills.isEmpty {
                        DesireEmptyState(
                            icon: "sparkles.rectangle.stack",
                            title: "没有可用能力",
                            message: "Mac 侧没有返回工具或技能。")
                    } else {
                        summaryCard(caps)
                        ForEach(groups(caps), id: \.0) { title, tools in
                            toolSection(title: title, tools: tools)
                        }
                        if !caps.skills.isEmpty {
                            skillSection(caps.skills)
                        }
                    }
                } else {
                    loadingCard
                }
            }
            .desirePagePadding()
            .padding(.vertical, 12)
        }
        .background(DesireUI.pageFill.ignoresSafeArea())
        .navigationTitle("工具与技能")
        .navigationBarTitleDisplayMode(.inline)
        .task { client.requestCapabilities() }
        .refreshable { client.requestCapabilities() }
    }

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在从 Mac 读取能力清单…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .desireCard()
    }

    private func summaryCard(_ caps: RemoteCapabilities) -> some View {
        HStack(spacing: 8) {
            DesireStatTile(icon: "wrench.and.screwdriver", title: "工具",
                           value: "\(caps.tools.count)")
            DesireStatTile(icon: "book", title: "技能", value: "\(caps.skills.count)")
            DesireStatTile(
                icon: "shield.lefthalf.filled", title: "需确认",
                value: "\(caps.tools.filter { $0.risk != "readonly" }.count)",
                tint: .orange)
        }
    }

    private func groups(_ caps: RemoteCapabilities) -> [(String, [RemoteToolInfo])] {
        Self.groupOrder
            .map { (title, key) in (title, caps.tools.filter { $0.risk == key }) }
            .filter { !$0.1.isEmpty }
    }

    private func toolSection(title: String, tools: [RemoteToolInfo]) -> some View {
        DesireSection(
            title: title,
            subtitle: riskSubtitle(title)
        ) {
            ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                if index > 0 { DesireRowDivider() }
                toolRow(tool)
            }
        }
    }

    private func riskSubtitle(_ title: String) -> String {
        switch title {
        case "只读安全": "自动执行，不打断你"
        case "改变状态": "每次调用前请你确认"
        default: "每次都单独确认，不提供「始终允许」"
        }
    }

    private func toolRow(_ tool: RemoteToolInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: riskIcon(tool.risk))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(riskColor(tool.risk))
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesireUI.cardPadding)
        .padding(.vertical, 10)
    }

    private func riskIcon(_ risk: String) -> String {
        switch risk {
        case "readonly": "checkmark.circle.fill"
        case "dangerous": "exclamationmark.shield.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    private func riskColor(_ risk: String) -> Color {
        switch risk {
        case "readonly": .green
        case "dangerous": .red
        default: .orange
        }
    }

    private func skillSection(_ skills: [RemoteSkillInfo]) -> some View {
        DesireSection(
            title: "技能",
            subtitle: "Agent 可按需加载的操作说明（Mac 本地 skills 目录）"
        ) {
            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                if index > 0 { DesireRowDivider() }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "book.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesireUI.brand)
                        .frame(width: 18)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.name)
                            .font(.system(size: 13, weight: .semibold))
                        if !skill.description.isEmpty {
                            Text(skill.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesireUI.cardPadding)
                .padding(.vertical, 10)
            }
        }
    }
}
