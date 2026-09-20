import AppKit
import SwiftUI
import WebKit

/// 调试面板（Console / Network / Element，主窗口右侧分栏）。
///
/// 视觉规则（2026-09 美学轮，与下载面板同一套令牌）：
/// - 头部是真正的标签条：图标 + 名称 + 计数（计数只在 > 0 时出现，错误/失败
///   用红色），选中态是强调色底 + 强调色文字；右侧"清除/关闭"用统一的
///   `HoverIcon`，不再是无反馈的裸文字按钮。
/// - 过滤条：级别/类型用自绘图标分段控件（与下载面板同一观感，选中跟随强调色），
///   搜索框与下载面板同尺寸同圆角；总数用等宽数字右对齐。
/// - Console 行：等宽消息 + 等宽时间戳 + 来源 URL 三级层次；错误/警告保留极淡
///   底色以便扫读，分隔线内缩；hover 出现复制按钮（点按整行复制的行为保留）。
/// - Network：沿用原生 Table（排序/选择/滚动都是系统行为），只统一单元格观感
///   （方法用淡底彩字，状态等宽着色），并给详情区加与面板一致的小节标题。
/// - Element：分组从系统 `GroupBox`（灰底方框，与面板语言不符）改为面板自己的
///   小节样式；空态给出"选择元素"引导。
/// - 动效克制：hover `.hoverFast`、分段切换 `.controlSpring`。日志是流式插入的，
///   不做逐行动画（几百条时会有明显开销）。
struct DevToolsPanel: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: DevToolsStore
    var tab: Tab?
    var onStartElementPicker: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var consoleFilter: ConsoleMessage.Level? = nil
    @State private var networkFilter: NetworkRequest.ResourceType? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Content — clipped so long URLs / wide tables don't bleed
            // into the webview.
            switch store.activePanel {
            case .console:
                ConsolePanel(store: store, tab: tab, filter: $consoleFilter)
            case .network:
                NetworkPanel(store: store, tab: tab, filter: $networkFilter)
            case .element:
                ElementPanel(store: store, tab: tab, onStartElementPicker: onStartElementPicker)
            case .application:
                ApplicationPanel(store: store, tab: tab)
            }
        }
        .clipped()
        // 面板所在标签页 → store（`.current` 作用域靠它解析）。标签页切换、
        // 以及面板首次出现时都要写，否则作用域会停在旧标签页上。
        .onChange(of: tab?.id, initial: true) { _, newValue in
            store.activeTabID = newValue
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(DevToolsStore.DevPanel.allCases, id: \.self) { panel in
                tabButton(panel)
            }

            Spacer(minLength: 8)

            HoverIcon(systemName: "eraser", action: {
                // 清除跟随当前作用域：作用域是"某个标签页"时只清它的日志
                // （看到的和清掉的是同一批），"全部标签页"才清全部。
                switch store.activePanel {
                case .console: store.clearConsoleInScope()
                case .network: store.clearNetworkRequestsInScope()
                case .element: store.inspectedElement = nil
                case .application: break   // 应用页签各自带"清空"（两步确认），不走这里
                }
            }, help: "Clear")

            if let onClose {
                HoverIcon(systemName: "xmark", action: onClose, help: "Close")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func tabButton(_ panel: DevToolsStore.DevPanel) -> some View {
        let selected = store.activePanel == panel
        return Button {
            store.setActivePanel(panel)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: panel.icon)
                    .font(.system(size: 10.5, weight: .medium))
                Text(panel.title)
                    .font(.system(size: 11.5, weight: .medium))
                if let count = badgeCount(for: panel), count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(panel.hasProblems(in: store) ? Color.red : Color.secondary)
                }
            }
            .foregroundStyle(selected ? appAccent : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: .radiusButton)
                    .fill(selected ? appAccent.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(panel.title)
    }

    private func badgeCount(for panel: DevToolsStore.DevPanel) -> Int? {
        switch panel {
        case .console: store.consoleErrorCount + store.consoleWarningCount
        case .network: store.networkFailedCount
        case .element, .application: nil
        }
    }
}

// MARK: - Panel presentation

private extension DevToolsStore.DevPanel {
    /// 面板名（本地化；`rawValue` 仍作身份用）。
    var title: String {
        switch self {
        case .console: String(localized: "Console")
        case .network: String(localized: "Network")
        case .element: String(localized: "Element")
        case .application: String(localized: "Application")
        }
    }

    var icon: String {
        switch self {
        case .console: "terminal"
        case .network: "arrow.left.arrow.right"
        case .element: "viewfinder"
        case .application: "shippingbox"
        }
    }

    /// 计数徽章是否该用红色（错误/警告/失败）。
    func hasProblems(in store: DevToolsStore) -> Bool {
        switch self {
        case .console: store.consoleErrorCount > 0 || store.consoleWarningCount > 0
        case .network: store.networkFailedCount > 0
        case .element, .application: false
        }
    }
}

private extension ConsoleMessage.Level {
    var title: String {
        switch self {
        case .error: String(localized: "Errors")
        case .warn: String(localized: "Warnings")
        case .info: String(localized: "Info")
        case .debug: String(localized: "Debug")
        case .log: String(localized: "Log")
        }
    }

    var icon: String {
        switch self {
        case .error: "xmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        case .debug: "ladybug.fill"
        case .log: "text.alignleft"
        }
    }

    var tint: Color {
        switch self {
        case .error: .red
        case .warn: .orange
        case .info: .blue
        case .debug: .purple
        case .log: .secondary
        }
    }

    /// 极淡的行底色：只在错误/警告上保留，方便扫读。
    var rowWash: Color {
        switch self {
        case .error: Color.red.opacity(0.06)
        case .warn: Color.orange.opacity(0.05)
        default: Color.clear
        }
    }
}

private extension NetworkRequest.ResourceType {
    var title: String {
        switch self {
        case .document: String(localized: "Doc")
        case .script: String(localized: "JS")
        case .stylesheet: String(localized: "CSS")
        case .image: String(localized: "Img")
        case .xhr: String(localized: "XHR")
        case .fetch: "Fetch"
        case .websocket: "WS"
        case .font, .media, .other: rawValue.capitalized
        }
    }

