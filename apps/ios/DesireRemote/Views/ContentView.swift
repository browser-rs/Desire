import SwiftUI

/// 根视图：相位切换（登录 / 主界面）。
///
/// 信息架构：主界面 = 底部 TabView「会话 / Agent / 设置」三个一级入口。
/// **对话不是一个 Tab** —— 它从会话列表 push 进去，并在进入后隐藏 TabBar
/// （全屏聊天）。此前把"对话"也做成 Tab，"会话列表"和"对话"两个入口语义
/// 重叠，且聊天页底部还被 TabBar 压住一截。
struct RootView: View {
    @EnvironmentObject var client: RemoteClient

    /// 朱砂品牌色（唯一来源见 `DesireUI.brand`）。
    static var brand: Color { DesireUI.brand }

    var body: some View {
        Group {
            switch client.phase {
            case .login:
                LoginView()
            case .main:
                MainView()
            }
        }
        .background(DesireUI.pageFill.ignoresSafeArea())
        .tint(DesireUI.brand)
        .preferredColorScheme(client.preferredColorScheme)
    }
}

/// 一级 Tab。
enum AppTab: Hashable {
    case sessions
    case agent
    case settings
}

/// 已登录主界面：配对后进入三 Tab 工作台；未配对时只显示连接引导
/// （此时任何 Tab 里的功能都无数据可依，不如把配对这一件事做清楚）。
struct MainView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var tab: AppTab = .sessions

    var body: some View {
        if client.hasSavedPairing {
            VStack(spacing: 0) {
                if !client.desktopOnline || client.connectionState.contains("重连") {
                    connectionBanner
                }
                TabView(selection: $tab) {
                    SessionsTab()
                        .tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right.fill") }
                        .tag(AppTab.sessions)

                    NavigationStack {
                        AgentHomeView()
                    }
                    .tabItem { Label("Agent", systemImage: "sparkles") }
                    .tag(AppTab.agent)

                    NavigationStack {
                        SettingsView()
                    }
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
                    .tag(AppTab.settings)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenSession)) { _ in
                tab = .sessions
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenJobs)) { _ in
                tab = .agent
            }
        } else {
            NavigationStack {
                ConnectMacView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 15, weight: .medium))
                            }
                        }
                    }
            }
        }
    }

    /// 断线/离线状态条（v0.8.38 批三）：此前只有聊天页状态行里一行小字，
    /// 断网时用户以为"发出去没人回"。
    private var connectionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: client.desktopOnline
                  ? "arrow.triangle.2.circlepath" : "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
            Text(bannerText)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("重试") { client.requestSync() }
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(client.desktopOnline ? Color.orange : Color.red.opacity(0.9))
    }

    private var bannerText: String {
        if client.desktopOnline {
            return "正在重连 Mac…"
        }
        if let last = client.lastOnlineAt {
            return "Mac 离线 · 最后在线 \(last.formatted(.relative(presentation: .named)))"
        }
        return "Mac 离线 · 恢复连接后会自动补发排队消息"
    }
}

/// 会话 Tab：列表 → push 对话页。对话页自身隐藏 TabBar（全屏聊天）。
/// iPad 横屏/分屏（regular）改为 NavigationSplitView：左会话、右对话。
struct SessionsTab: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [String] = []
    @State private var splitSelection: String?

    /// 新建对话的 route 占位值：点"新建"时 Mac 还没回来会话 id（`newSession`
    /// 之后的第一帧快照才带），而对话页本来就读 client 状态，不需要真 id。
    private static let newConversationRoute = "__new__"

    var body: some View {
        Group {
            if sizeClass == .regular {
                splitLayout
            } else {
                stackLayout
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteOpenSession)) { note in
            guard let session = note.object as? String, !session.isEmpty else { return }
            if session != client.selectedSessionID { client.selectSession(session) }
            if sizeClass == .regular {
                splitSelection = session
            } else if !path.contains(session) {
                path.append(session)
            }
        }
    }

    private var stackLayout: some View {
        NavigationStack(path: $path) {
            SessionListView(
                onOpen: { id in
                    if id != client.selectedSessionID { client.selectSession(id) }
                    path.append(id)
                },
                onNew: {
                    client.newSession()
                    path.append(Self.newConversationRoute)
                })
                .navigationDestination(for: String.self) { _ in
                    ChatView()
                }
        }
    }

    private var splitLayout: some View {
        NavigationSplitView {
            SessionListView(
                onOpen: { id in
                    if id != client.selectedSessionID { client.selectSession(id) }
                    splitSelection = id
                },
                onNew: {
                    client.newSession()
                    splitSelection = Self.newConversationRoute
                })
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            if splitSelection != nil {
                ChatView()
            } else {
                DesireEmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "选择一个会话",
                    message: "左侧选择 Mac 上的对话，或点右上角新建。")
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
