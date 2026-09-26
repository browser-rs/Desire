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
