import SwiftUI

/// Agent Tab：桌面 Agent 面板的能力总入口。
///
/// 形态与「会话」「设置」两个 Tab 保持一致：`List(.insetGrouped)` +
/// `DesireSectionHeader` 分组的原生分组列表。此前这里是 ScrollView + 自绘卡片
/// （圆角 14、行距 18、分组标题字号都自成一套），三个 Tab 摆在一起风格不齐。
struct AgentHomeView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var confirmFullAccess = false
    @State private var confirmClear = false

    var body: some View {
        List {
            statusSection
            controlSection
            capabilitySection
            usageSection
            memorySection
            deviceSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.large)
        .task { client.requestModels() }
        // 每次切到本页都强制要一帧快照，避免状态停在"工作中"
        .onAppear { client.requestSync() }
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

    // MARK: - 状态

    private var statusSection: some View {
        Section {
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
            DesireValueRow(
                title: "上下文占用", value: "\(client.contextPercent)%",
                valueColor: contextColor, mono: true)
            DesireValueRow(
                title: "本对话 Token",
                value: client.tokens.map(DesireUI.formatTokens) ?? "—", mono: true)
            DesireValueRow(title: "本对话成本", value: client.cost ?? "—", mono: true)
        } header: {
            DesireSectionHeader(title: "状态")
        }
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
        return .secondary
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
        Section {
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
        } header: {
            DesireSectionHeader(title: "控制")
        }
    }

    /// 开启要二次确认（不可逆的风险方向），关闭直接生效。
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
        Section {
            NavigationLink {
                AgentCapabilitiesView()
            } label: {
                DesireNavRow(
                    icon: "sparkles.rectangle.stack",
                    title: "工具与技能",
                    subtitle: "全部可调用工具、风险分级与技能库",
                    showsChevron: false)
            }
        } header: {
            DesireSectionHeader(title: "能力")
        }
    }

    private var usageSection: some View {
        Section {
            NavigationLink {
                AgentStatsView()
            } label: {
                DesireNavRow(
                    icon: "chart.bar.xaxis",
                    title: "用量统计",
                    subtitle: "跨会话 token、成本与工具失败率",
                    showsChevron: false)
            }
            NavigationLink {
                AgentTraceView()
            } label: {
                DesireNavRow(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "执行轨迹",
                    subtitle: "当前对话每个回合做了什么、每步耗时",
                    showsChevron: false)
            }
        } header: {
            DesireSectionHeader(title: "用量")
        }
    }

    private var memorySection: some View {
        Section {
            NavigationLink {
                MemoryView()
            } label: {
                DesireNavRow(
                    icon: "brain.head.profile",
                    title: "Agent 记忆",
                    subtitle: "用户画像、长期事实与对话摘要",
                    showsChevron: false)
            }
        } header: {
            DesireSectionHeader(title: "记忆")
        }
    }

    private var deviceSection: some View {
        Section {
            DesireValueRow(title: "Mac", value: client.desktopName ?? "—")
            DesireValueRow(
                title: "账号",
                value: client.savedUsername.isEmpty ? "—" : client.savedUsername)
            DesireValueRow(
                title: "链路", value: client.connectionState,
                valueColor: connectionColor)
        } header: {
            DesireSectionHeader(title: "设备")
        }
    }
}
