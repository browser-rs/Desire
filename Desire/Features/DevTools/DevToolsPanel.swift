import SwiftUI

struct DevToolsPanel: View {
    @ObservedObject var store: DevToolsStore
    let tab: Tab
    let onStartElementPicker: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DevToolsBar(store: store)
            Divider()
            activePanelView
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var activePanelView: some View {
        switch store.activePanel {
        case .console:
            DevConsolePanel(store: store)
        case .network:
            NetworkMonitorPanel(store: store)
        case .element:
            ElementInspector(store: store, onStartPicking: onStartElementPicker)
        }
    }
}

#Preview {
    let store = DevToolsStore()
    store.addConsoleMessage(level: .log, message: "Hello, world!")
    return DevToolsPanel(store: store, tab: Tab(), onStartElementPicker: {})
        .frame(width: 400, height: 500)
}