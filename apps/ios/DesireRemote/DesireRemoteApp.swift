import SwiftUI

@main
struct DesireRemoteApp: App {
    @StateObject private var client = RemoteClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var client: RemoteClient

    var body: some View {
        switch client.phase {
        case .login:
            LoginView()
        case .devices:
            DevicesView()
        case .chat:
            ChatView()
        }
    }
}
