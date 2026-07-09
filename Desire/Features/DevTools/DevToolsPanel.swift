import SwiftUI

struct DevToolsPanel: View {
    @ObservedObject var store: DevToolsStore
    var tab: Tab?
    var onStartElementPicker: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var consoleFilter: ConsoleMessage.Level? = nil
    @State private var networkFilter: NetworkRequest.ResourceType? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header with tabs
            HStack(spacing: 0) {
                ForEach(DevToolsStore.DevPanel.allCases, id: \.self) { panel in
                    Button {
                        store.setActivePanel(panel)
                    } label: {
                        HStack(spacing: 6) {
                            Text(panel.rawValue)
                                .font(.system(size: 12, weight: .medium))

                            if panel == .console {
                                badge(store.consoleErrorCount + store.consoleWarningCount, color: .red)
                            } else if panel == .network {
                                badge(store.networkFailedCount, color: .red)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(store.activePanel == panel ? Color.accentColor.opacity(0.1) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if store.activePanel == .console {
                    Button("Clear") { store.clearConsole() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else if store.activePanel == .network {
                    Button("Clear") { store.clearNetworkRequests() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // Content
            switch store.activePanel {
            case .console:
                ConsolePanel(store: store, filter: $consoleFilter)
            case .network:
                NetworkPanel(store: store, filter: $networkFilter)
            case .element:
                ElementPanel(store: store, tab: tab, onStartElementPicker: onStartElementPicker)
            }
        }
        .frame(width: 800, height: 500)
    }

    @ViewBuilder
    private func badge(_ count: Int, color: Color) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Console Panel

private struct ConsolePanel: View {
    @ObservedObject var store: DevToolsStore
    @Binding var filter: ConsoleMessage.Level?

    var body: some View {
        VStack(spacing: 0) {
            // Filter
            HStack {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(nil as ConsoleMessage.Level?)
                    Text("Errors").tag(ConsoleMessage.Level.error as ConsoleMessage.Level?)
                    Text("Warnings").tag(ConsoleMessage.Level.warn as ConsoleMessage.Level?)
                    Text("Info").tag(ConsoleMessage.Level.info as ConsoleMessage.Level?)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Spacer()

                Text("\(filteredMessages.count) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Messages
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredMessages) { message in
                        consoleMessageRow(message)
                        Divider()
                    }
                }
            }
        }
    }

    private var filteredMessages: [ConsoleMessage] {
        guard let filter = filter else { return store.consoleMessages }
        return store.consoleMessages.filter { $0.level == filter }
    }

    private func consoleMessageRow(_ message: ConsoleMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: levelIcon(message.level))
                .foregroundStyle(levelColor(message.level))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.message)
                    .font(.system(size: 12, design: .monospaced))

                if let url = message.url {
                    Text(url)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(levelBackgroundColor(message.level))
    }

    private func levelIcon(_ level: ConsoleMessage.Level) -> String {
        switch level {
        case .error: return "xmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .log: return "text.alignleft"
        case .debug: return "ladybug"
        }
    }

    private func levelColor(_ level: ConsoleMessage.Level) -> Color {
        switch level {
        case .error: return .red
        case .warn: return .orange
        case .info: return .blue
        case .log: return .secondary
        case .debug: return .purple
        }
    }

    private func levelBackgroundColor(_ level: ConsoleMessage.Level) -> Color {
        switch level {
        case .error: return Color.red.opacity(0.05)
        case .warn: return Color.orange.opacity(0.05)
        case .debug: return Color.purple.opacity(0.05)
        default: return Color.clear
        }
    }
}

// MARK: - Network Panel

private struct NetworkPanel: View {
    @ObservedObject var store: DevToolsStore
    @Binding var filter: NetworkRequest.ResourceType?

    var body: some View {
        VStack(spacing: 0) {
            // Filter
            HStack {
                Picker("Filter", selection: $filter) {
                    Text("All").tag(nil as NetworkRequest.ResourceType?)
                    Text("Document").tag(NetworkRequest.ResourceType.document as NetworkRequest.ResourceType?)
                    Text("Script").tag(NetworkRequest.ResourceType.script as NetworkRequest.ResourceType?)
                    Text("Stylesheet").tag(NetworkRequest.ResourceType.stylesheet as NetworkRequest.ResourceType?)
                    Text("Image").tag(NetworkRequest.ResourceType.image as NetworkRequest.ResourceType?)
                    Text("XHR").tag(NetworkRequest.ResourceType.xhr as NetworkRequest.ResourceType?)
                }
                .pickerStyle(.segmented)
                .frame(width: 400)

                Spacer()

                Text("\(filteredRequests.count) requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Requests
            Table(filteredRequests) {
                TableColumn("Method") { request in
                    Text(request.method)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(methodColor(request.method))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .width(min: 60, max: 80)

                TableColumn("Status") { request in
                    if let status = request.statusCode {
                        Text("\(status)")
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor(status))
                    } else if request.failed {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .width(min: 50, max: 70)

                TableColumn("Type") { request in
                    Text(request.resourceType.rawValue)
                        .font(.caption)
                }
                .width(min: 80, max: 100)

                TableColumn("URL") { request in
                    Text(request.url)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }

                TableColumn("Time") { request in
                    if let duration = request.duration {
                        Text("\(Int(duration * 1000))ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, max: 80)
            }
        }
    }

    private var filteredRequests: [NetworkRequest] {
        guard let filter = filter else { return store.networkRequests }
        return store.networkRequests.filter { $0.resourceType == filter }
    }

    private func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "DELETE": return .red
        case "PATCH": return .purple
        default: return .secondary
        }
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        case 500..<600: return .red
        default: return .secondary
        }
    }
}

// MARK: - Element Panel

private struct ElementPanel: View {
    @ObservedObject var store: DevToolsStore
    var tab: Tab?
    var onStartElementPicker: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let element = store.inspectedElement {
                    GroupBox("Element Information") {
                        VStack(alignment: .leading, spacing: 8) {
                            infoRow("Tag", value: element.tagName)
                            infoRow("Selector", value: element.selector)
                            if let xpath = element.xpath {
                                infoRow("XPath", value: xpath)
                            }
                        }
                        .padding(8)
                    }

                    if !element.innerHTML.isEmpty {
                        GroupBox("Inner HTML") {
                            Text(element.innerHTML)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(10)
                                .padding(8)
                        }
                    }

                    if !element.attributes.isEmpty {
                        GroupBox("Attributes") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(element.attributes.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                                    HStack {
                                        Text(key)
                                            .font(.caption.bold())
                                        Text("=")
                                        Text(value)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }

                    if !element.cssProperties.isEmpty {
                        GroupBox("CSS Properties") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(element.cssProperties, id: \.name) { prop in
                                    HStack {
                                        Text(prop.name)
                                            .font(.caption.bold())
                                        Text(":")
                                        Text(prop.value)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if prop.important {
                                            Text("!important")
                                                .font(.caption2)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                            .padding(8)
                        }
                    }

                    if let box = element.boundingBox {
                        GroupBox("Bounding Box") {
                            VStack(alignment: .leading, spacing: 4) {
                                infoRow("x", value: String(format: "%.1f", box.x))
                                infoRow("y", value: String(format: "%.1f", box.y))
                                infoRow("width", value: String(format: "%.1f", box.width))
                                infoRow("height", value: String(format: "%.1f", box.height))
                            }
                            .padding(8)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        EmptyState(message: "No element inspected")

                        if let tab = tab, let onStartElementPicker = onStartElementPicker {
                            Button {
                                onStartElementPicker()
                            } label: {
                                Label("Pick Element", systemImage: "scope")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding()
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption.bold())
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview {
    DevToolsPanel(store: DevToolsStore())
}