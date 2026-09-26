import SwiftUI

@main
struct DesireRemoteApp: App {
    @StateObject private var client = RemoteClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { client.appForegrounded() }
                }
        }
    }
}