    var icon: String {
        switch self {
        case .document: "doc.text"
        case .script: "curlybraces"
        case .stylesheet: "paintbrush"
        case .image: "photo"
        case .xhr: "arrow.left.arrow.right"
        case .fetch: "arrow.down.circle"
        case .websocket: "bolt.horizontal"
        case .font: "textformat"
        case .media: "play.rectangle"
        case .other: "ellipsis.circle"
        }
    }
}

// MARK: - Shared pieces

/// 自绘图标分段控件（与下载面板同一观感，选中态跟随强调色）。
private struct IconSegmentedControl<Item: Hashable>: View {
    @Environment(\.appAccent) private var appAccent: Color
    /// 选项里可以含 `nil`（表示"全部"）。
    let items: [Item?]
    let icon: (Item?) -> String
    let title: (Item?) -> String
    @Binding var selection: Item?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let selected = selection == item
                Button {
                    selection = item
                } label: {
                    Image(systemName: icon(item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? appAccent : .secondary)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                                .shadow(color: .black.opacity(selected ? 0.22 : 0), radius: 1.5, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(title(item))
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: .radiusButton)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .animation(.controlSpring, value: selection)
    }
}

/// 面板内的小节标题（Network 详情、Element 分组共用）：小字 + 细线。
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.10))
                .frame(height: 0.5)
        }
    }
}

/// 过滤条里统一的搜索框（26pt、圆角 6、controlBackground）。
private struct PanelSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: .radiusButton)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

/// 标签页作用域菜单（Console / Network 共用）。
///
/// 面板的数据源是 app 级共享 store：所有标签页、容器、无痕窗口的日志都进
/// 同一个数组。默认只看**当前标签页**，需要时切到"全部标签页"（多标签联调）
/// 或某个具体标签页（含已关闭的——它留下的日志还在这里）。Chrome 对应的是
/// Console 左上角那个 context 下拉。
private struct TabScopeMenu: View {
    @ObservedObject var store: DevToolsStore

