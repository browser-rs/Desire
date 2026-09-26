import SwiftUI

/// Agent Tab：桌面 Agent 面板的能力总入口。
///
/// 取代原来的「Agent 看板」——那个页面只是把 5 个数字排成 List，没有任何
/// 可操作项、也没有通往桌面那 5 个子页（记忆/历史/统计/轨迹/能力）的入口。
/// 现在这一页 = 状态总览 + 会话控制 + 能力/用量/记忆/设备四组入口。
struct AgentHomeView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var confirmFullAccess = false
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                statusCard
                controlSection
                capabilitySection
                usageSection
                memorySection
                deviceSection
            }
            .desirePagePadding()
            .padding(.vertical, 12)
        }
        .background(DesireUI.pageFill.ignoresSafeArea())
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.large)
        .task { client.requestModels() }
        .refreshable {
            client.requestModels()
            client.requestSync()
        }
        .confirmationDialog("开启 FULL ACCESS？", isPresented: $confirmFullAccess, titleVisibility: .visible) {
            Button("开启 FULL ACCESS", role: .destructive) { client.setFullAccess(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有工具都不再逐一确认，包括在页面上执行任意 JavaScript。\n只在完全信任当前任务时开启。")
        }
        .alert("开始新对话？", isPresented: $confirmClear) {
            Button("新对话", role: .destructive) { client.clearConversation() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前对话会被清空（Mac 会先把这段对话的记忆摘要沉淀下来）。")
        }
    }

    // MARK: - 状态总览

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DesireIconBadge(icon: "sparkles", size: 40, filled: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.agentModel.isEmpty ? "未配置模型" : client.agentModel)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(connectionColor)
                            .frame(width: 7, height: 7)
                        Text(runStateText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if client.fullAccess {
                    Text("FULL ACCESS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                }
            }

            Divider()

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                DesireStatTile(
                    icon: "gauge.medium", title: "上下文",
                    value: "\(client.contextPercent)%", tint: contextColor)
                DesireStatTile(
                    icon: "text.word.spacing", title: "Token",
                    value: client.tokens.map(DesireUI.formatTokens) ?? "—")
                DesireStatTile(
                    icon: "dollarsign.circle", title: "成本",
                    value: client.cost ?? "—")
            }
        }
        .desireCard()
    }

    private var connectionColor: Color {
        if client.connectionState.contains("断开") || client.connectionState.contains("重连") {
            return .red
        }
        if !client.desktopOnline { return .orange }
        return .green
    }

    private var contextColor: Color {
        if client.contextPercent >= 85 { return .red }
        if client.contextPercent >= 60 { return .orange }
        return DesireUI.brand
    }

    private var runStateText: String {
        if client.paused { return "已暂停 · 等待继续" }
        if client.busy {
            return client.elapsedSeconds.map { "工作中 · \($0)s" } ?? "工作中"
        }
        return client.connectionState
    }

    // MARK: - 控制

    private var controlSection: some View {
        DesireSection(title: "控制") {
            HStack(spacing: 8) {
                if client.busy {
                    controlButton(
                        client.paused ? "继续" : "暂停",
                        icon: client.paused ? "play.fill" : "pause.fill",
                        tint: client.paused ? .green : .orange
                    ) {
                        client.paused ? client.resumeTurn() : client.pauseTurn()
                    }
                    controlButton("停止", icon: "stop.fill", tint: .red) {
                        client.sendCancel()
                    }
                }
                controlButton("新对话", icon: "plus.bubble", tint: DesireUI.brand) {
                    confirmClear = true
                }
            }
            .padding(.horizontal, DesireUI.cardPadding)
            .padding(.vertical, 12)

            DesireRowDivider()

            HStack(spacing: 10) {
                DesireIconBadge(
                    icon: "bolt.shield.fill",
                    tint: client.fullAccess ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FULL ACCESS")
                        .font(.system(size: 15, weight: .medium))
                    Text(client.fullAccess ? "所有工具免审批（含执行代码）" : "工具调用前会请你确认")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: fullAccessBinding)
                    .labelsHidden()
                    .tint(.orange)
            }
            .padding(.horizontal, DesireUI.cardPadding)
            .padding(.vertical, 11)
        }
    }

    /// 开启要二次确认（不可逆风险方向），关闭直接生效。
    private var fullAccessBinding: Binding<Bool> {
        Binding(
            get: { client.fullAccess },
            set: { newValue in
                if newValue {
                    confirmFullAccess = true
                } else {
                    client.setFullAccess(false)
                }
            })
    }

    private func controlButton(
        _ title: String, icon: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DesireUI.chipCorner, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 能力 / 用量 / 记忆 / 设备

    private var capabilitySection: some View {
        DesireSection(
            title: "能力",
            subtitle: "手机能指挥 Mac 上的 Agent 做什么"
        ) {
            DesireNavLink(
                icon: "sparkles.rectangle.stack",
                title: "工具与技能",
                subtitle: "全部可调用工具、风险分级与技能库"
            ) {
                AgentCapabilitiesView()
            }
        }
    }

    private var usageSection: some View {
        DesireSection(title: "用量") {
            DesireNavLink(
                icon: "chart.bar.xaxis",
                title: "用量统计",
                subtitle: "跨会话 token、成本与工具失败率"
            ) {
                AgentStatsView()
            }
            DesireRowDivider()
            DesireNavLink(
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                title: "执行轨迹",
                subtitle: "当前对话每个回合做了什么、每步耗时"
            ) {
                AgentTraceView()
            }
        }
    }

    private var memorySection: some View {
        DesireSection(title: "记忆") {
            DesireNavLink(
                icon: "brain.head.profile",
                title: "Agent 记忆",
                subtitle: "用户画像、长期事实与对话摘要"
            ) {
                MemoryView()
            }
        }
    }

    private var deviceSection: some View {
        DesireSection(title: "设备") {
            VStack(spacing: 10) {
                DesireValueRow(title: "Mac", value: client.desktopName ?? "—")
                DesireValueRow(title: "账号", value: client.savedUsername.isEmpty ? "—" : client.savedUsername)
                DesireValueRow(title: "链路", value: client.connectionState, valueColor: connectionColor)
            }
            .padding(.horizontal, DesireUI.cardPadding)
            .padding(.vertical, 12)
        }
    }
}
