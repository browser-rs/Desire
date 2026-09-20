import SwiftUI

struct DevToolsBar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: DevToolsStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DevToolsStore.DevPanel.allCases, id: \.self) { panel in
                panelButton(panel)
                if panel != DevToolsStore.DevPanel.allCases.last {
                    Divider()
                        .frame(width: 1)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .background(.bar)
    }

    private func panelButton(_ panel: DevToolsStore.DevPanel) -> some View {
        Button {
            store.setActivePanel(panel)
        } label: {
            HStack(spacing: 4) {
                panelIcon(panel)
                Text(panel.rawValue)
                    .font(.system(size: 12))
                panelBadge(panel)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 80)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(store.activePanel == panel ? appAccent.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func panelIcon(_ panel: DevToolsStore.DevPanel) -> some View {
        Group {
            switch panel {
            case .console:
                Image(systemName: "terminal")
            case .network:
                Image(systemName: "network")
            case .element:
                Image(systemName: "viewfinder")
            case .application:
                Image(systemName: "shippingbox")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(store.activePanel == panel ? appAccent : .secondary)
    }

    private func panelBadge(_ panel: DevToolsStore.DevPanel) -> some View {
        Group {
            switch panel {
            case .console:
                if store.consoleErrorCount > 0 {
                    Text("\(store.consoleErrorCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.2)))
                } else if store.consoleWarningCount > 0 {
                    Text("\(store.consoleWarningCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.yellow.opacity(0.2)))
                }
            case .network:
                if store.networkPendingCount > 0 {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else if store.networkFailedCount > 0 {
                    Text("\(store.networkFailedCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.2)))
                }
            case .application:
                EmptyView()
            case .element:
                EmptyView()
            }
        }
    }
}

#Preview {
    let store = DevToolsStore()
    store.addConsoleMessage(level: .error, message: "Error")
    store.addConsoleMessage(level: .warn, message: "Warning")
    store.addConsoleMessage(level: .warn, message: "Warning 2")
    _ = store.startNetworkRequest(url: "https://example.com", method: "GET", resourceType: .document)
    return VStack {
        DevToolsBar(store: store)
        Divider()
        Text("DevTools Panel Content")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 400, height: 300)
}