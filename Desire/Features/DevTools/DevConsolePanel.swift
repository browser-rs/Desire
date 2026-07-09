import SwiftUI

struct DevConsolePanel: View {
    @ObservedObject var store: DevToolsStore
    @State private var searchText = ""
    @State private var selectedLevel: ConsoleMessage.Level? = nil

    var filteredMessages: [ConsoleMessage] {
        var messages = store.consoleMessages
        if let level = selectedLevel {
            messages = messages.filter { $0.level == level }
        }
        if !searchText.isEmpty {
            messages = messages.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
        }
        return messages.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            consoleToolbar
            Divider()
            if filteredMessages.isEmpty {
                EmptyState(message: "No Console Messages")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredMessages) { message in
                            ConsoleMessageRow(message: message)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var consoleToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)

            TextField("Filter messages", text: $searchText)
                .textFieldStyle(.roundedBorder)

            levelFilterButton

            Spacer()

            Text("\(store.consoleMessages.count) messages")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if store.consoleErrorCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("\(store.consoleErrorCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                }
            }

            if store.consoleWarningCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("\(store.consoleWarningCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.yellow)
                }
            }

            Button {
                store.clearConsole()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Clear Console")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var levelFilterButton: some View {
        Menu {
            Button("All Levels") {
                selectedLevel = nil
            }
            ForEach(ConsoleMessage.Level.allCases, id: \.self) { level in
                Button(level.rawValue.capitalized) {
                    selectedLevel = level
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if let level = selectedLevel {
                    Text(level.rawValue.capitalized)
                        .font(.system(size: 11))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct ConsoleMessageRow: View {
    let message: ConsoleMessage

    private var levelIcon: String {
        switch message.level {
        case .log: return "circle"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        case .debug: return "ladybug.fill"
        }
    }

    private var levelColor: Color {
        switch message.level {
        case .log: return .secondary
        case .warn: return .yellow
        case .error: return .red
        case .info: return .blue
        case .debug: return .purple
        }
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: message.timestamp)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: levelIcon)
                .foregroundStyle(levelColor)
                .font(.system(size: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(message.message)
                    .font(.system(size: 12))
                    .textSelection(.enabled)

                if let url = message.url, let line = message.line {
                    HStack(spacing: 4) {
                        Text(url)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let column = message.column {
                            Text(":\(line):\(column)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(":\(line)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            Text(timeString)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(message.level == .error ? Color.red.opacity(0.08) : Color.clear)
        )
    }
}

#Preview {
    let store = DevToolsStore()
    store.addConsoleMessage(level: .log, message: "Hello, world!")
    store.addConsoleMessage(level: .warn, message: "This is a warning")
    store.addConsoleMessage(level: .error, message: "An error occurred", url: "https://example.com/script.js", line: 42)
    return DevConsolePanel(store: store)
        .frame(width: 400, height: 300)
}