    var body: some View {
        Menu {
            Picker(String(localized: "Tab Scope"), selection: $store.tabScope) {
                Text(String(localized: "Current Tab"))
                    .tag(DevToolsStore.TabScope.current)
                Text(String(localized: "All Tabs"))
                    .tag(DevToolsStore.TabScope.all)
                ForEach(store.knownTabs) { ref in
                    Text(store.displayName(for: ref))
                        .tag(DevToolsStore.TabScope.tab(ref.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 10))
                Text(scopeLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .frame(minWidth: 78, maxWidth: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tab Scope")
    }

    /// 菜单标题：当前标签页显示它的标题（比"当前标签页"更有信息量）。
    private var scopeLabel: String {
        switch store.tabScope {
        case .current:
            if let id = store.activeTabID,
               let ref = store.knownTabs.first(where: { $0.id == id }) {
                return store.displayName(for: ref)
            }
            return String(localized: "Current Tab")
        case .all:
            return String(localized: "All Tabs")
        case .tab(let id):
            if let ref = store.knownTabs.first(where: { $0.id == id }) {
                return store.displayName(for: ref)
            }
            return String(id.uuidString.prefix(8))
        }
    }
}

// MARK: - Console Panel

private struct ConsolePanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: DevToolsStore
    /// REPL 要在页面里执行 JS，需要目标 webview。
    var tab: Tab?
    @Binding var filter: ConsoleMessage.Level?
    @State private var searchText = ""
    @State private var copiedMessageId: UUID?
    @State private var expandedMessageIDs: Set<UUID> = []
    /// 折叠连续重复消息（Chrome 同款）：同一级别 + 同一文本算一组，显示 ×N。
    @State private var collapseRepeats = true
    /// 搜索按正则解释（写错就当普通文本，不弹错）。
    @State private var regexSearch = false
    @State private var input = ""
    @State private var inputHistory: [String] = []
    @State private var historyIndex: Int?
    @FocusState private var inputFocused: Bool

    private var levels: [ConsoleMessage.Level?] { [nil, .error, .warn, .info] }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filteredMessages.isEmpty {
                EmptyState(
                    title: String(localized: "No console messages"),
                    systemImage: "terminal",
                    description: String(localized: "Page console output appears here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messageList
            }
            if tab != nil {
                Divider()
                inputBar
            }
        }
    }

    /// 控制台输入行（REPL）：↵ 执行，↑/↓ 翻历史。执行结果/异常会作为日志行
    /// 追加在上方列表里（见 `DevToolsStore.evaluateConsoleInput`）。
    private var inputBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(appAccent)
            TextField("Run JavaScript in the page…", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($inputFocused)
                .onSubmit(runInput)
                .onKeyPress(.upArrow) {
                    guard !inputHistory.isEmpty else { return .ignored }
                    let next = historyIndex.map { max(0, $0 - 1) } ?? (inputHistory.count - 1)
                    historyIndex = next
                    input = inputHistory[next]
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard let index = historyIndex else { return .ignored }
                    if index + 1 >= inputHistory.count {
                        historyIndex = nil
                        input = ""
                    } else {
                        historyIndex = index + 1
                        input = inputHistory[index + 1]
                    }
                    return .handled
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func runInput() {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, let webView = tab?.browser.webView else { return }
        inputHistory.append(source)
        if inputHistory.count > 100 { inputHistory.removeFirst(inputHistory.count - 100) }
        historyIndex = nil
        input = ""
        Task { await store.evaluateConsoleInput(source, in: webView, tabID: tab?.id) }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            TabScopeMenu(store: store)

            IconSegmentedControl(
                items: levels,
                icon: { $0?.icon ?? "line.3.horizontal" },
                title: { $0?.title ?? String(localized: "All") },
                selection: $filter
            )

            PanelSearchField(placeholder: String(localized: "Filter messages…"), text: $searchText)

            repeatToggle
            regexToggle
            clearOnNavigateToggle

            HoverIcon(systemName: "square.and.arrow.down", action: exportLog, help: "Export Log")

            Text("\(filteredMessages.count)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var regexToggle: some View {
        Button {
            regexSearch.toggle()
        } label: {
            Image(systemName: "textformat.abc.dottedunderline")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(regexSearch ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(regexSearch ? appAccent.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Regex Search")
    }

    private var clearOnNavigateToggle: some View {
        Button {
            store.clearConsoleOnNavigate.toggle()
        } label: {
            Image(systemName: store.clearConsoleOnNavigate ? "eraser.line.dashed.fill" : "eraser.line.dashed")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(store.clearConsoleOnNavigate ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(store.clearConsoleOnNavigate ? appAccent.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear on Navigate")
    }

    private var repeatToggle: some View {
        Button {
            collapseRepeats.toggle()
        } label: {
            Image(systemName: collapseRepeats ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(collapseRepeats ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(collapseRepeats ? appAccent.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Collapse Repeats")
    }

    /// 把当前（过滤后的）日志导出成文本文件并选中它——排查问题时比截图有用。
    private func exportLog() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let body = filteredMessages.map { message in
            let stamp = formatter.string(from: message.timestamp)
            let source = message.url.map { " (\($0)\(message.line.map { ":\($0)" } ?? ""))" } ?? ""
            return "[\(stamp)] [\(message.level.rawValue)] \(message.message)\(source)"
        }.joined(separator: "\n")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
            .appendingPathComponent("desire-console-\(stamp).log")
        guard let url else { return }
        try? body.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(displayMessages, id: \.message.id) { entry in
                        messageRow(entry.message, repeatCount: entry.count)
                        Rectangle()
                            .fill(Color.secondary.opacity(0.10))
                            .frame(height: 0.5)
                            .padding(.leading, 26)
                    }
                    Color.clear.frame(height: 1).id("__console_bottom__")
                }
            }
            .onChange(of: store.consoleMessages.count) { _, _ in
                withAnimation { proxy.scrollTo("__console_bottom__", anchor: .bottom) }
            }
        }
    }

    /// 折叠重复后的显示条目（Chrome 语义：同级别 + 同文本合并，保留**首次**出现
    /// 的位置，时间显示**最新**一次，附 ×N）。关掉就是原始逐条。
    private var displayMessages: [(message: ConsoleMessage, count: Int)] {
        let messages = filteredMessages
        guard collapseRepeats else { return messages.map { ($0, 1) } }
        var order: [String] = []
        var grouped: [String: (message: ConsoleMessage, count: Int)] = [:]
        for message in messages {
            let key = "\(message.level.rawValue)\u{1}\(message.message)"
            if var existing = grouped[key] {
                existing.count += 1
                existing.message = ConsoleMessage(level: message.level, message: message.message, url: message.url, line: message.line, column: message.column, tabID: message.tabID)
                grouped[key] = existing
            } else {
                grouped[key] = (message, 1)
                order.append(key)
            }
        }
        return order.compactMap { grouped[$0] }
    }

    private var filteredMessages: [ConsoleMessage] {
        // 先按标签页作用域收敛，再按级别/搜索过滤。
        var messages = store.scopedConsoleMessages
        if let filter = filter {
            messages = messages.filter { $0.level == filter }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            if regexSearch, let regex = try? NSRegularExpression(pattern: q, options: [.caseInsensitive]) {
                messages = messages.filter { message in
                    let range = NSRange(message.message.startIndex..., in: message.message)
                    return regex.firstMatch(in: message.message, options: [], range: range) != nil
                }
            } else {
                let lowered = q.lowercased()
                messages = messages.filter { $0.message.lowercased().contains(lowered) }
            }
        }
        return messages
    }

    private func messageRow(_ message: ConsoleMessage, repeatCount: Int = 1) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: message.level.icon)
                .font(.system(size: 10))
                .foregroundStyle(message.level.tint)
                .frame(width: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(message.message)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(expandedMessageIDs.contains(message.id) ? nil : 8)
                    .animation(.hoverFast, value: expandedMessageIDs.contains(message.id))

                if let url = message.url {
                    Text(url)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        // 窄面板下 middle 截断只剩 "https"，尾部截断至少保住域名。
                        .truncationMode(.tail)
                }
            }

            if repeatCount > 1 {
                Text("×\(repeatCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
            }

            Spacer(minLength: 4)

            Text(message.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)

            Image(systemName: copiedMessageId == message.id ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copiedMessageId == message.id ? AnyShapeStyle(appAccent) : AnyShapeStyle(.tertiary))
                .opacity(copiedMessageId == message.id ? 1 : 0)
                .frame(width: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { copy(message) }
        .contextMenu {
            Button(expandedMessageIDs.contains(message.id)
                   ? String(localized: "Collapse")
                   : String(localized: "Expand")) {
                if expandedMessageIDs.contains(message.id) {
                    expandedMessageIDs.remove(message.id)
                } else {
                    expandedMessageIDs.insert(message.id)
                }
            }
            Button("Copy") { copy(message) }
        }
        .background(
            copiedMessageId == message.id
                ? appAccent.opacity(0.10)
                : message.level.rowWash
        )
        .help("Copy")
    }

    private func copy(_ message: ConsoleMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.message, forType: .string)
        copiedMessageId = message.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedMessageId = nil }
    }
}

// MARK: - Network Panel

private struct NetworkPanel: View {
    @ObservedObject var store: DevToolsStore
    var tab: Tab?
    @Binding var filter: NetworkRequest.ResourceType?
    @State private var selectedRequest: NetworkRequest.ID?
    @State private var sortOrder: [KeyPathComparator<NetworkRequest>] = []
    @State private var searchText = ""
    @State private var onlyFailures = false

    private var kinds: [NetworkRequest.ResourceType?] {
        [nil, .document, .script, .stylesheet, .image, .xhr]
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

            if filteredRequests.isEmpty {
                EmptyState(
                    title: String(localized: "No requests captured"),
                    systemImage: "arrow.left.arrow.right",
                    description: String(localized: "Network activity of this page appears here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            TabScopeMenu(store: store)

            IconSegmentedControl(
                items: kinds,
                icon: { $0?.icon ?? "line.3.horizontal" },
                title: { $0?.title ?? String(localized: "All") },
                selection: $filter
            )

            PanelSearchField(placeholder: String(localized: "Filter URLs…"), text: $searchText)
                .frame(maxWidth: 200)

            failuresToggle

            Spacer(minLength: 4)

            // 汇总：条数 + 传输字节（排查"页面为什么慢/重"第一眼要看的数）。
            Text("\(filteredRequests.count) · \(formatBytes(networkTotals))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Menu {
                Button("Copy All URLs") {
                    copyToPasteboard(filteredRequests.map(\.url).joined(separator: "\n"))
                }
                Button("Copy All as cURL") {
                    copyToPasteboard(filteredRequests.map { Self.curlCommand(for: $0) }.joined(separator: "\n\n"))
                }
                Divider()
                Button("Export Log…") {
                    _ = store.exportNetworkLog(filteredRequests)
                }
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Copy")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 只看失败（4xx/5xx 或标记失败）——排查"页面报错但控制台干净"时最常用。
    private var failuresToggle: some View {
        Button {
            onlyFailures.toggle()
        } label: {
            Image(systemName: onlyFailures ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(onlyFailures ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(onlyFailures ? Color.red.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Only Failures")
    }

    private var networkTotals: Int64 {
        filteredRequests.reduce(0) { $0 + ($1.size ?? 0) }
    }

    private var table: some View {
        VStack(spacing: 0) {
            Table(filteredRequests.sorted(using: sortOrder), selection: $selectedRequest, sortOrder: $sortOrder) {
                TableColumn("Method") { request in
                    Text(request.method)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(methodColor(request.method))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: .radiusBadge)
                                .fill(methodColor(request.method).opacity(0.14))
                        )
                }
                .width(min: 40, ideal: 52)

                TableColumn("Status", sortUsing: KeyPathComparator(\NetworkRequest.sortStatusCode)) { request in
                    statusCell(request.statusCode)
                }
                .width(min: 36, ideal: 44)

                TableColumn("URL", sortUsing: KeyPathComparator(\NetworkRequest.url)) { request in
                    HStack(spacing: 4) {
                        cacheBadge(request.fromCache)
                        Text(request.url)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                TableColumn("Size", sortUsing: KeyPathComparator(\NetworkRequest.sortSize)) { request in
                    sizeCell(request.size)
                }
                .width(min: 48, ideal: 60)

                TableColumn("Time", sortUsing: KeyPathComparator(\NetworkRequest.sortDuration)) { request in
                    waterfallCell(request)
                }
                .width(min: 90, ideal: 140)
            }
            .frame(minHeight: 120)

            if let id = selectedRequest,
               let request = store.networkRequests.first(where: { $0.id == id }) {
                Divider()
                requestDetail(request)
                    .frame(maxHeight: 220)
            }
        }
    }

    @ViewBuilder
    private func requestDetail(_ r: NetworkRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(r.method)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(methodColor(r.method))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: .radiusBadge)
                                .fill(methodColor(r.method).opacity(0.14))
                        )
                    Text(r.url)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let code = r.statusCode {
                        Text("\(code)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(statusColor(code))
                    }
                    Button {
                        if let webView = tab?.browser.webView {
                            Task { await store.replayRequest(r, in: webView) }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Replay")

                    Menu {
                        Button("Copy") { copyToPasteboard(r.url) }
                        Button("Copy as cURL") { copyToPasteboard(Self.curlCommand(for: r)) }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Copy")
                }

                if let timing = r.timing, hasTiming(timing) {
                    PanelSection(title: String(localized: "Timing")) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(timingRows(timing), id: \.0) { label, value in
                                HStack(spacing: 4) {
                                    Text(label).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                                    Text(value)
                                        .monospacedDigit()
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 10.5, design: .monospaced))
                            }
                        }
                    }
                }

                if let headers = r.requestHeaders, !headers.isEmpty {
                    headerSection(String(localized: "Request Headers"), headers)
                }
                if let body = r.requestBody, !body.isEmpty {
                    PanelSection(title: String(localized: "Request Body")) {
                        bodyText(body)
                    }
                }
                if let headers = r.responseHeaders, !headers.isEmpty {
                    headerSection(String(localized: "Response Headers"), headers)
                }
                if let body = r.responseBody, !body.isEmpty {
                    PanelSection(title: String(localized: "Response Body")) {
                        bodyText(body, request: r)
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity)
    }

    private func hasTiming(_ timing: NetworkRequest.Timing) -> Bool {
        [timing.blocked, timing.dns, timing.connect, timing.tls, timing.ttfb, timing.download]
            .contains { ($0 ?? 0) > 0 }
    }

    private func timingRows(_ timing: NetworkRequest.Timing) -> [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ label: String, _ value: Double?) {
            guard let value, value > 0 else { return }
            rows.append((String(localized: String.LocalizationValue(label)), "\(Int(value * 1000))ms"))
        }
        add("Queued", timing.blocked)
        add("DNS", timing.dns)
        add("Connect", timing.connect)
        add("TLS", timing.tls)
        add("TTFB", timing.ttfb)
        add("Download", timing.download)
        return rows
    }

    /// body 文本：能解析成 JSON 就美化（排查接口时最常看的东西），并提供复制。
    @ViewBuilder
    private func bodyText(_ body: String, request: NetworkRequest? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(prettyJSON(body))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(24)
            HStack(spacing: 8) {
                Button("Copy") { copyToPasteboard(body) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if let request {
                    Button("Save to File") { _ = store.saveResponseBody(request) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }

    private func headerSection(_ title: String, _ headers: [String: String]) -> some View {
        PanelSection(title: title) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(headers.keys.sorted()), id: \.self) { key in
                    HStack(alignment: .top, spacing: 4) {
                        Text(key)
                            .foregroundStyle(.secondary)
                        Text(headers[key] ?? "")
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private func statusCell(_ status: Int?) -> some View {
        if let status {
            Text("\(status)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(statusColor(status))
        } else {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func sizeCell(_ size: Int64?) -> some View {
        if let size, size > 0 {
            Text(formatBytes(size))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// 缓存命中徽章（transferSize 为 0 但解出了内容）——性能排查的关键信号。
    @ViewBuilder
    private func cacheBadge(_ fromCache: Bool?) -> some View {
        if fromCache == true {
            Text(String(localized: "Cache"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.teal)
                .padding(.horizontal, 4)
                .padding(.vertical, 0.5)
                .background(Capsule().fill(Color.teal.opacity(0.16)))
        }
    }

    /// 时间列 = 相对起始位置的瀑布条 + 时长文本（Chrome 同款阅读方式）。
    @ViewBuilder
    private func waterfallCell(_ request: NetworkRequest) -> some View {
        let (origin, span) = waterfallSpan
        let offset = request.startTime.timeIntervalSince(origin)
        let duration = request.duration ?? 0
        HStack(spacing: 5) {
            GeometryReader { geo in
                let barWidth = max(2, geo.size.width * (duration / span))
                let barOffset = max(0, geo.size.width * (offset / span))
                Capsule()
                    .fill(request.failed ? AnyShapeStyle(.red) : AnyShapeStyle(statusTint(request.statusCode)))
                    .frame(width: min(barWidth, max(2, geo.size.width - barOffset)))
                    .offset(x: min(barOffset, geo.size.width - 2))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 4)

            if duration > 0 {
                Text("\(Int(duration * 1000))ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusTint(_ status: Int?) -> Color {
        guard let status else { return .secondary }
        return statusColor(status)
    }

    private var filteredRequests: [NetworkRequest] {
        // 先按标签页作用域收敛，再按类型/搜索/失败过滤。
        var requests = store.scopedNetworkRequests
        if let filter { requests = requests.filter { $0.resourceType == filter } }
        if onlyFailures {
            requests = requests.filter { $0.failed || ($0.statusCode ?? 0) >= 400 }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            requests = requests.filter { $0.url.lowercased().contains(query) }
        }
        return requests
    }

    /// 瀑布条的时间基准（当前可见请求里最早/最晚），用于按比例画横条。
    private var waterfallSpan: (start: Date, span: TimeInterval) {
        let starts = filteredRequests.map(\.startTime)
        guard let first = starts.min(), let lastEnd = filteredRequests.compactMap(\.endTime).max() else {
            return (Date(), 1)
        }
        let span = max(0.05, lastEnd.timeIntervalSince(first))
        return (first, span)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 复制成可直接跑的 cURL（含方法与请求头；body 以单引号包住）。
    private static func curlCommand(for request: NetworkRequest) -> String {
        var parts = ["curl -X \(request.method)"]
        parts.append("'\(request.url)'")
        for (key, value) in (request.requestHeaders ?? [:]).sorted(by: { $0.key < $1.key }) {
            parts.append("-H '\(key): \(value)'")
        }
        if let body = request.requestBody, !body.isEmpty {
            parts.append("--data '\(body.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        return parts.joined(separator: " ")
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

// MARK: - Application Panel

/// Cookie / localStorage / sessionStorage / 扩展存储 —— Chrome DevTools 的
/// Application 页签最常用的那一块。Cookie 读的是**当前标签页所在的
/// `WKWebsiteDataStore`**（所以容器/无痕标签看到的是自己的那份，HttpOnly 也在内），
/// Web 存储走页面 JS（可改可增可删），扩展存储走插件的 `chrome.storage.local`
/// （`WebExtensionStore` 后端）。
private struct ApplicationPanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: DevToolsStore
    var tab: Tab?

    @State private var cookies: [CookieEntry] = []
    @State private var storageItems: [DevToolsStore.StorageItem] = []
    @State private var extensions: [DevToolsStore.ExtensionSnapshot] = []
    @State private var searchText = ""
    @State private var confirmClear = false
    @State private var copiedKey: String?
    /// Cookie 默认只看当前站点（devtools 语义）；打开这个开关才列出整个数据存储。
    @State private var allDomains = false
    /// 正在编辑的行 id（存储项 / 扩展存储项），以及草稿值。
    @State private var editingKey: String?
    @State private var draftValue = ""
    /// 新增行归属："web" = 当前页的 Web 存储，"ext:<extID>" = 某插件；nil = 未展开。
    @State private var addingFor: String?
    @State private var newName = ""
    @State private var newValue = ""

    private var section: DevToolsStore.ApplicationSection { store.applicationSection }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            switch section {
            case .extensionStorage:
                extensionList
            default:
                if visibleRows.isEmpty {
                    EmptyState(
                        title: emptyTitle,
                        systemImage: section.icon,
                        description: emptyDescription
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
        }
        .task(id: refreshToken) { await reload() }
    }

    private var refreshToken: String {
        "\(section.rawValue)|\(tab?.id.uuidString ?? "-")"
    }

    // MARK: Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            IconSegmentedControl(
                items: DevToolsStore.ApplicationSection.allCases,
                icon: { $0?.icon ?? "shippingbox" },
                title: { $0?.title ?? "" },
                selection: Binding(
                    get: { store.applicationSection },
                    set: { if let value = $0 { store.applicationSection = value; confirmClear = false; addingFor = nil; editingKey = nil } }
                )
            )

            PanelSearchField(placeholder: String(localized: "Filter…"), text: $searchText)

            if section == .cookies {
                Button {
                    allDomains.toggle()
                } label: {
                    Image(systemName: allDomains ? "globe" : "globe.americas")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(allDomains ? AnyShapeStyle(appAccent) : AnyShapeStyle(.secondary))
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(allDomains ? appAccent.opacity(0.14) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("All Domains")
            }

            Spacer(minLength: 4)

            Text("\(rowCount)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            if section.isEditable {
                HoverIcon(systemName: "plus", action: { beginAdd(addingFor == "web" ? nil : "web") }, help: "Add")
            }

            HoverIcon(systemName: "arrow.clockwise", action: { Task { await reload() } }, help: "Reload")

            // 清空：按一下变"确认"，3 秒后自动复原（不用模态框，避免挡住自动化桥）。
            Button {
                if confirmClear {
                    Task { await clearAll() }
                } else {
                    confirmClear = true
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        confirmClear = false
                    }
                }
            } label: {
                Text(confirmClear ? String(localized: "Confirm?") : String(localized: "Clear"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(confirmClear ? Color.red : Color.secondary)
                    .padding(.horizontal, confirmClear ? 8 : 4)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(confirmClear ? Color.red.opacity(0.14) : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Rows

    private struct Row: Identifiable {
        let id: String
        let name: String
        let value: String
        let detail: String
        let flags: [String]
        /// 非 nil = 扩展存储项（属于这个插件）。
        var extID: String?
        var editable = false
    }

    private struct ExtensionGroup: Identifiable {
        let id: String
        let name: String
        let rows: [Row]
        let total: Int
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var visibleRows: [Row] {
        let q = query
        switch section {
        case .cookies:
            let host = tab?.browser.webView.url?.host?.lowercased()
            return cookies
                .filter { cookie in
                    guard allDomains || host == nil else {
                        let domain = cookie.domain.lowercased().hasPrefix(".") ? String(cookie.domain.dropFirst().lowercased()) : cookie.domain.lowercased()
                        // `.youtube.com` 对 `www.youtube.com` 有效，反向也放行（父域 Cookie）。
                        return domain.hasSuffix(host!) || host!.hasSuffix(domain)
                    }
                    return true
                }
                .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.domain.lowercased().contains(q) }
                .map { cookie in
                    var flags: [String] = []
                    if cookie.isSecure { flags.append("Secure") }
                    if cookie.isHttpOnly { flags.append("HttpOnly") }
                    if let sameSite = cookie.sameSitePolicy { flags.append(sameSite.capitalized) }
                    if cookie.expiryDate == nil { flags.append(String(localized: "Session")) }
                    return Row(
                        id: "\(cookie.domain)|\(cookie.path)|\(cookie.name)",
                        name: cookie.name,
                        value: cookie.value,
                        detail: "\(cookie.domain)\(cookie.path)",
                        flags: flags
                    )
                }
        case .localStorage, .sessionStorage, .extensionStorage:
            return storageItems
                .filter { q.isEmpty || $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
                .map { item in
                    Row(id: item.key, name: item.key, value: item.value, detail: "", flags: ["\(item.bytes) B"], editable: true)
                }
        }
    }

    private var extensionGroups: [ExtensionGroup] {
        let q = query
        return extensions.compactMap { ext in
            let rows = ext.items
                .filter { q.isEmpty || $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
                .sorted { $0.key < $1.key }
                .map { key, value in
                    Row(
                        id: "\(ext.id)|\(key)",
                        name: key,
                        value: value,
                        detail: "",
                        flags: ["\(value.count) B"],
                        extID: ext.id,
                        editable: true
                    )
                }
            // 搜索时只留有命中的插件；不搜索时全部保留（空插件也要能往里加键）。
            if !q.isEmpty, rows.isEmpty, !ext.name.lowercased().contains(q) { return nil }
            return ExtensionGroup(id: ext.id, name: ext.name, rows: rows, total: ext.items.count)
        }
    }

    private var rowCount: Int {
        section == .extensionStorage ? extensionGroups.reduce(0) { $0 + $1.rows.count } : visibleRows.count
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visibleRows) { row in
                    rowView(row)
                    rowSeparator
                }
                if section.storageKind != nil {
                    addFooter(owner: "web")
                }
            }
        }
    }

    private var extensionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if extensionGroups.isEmpty {
                    EmptyState(
                        title: String(localized: "No extension storage"),
                        systemImage: "puzzlepiece.extension",
                        description: String(localized: "Plugins that use chrome.storage.local show their keys here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(extensionGroups) { group in
                        extensionHeader(group)
                        ForEach(group.rows) { row in
                            rowView(row)
                            rowSeparator
                        }
                        addFooter(owner: "ext:\(group.id)")
                    }
                }
            }
        }
    }

    private func extensionHeader(_ group: ExtensionGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 10))
                .foregroundStyle(AnyShapeStyle(appAccent))
            Text(group.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text("\(group.rows.count)/\(group.total)")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06))
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.10))
            .frame(height: 0.5)
            .padding(.leading, 12)
    }

    /// "+ 新增一项"：展开两个输入框；扩展存储按插件分别展开。
    @ViewBuilder
    private func addFooter(owner: String) -> some View {
        if addingFor == owner {
            HStack(spacing: 4) {
                TextField("name", text: $newName)
                    .textFieldStyle(.plain)
                    .frame(width: 110)
                Text("=").foregroundStyle(.tertiary)
                TextField("value", text: $newValue)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await commitNew(owner: owner) } }
                Button("Add") { Task { await commitNew(owner: owner) } }
                    .buttonStyle(.plain)
                    .foregroundStyle(appAccent)
                Button {
                    beginAdd(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
            .font(.system(size: 10.5, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        } else {
            Button {
                beginAdd(owner)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 8.5, weight: .bold))
                    Text("Add Key")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func beginAdd(_ owner: String?) {
        addingFor = owner
        newName = ""
        newValue = ""
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    ForEach(row.flags, id: \.self) { flag in
                        Text(flag)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                }
                if row.editable, editingKey == row.id {
                    TextField("", text: $draftValue)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, design: .monospaced))
                        .onSubmit { Task { await commit(row) } }
                        .onExitCommand { editingKey = nil }
                } else {
                    Text(row.value)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .onTapGesture {
                            guard row.editable else { return }
                            draftValue = row.value
                            editingKey = row.id
                        }
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                if row.editable {
                    Button {
                        draftValue = row.value
                        editingKey = editingKey == row.id ? nil : row.id
                    } label: {
                        Image(systemName: editingKey == row.id ? "pencil.circle.fill" : "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(editingKey == row.id ? AnyShapeStyle(appAccent) : AnyShapeStyle(.tertiary))
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit Value")
                }

                Button {
                    copyToPasteboard("\(row.name)=\(row.value)")
                    copiedKey = row.id
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copiedKey = nil
                    }
                } label: {
                    Image(systemName: copiedKey == row.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copiedKey == row.id ? AnyShapeStyle(appAccent) : AnyShapeStyle(.tertiary))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy")

                Button {
                    Task { await delete(row) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            .opacity(isHoveringRow(row.id) ? 1 : 0.35)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredRow = row.id } else if hoveredRow == row.id { hoveredRow = nil }
        }
        .contextMenu {
            Button("Copy") { copyToPasteboard("\(row.name)=\(row.value)") }
            if section == .cookies {
                Button("Copy as document.cookie") {
                    copyToPasteboard("\(row.name)=\(row.value)")
                }
            }
            if row.editable {
                Button("Edit Value") {
                    draftValue = row.value
                    editingKey = row.id
                }
            }
            Divider()
            Button("Delete", role: .destructive) { Task { await delete(row) } }
        }
    }

    @State private var hoveredRow: String?
    private func isHoveringRow(_ id: String) -> Bool { hoveredRow == id }

    // MARK: Data

    private var emptyTitle: String {
        switch section {
        case .cookies: String(localized: "No cookies for this tab")
        case .localStorage, .sessionStorage: String(localized: "No storage entries")
        case .extensionStorage: String(localized: "No extension storage")
        }
    }

    private var emptyDescription: String? {
        switch section {
        case .cookies: String(localized: "Cookies of this tab's data store (containers/private tabs have their own).")
        case .localStorage, .sessionStorage: String(localized: "Keys of this page's storage — add or edit them here.")
        case .extensionStorage: nil
        }
    }

    private func reload() async {
        switch section {
        case .cookies:
            guard let dataStore = tab?.browser.webView.configuration.websiteDataStore else { return }
            cookies = await store.loadCookies(in: dataStore)
        case .localStorage, .sessionStorage:
            guard let webView = tab?.browser.webView, let kind = section.storageKind else { return }
            storageItems = await store.loadWebStorage(kind: kind, in: webView)
        case .extensionStorage:
            extensions = store.extensionStorageSnapshots()
        }
    }

    /// 提交某行编辑后的值（存储项 → 页面 localStorage/setItem；扩展项 → chrome.storage.local）。
    private func commit(_ row: Row) async {
        if let extID = row.extID {
            store.setExtensionStorageValue(pluginID: extID, key: row.name, value: draftValue)
        } else if let webView = tab?.browser.webView, let kind = section.storageKind {
            await store.setStorageItem(kind: kind, key: row.name, value: draftValue, in: webView)
        }
        editingKey = nil
        await reload()
    }

    /// 新增一行（owner: "web" 或 "ext:<extID>"）。
    private func commitNew(owner: String) async {
        let key = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if owner.hasPrefix("ext:") {
            let extID = String(owner.dropFirst(4))
            store.setExtensionStorageValue(pluginID: extID, key: key, value: newValue)
        } else if let webView = tab?.browser.webView, let kind = section.storageKind {
            await store.setStorageItem(kind: kind, key: key, value: newValue, in: webView)
        }
        beginAdd(nil)
        await reload()
    }

    private func delete(_ row: Row) async {
        if let extID = row.extID {
            store.setExtensionStorageValue(pluginID: extID, key: row.name, value: nil)
        } else {
            switch section {
            case .cookies:
                guard let dataStore = tab?.browser.webView.configuration.websiteDataStore,
                      let cookie = cookies.first(where: { "\($0.domain)|\($0.path)|\($0.name)" == row.id }) else { return }
                await store.deleteCookie(name: cookie.name, domain: cookie.domain, path: cookie.path, in: dataStore)
            case .localStorage, .sessionStorage:
                guard let webView = tab?.browser.webView, let kind = section.storageKind else { return }
                await store.removeStorageItem(kind: kind, key: row.name, in: webView)
            case .extensionStorage:
                return
            }
        }
        await reload()
    }

    private func clearAll() async {
        switch section {
        case .cookies:
            guard let dataStore = tab?.browser.webView.configuration.websiteDataStore else { return }
            await store.clearCookies(in: dataStore)
        case .localStorage, .sessionStorage:
            guard let webView = tab?.browser.webView, let kind = section.storageKind else { return }
            await store.removeStorageItem(kind: kind, key: nil, in: webView)
        case .extensionStorage:
            let ids = extensionGroups.map(\.id)
            for extID in ids {
                let snap = extensions.first { $0.id == extID }
                for key in snap?.items.keys.sorted() ?? [] {
                    store.setExtensionStorageValue(pluginID: extID, key: key, value: nil)
                }
            }
        }
        confirmClear = false
        await reload()
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Element Panel

private struct ElementPanel: View {
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: DevToolsStore
    var tab: Tab?
    var onStartElementPicker: (() -> Void)?

    /// 正在编辑的行（"style:名称" / "attr:名称"），以及新增行是否展开。
    @State private var editingKey: String?
    @State private var draftValue = ""
    @State private var addingStyle = false
    @State private var addingAttribute = false
    @State private var newName = ""
    @State private var newValue = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let element = store.inspectedElement {
                    PanelSection(title: String(localized: "Element")) {
                        VStack(alignment: .leading, spacing: 4) {
                            infoRow("Tag", value: element.tagName)
                            infoRow("Selector", value: element.selector)
                            if let cssPath = element.cssPath {
                                infoRow("CSS Path", value: cssPath)
                            }
                            if let xpath = element.xpath {
                                infoRow("XPath", value: xpath)
                            }
                            HStack(spacing: 6) {
                                smallAction("square.on.square", help: "Copy Selector") {
                                    copyToPasteboard(element.selector)
                                }
                                if let cssPath = element.cssPath {
                                    smallAction("point.topleft.down.to.point.bottomright.curvepath", help: "Copy CSS Path") {
                                        copyToPasteboard(cssPath)
                                    }
                                }
                                smallAction("chevron.left.forwardslash.chevron.right", help: "Copy HTML") {
                                    copyToPasteboard(element.outerHTML)
                                }
                                smallAction("scope", help: "Flash in Page") {
                                    flash(selector: element.selector)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }

                    if !element.innerHTML.isEmpty {
                        PanelSection(title: "Inner HTML") {
                            Text(element.innerHTML)
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(10)
                                .textSelection(.enabled)
                        }
                    }

                    PanelSection(title: String(localized: "Attributes")) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(element.attributes.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                                editableRow(
                                    rowKey: "attr:\(key)",
                                    name: key,
                                    value: value,
                                    element: element
                                )
                            }
                            addRow(kind: "attr", isAdding: $addingAttribute, element: element)
                        }
                    }

                    PanelSection(title: "CSS Properties") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(element.cssProperties, id: \.name) { prop in
                                editableRow(
                                    rowKey: "style:\(prop.name)",
                                    name: prop.name,
                                    value: prop.value,
                                    element: element,
                                    important: prop.important
                                )
                            }
                            addRow(kind: "style", isAdding: $addingStyle, element: element)
                        }
                    }

                    if let box = element.boundingBox, box.width > 0 || box.height > 0 {
                        PanelSection(title: String(localized: "Box Model")) {
                            boxModelDiagram(element.computedStyle)
                        }
                    }

                    if !element.computedStyle.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(element.computedStyle.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    HStack(alignment: .top, spacing: 4) {
                                        Text(key).foregroundStyle(.primary)
                                        Text(":").foregroundStyle(.tertiary)
                                        Text(value)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    .font(.system(size: 10.5, design: .monospaced))
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("Computed Style (\(element.computedStyle.count))")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 2)
                    }

                    if let box = element.boundingBox {
                        PanelSection(title: "Bounding Box") {
                            VStack(alignment: .leading, spacing: 3) {
                                infoRow("x", value: String(format: "%.1f", box.x))
                                infoRow("y", value: String(format: "%.1f", box.y))
                                infoRow("width", value: String(format: "%.1f", box.width))
                                infoRow("height", value: String(format: "%.1f", box.height))
                            }
                        }
                    }
                } else {
                    VStack(spacing: 14) {
                        EmptyState(
                            title: String(localized: "No element inspected"),
                            systemImage: "viewfinder",
                            description: String(localized: "Pick an element to see its tag, CSS and box model.")
                        )
                        if tab != nil, let onStartElementPicker {
                            Button {
                                onStartElementPicker()
                            } label: {
                                Text("Pick Element")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(appAccent.opacity(0.14)))
                                    .foregroundStyle(appAccent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(12)
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    /// 盒模型示意（margin → border → padding → content），数值取计算样式。
    @ViewBuilder
    private func boxModelDiagram(_ style: [String: String]) -> some View {
        let margin = style["margin"] ?? ""
        let padding = style["padding"] ?? ""
        let border = style["border"] ?? ""
        VStack(spacing: 2) {
            diagramLayer(String(localized: "Margin"), margin, color: .orange)
            VStack(spacing: 2) {
                diagramLayer(String(localized: "Border"), border, color: .yellow)
                VStack(spacing: 2) {
                    diagramLayer(String(localized: "Padding"), padding, color: .green)
                    Text(String(localized: "Content"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 3).fill(Color.blue.opacity(0.14))
                        )
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.10)))
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.yellow.opacity(0.10)))
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.10)))
    }

    private func diagramLayer(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color)
            if !value.isEmpty, value != "0px" {
                Text(value)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// 可编辑的一行（属性 / 内联样式）：点值进入编辑、回车提交、旁边给删除。
    @ViewBuilder
    private func editableRow(rowKey: String, name: String, value: String, element: InspectedElement, important: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name).foregroundStyle(.primary)
            Text(important ? ":" : ":").foregroundStyle(.tertiary)
            if editingKey == rowKey {
                TextField("", text: $draftValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced))
                    .onSubmit {
                        Task { await commit(rowKey: rowKey, name: name, element: element) }
                    }
                    .onExitCommand { editingKey = nil }
            } else {
                Text(value)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .onTapGesture {
                        draftValue = value
                        editingKey = rowKey
                    }
            }
            if important {
                Text("!important").foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            Button {
                Task { await remove(rowKey: rowKey, name: name, element: element) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .font(.system(size: 10.5, design: .monospaced))
        .onHover { hovering in
            guard let webView = tab?.browser.webView else { return }
            store.highlightElement(selector: element.selector, on: hovering, in: webView)
        }
    }

    /// "+ 新增一行"：展开两个输入框（名称 / 值）。
    @ViewBuilder
    private func addRow(kind: String, isAdding: Binding<Bool>, element: InspectedElement) -> some View {
        if isAdding.wrappedValue {
            HStack(spacing: 4) {
                TextField("name", text: $newName)
                    .textFieldStyle(.plain)
                    .frame(width: 90)
                Text("=").foregroundStyle(.tertiary)
                TextField("value", text: $newValue)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await commitNew(kind: kind, element: element, isAdding: isAdding) } }
                Button("Add") { Task { await commitNew(kind: kind, element: element, isAdding: isAdding) } }
                    .buttonStyle(.plain)
                    .foregroundStyle(appAccent)
            }
            .font(.system(size: 10.5, design: .monospaced))
        } else {
            Button {
                newName = ""
                newValue = ""
                isAdding.wrappedValue = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add")
        }
    }

    private func commit(rowKey: String, name: String, element: InspectedElement) async {
        guard let webView = tab?.browser.webView else { return }
        if rowKey.hasPrefix("style:") {
            await store.setElementStyle(selector: element.selector, name: name, value: draftValue, in: webView)
        } else {
            await store.setElementAttribute(selector: element.selector, name: name, value: draftValue, in: webView)
        }
        editingKey = nil
    }

    private func remove(rowKey: String, name: String, element: InspectedElement) async {
        guard let webView = tab?.browser.webView else { return }
        if rowKey.hasPrefix("style:") {
            await store.setElementStyle(selector: element.selector, name: name, value: nil, in: webView)
        } else {
            await store.setElementAttribute(selector: element.selector, name: name, value: nil, in: webView)
        }
    }

    private func commitNew(kind: String, element: InspectedElement, isAdding: Binding<Bool>) async {
        guard let webView = tab?.browser.webView else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if kind == "style" {
            await store.setElementStyle(selector: element.selector, name: name, value: newValue, in: webView)
        } else {
            await store.setElementAttribute(selector: element.selector, name: name, value: newValue, in: webView)
        }
        isAdding.wrappedValue = false
    }

    private func smallAction(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: .radiusBadge)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 在页面上闪一下选中元素的描边——比对着 selector 找快得多。
    private func flash(selector: String) {
        guard let webView = tab?.browser.webView else { return }
        let escaped = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript("""
        (function() {
            var el = document.querySelector('\(escaped)');
            if (!el) return;
            var previous = el.style.outline;
            el.style.outline = '2px solid #FF2D55';
            el.style.outlineOffset = '2px';
            setTimeout(function() { el.style.outline = previous; el.style.outlineOffset = ''; }, 1200);
        })();
        """, completionHandler: nil)
    }
}

#Preview {
    DevToolsPanel(store: DevToolsStore())
        .frame(width: 420, height: 520)
}
