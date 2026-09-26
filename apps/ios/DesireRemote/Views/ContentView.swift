import SwiftUI

/// 根视图：相位切换（登录 / 主页面）。
/// 主页面照 IrsClawApp ContentView：NavigationStack 根 = ChatView，
/// toolbar 左 ≡（DrawerMenu sheet）右 ✎ ⚙；Menu 磁贴经 navigationDestination
/// push 全屏页（会话 / 记忆 / 看板）。
struct RootView: View {
    @EnvironmentObject var client: RemoteClient

    /// 朱砂品牌色（与 Mac 端「欲」字印章一致）。深色模式提亮一档。
    static let brand = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.36, blue: 0.20, alpha: 1)
            : UIColor(red: 0.75, green: 0.23, blue: 0.10, alpha: 1)
    })

    var body: some View {
        Group {
            switch client.phase {
            case .login:
                LoginView()
            case .main:
                MainView()
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .tint(Self.brand)
        .preferredColorScheme(client.preferredColorScheme)
    }
}

/// 已登录主页面。未配对时根内容为连接引导（ConnectMacView），
/// 已配对为聊天页——toolbar 恒在，功能任何状态可达。
enum DrawerDestination: Hashable {
    case sessions
    case memory
    case board
}

struct MainView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var drawerPath = NavigationPath()
    @State private var showingDrawer = false
    @State private var showingSettings = false
    @State private var showQRLogin = false

    var body: some View {
        NavigationStack(path: $drawerPath) {
            Group {
                if client.hasSavedPairing {
                    ChatView()
                } else {
                    ConnectMacView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingDrawer = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 16, weight: .medium))
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if client.hasSavedPairing {
                        Button {
                            client.newSession()
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 15, weight: .medium))
                        }
                    }
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                    }
                }
            }
            .navigationDestination(for: DrawerDestination.self) { destination in
                switch destination {
                case .sessions:
                    SessionListView()
                        .navigationTitle("会话")
                case .memory:
                    MemoryView()
                        .navigationTitle("记忆")
                case .board:
                    AgentBoardView()
                        .navigationTitle("Agent 看板")
                }
            }
        }
        .sheet(isPresented: $showingDrawer) {
            DrawerMenuView { destination in
                drawerPath.append(destination)
            } onQRLogin: {
                showQRLogin = true
            } onSettings: {
                showingSettings = true
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(client.preferredColorScheme)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(client.preferredColorScheme)
        }
        .sheet(isPresented: $showQRLogin) {
            QRLoginScanSheet()
                .preferredColorScheme(client.preferredColorScheme)
        }
    }
}

// MARK: - 抽屉 Menu（Agent 卡 + Browse 磁贴 + 最近会话）

struct DrawerMenuView: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    let onNavigate: (DrawerDestination) -> Void
    let onQRLogin: () -> Void
    let onSettings: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    agentCard
                    navigationGrid
                    if !client.sessions.isEmpty {
                        recentSessionsSection
                    }
                }
                .padding()
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: Agent 卡（当前模型 + 连接状态 + 上下文）

    private var agentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [RootView.brand, RootView.brand.opacity(0.55)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 36, height: 36)
                    Image(systemName: "star.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.agentModel.isEmpty ? "未配置模型" : client.agentModel)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(connectionLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var connectionLine: String {
        var parts: [String] = [client.connectionState]
        if client.contextPercent > 0 { parts.append("上下文 \(client.contextPercent)%") }
        if client.queueCount > 0 { parts.append("排队 \(client.queueCount)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Browse 磁贴网格

    private var navigationGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("浏览")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                navigationCard(icon: "message.fill", title: "会话", color: .blue) {
                    dismiss(); onNavigate(.sessions)
                }
                navigationCard(icon: "brain.fill", title: "记忆", color: .green) {
                    dismiss(); onNavigate(.memory)
                }
                navigationCard(icon: "gauge.with.needle", title: "Agent 看板", color: .orange) {
                    dismiss(); onNavigate(.board)
                }
                navigationCard(icon: "qrcode.viewfinder", title: "扫码登录 Mac", color: .purple) {
                    dismiss(); onQRLogin()
                }
            }
        }
    }

    private func navigationCard(icon: String, title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 最近会话（前 5 + See All）

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近会话")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("查看全部") {
                    dismiss(); onNavigate(.sessions)
                }
                .font(.subheadline)
            }

            VStack(spacing: 0) {
                ForEach(Array(client.sessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                    Button {
                        client.selectSession(session.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "message.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(session.label)
                                .font(.body)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < min(5, client.sessions.count) - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
