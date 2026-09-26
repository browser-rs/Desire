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
}

/// 会话 Tab：列表 → push 对话页。对话页自身隐藏 TabBar（全屏聊天）。
struct SessionsTab: View {
    @EnvironmentObject var client: RemoteClient
    @State private var path: [String] = []

    /// 新建对话的 route 占位值：点"新建"时 Mac 还没回来会话 id（`newSession`
    /// 之后的第一帧快照才带），而对话页本来就读 client 状态，不需要真 id。
    private static let newConversationRoute = "__new__"

    var body: some View {
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
}
