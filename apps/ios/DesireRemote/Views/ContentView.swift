import Combine
import SwiftUI

/// 根视图：相位切换（登录 / 主界面）。
///
/// 信息架构（重做后）：主界面 = 底部 TabView 四个一级入口
/// 「对话 / 会话 / Agent / 设置」——此前是一个 Drawer 抽屉塞磁贴，
/// 功能入口分散且层级混乱。聊天窗口保持独立，其余页面全部重做。
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
    case chat
    case sessions
    case agent
    case settings
}

/// Tab 之间的跳转（例如在会话列表里选中一条后自动回到对话页）。
final class AppTabRouter: ObservableObject {
    @Published var tab: AppTab = .chat
}

/// 已登录主界面：配对后进入四 Tab 工作台；未配对时只显示连接引导
/// （此时任何 Tab 里的功能都无数据可依，不如把配对这一件事做清楚）。
struct MainView: View {
    @EnvironmentObject var client: RemoteClient
    @StateObject private var router = AppTabRouter()

    var body: some View {
        if client.hasSavedPairing {
            TabView(selection: $router.tab) {
                NavigationStack {
                    ChatView()
                }
                .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(AppTab.chat)

                NavigationStack {
                    SessionListView()
                }
                .tabItem { Label("会话", systemImage: "clock.arrow.circlepath") }
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
            .environmentObject(router)
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
