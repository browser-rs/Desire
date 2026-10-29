import SwiftUI

/// 专注模式的工作台（v0.8.23 第一批）：对话为主 + **可折叠的内嵌浏览面板**。
///
/// 折叠 = 面板视图移出层级（webview 仍存活，可导航/取文/执行 JS——spike
/// S1/S2 已验证）；展开 = Peek 的就地形式（不搬窗口、不抢焦点）。
struct AgentWorkspaceView: View {
    @Environment(\.appAccent) private var appAccent
    @ObservedObject var modeStore = AppModeStore.shared
    @ObservedObject var paneStore = AgentPaneManager.shared
    @ObservedObject var peek = PeekCenter.shared
    @ObservedObject var store: AgentSessionStore
    @ObservedObject var conversationStore: ConversationStore
    let content: ContentView
    var onExit: () -> Void

    @State private var paneExpanded = false
    /// 面板是因为 Peek 自动展开的（结束时自动收回；用户手动展开的不动）。
    @State private var peekAutoExpanded = false

    private var pane: TabManager? { paneStore.manager }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let request = peek.active {
                peekBanner(request)
            }
            Divider()
            HStack(spacing: 0) {
                AgentPanel(store: store, conversationStore: conversationStore, promptCenter: store.promptCenter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if paneExpanded, let pane {
                    Divider()
                    paneColumn(pane)
                        .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { AgentPaneManager.shared.ensure() }
        .onChange(of: peek.active?.id) { _, newID in
            if newID != nil {
                if !paneExpanded { peekAutoExpanded = true }
                withAnimation(.easeInOut(duration: 0.18)) { paneExpanded = true }
            } else if peekAutoExpanded {
                withAnimation(.easeInOut(duration: 0.18)) { paneExpanded = false }
                peekAutoExpanded = false
            }
        }
    }

    private func peekBanner(_ request: PeekRequest) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(appAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Agent needs your help"))
                    .font(.system(size: 11.5, weight: .semibold))
                Text(request.reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(String(localized: "Done")) {
                PeekCenter.shared.resolve(completed: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(String(localized: "Dismiss")) {
                PeekCenter.shared.resolve(completed: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(appAccent.opacity(0.08))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appAccent)
            Text(String(localized: "Agent Workspace"))
                .font(.system(size: 13, weight: .semibold))
            if let pane {
                let current = pane.selectedTab?.displayTitle ?? String(localized: "New Tab")
                let count = String(localized: "\(pane.tabs.count) tab(s) in the background")
                Text("\(current) · \(count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    paneExpanded.toggle()
                }
                if paneExpanded { AgentPaneManager.shared.ensure() }
            } label: {
                Label(paneExpanded
                      ? String(localized: "Hide Browser")
                      : String(localized: "Show Browser"),
                      systemImage: paneExpanded
                      ? "rectangle.compress.vertical"
                      : "rectangle.expand.vertical")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(pane == nil && false)
            Button(String(localized: "Back to Browsing")) {
                onExit()
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(appAccent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func paneColumn(_ pane: TabManager) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        Button {
                            pane.selectTab(at: index)
                        } label: {
                            Text(tab.displayTitle.isEmpty ? String(localized: "New Tab") : tab.displayTitle)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(
                                    index == pane.selectedIndex
                                    ? appAccent.opacity(0.16)
                                    : Color.secondary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        pane.addTab(javaScriptEnabled: content.settings.isJavaScriptEnabled,
                                    contentBlocker: content.contentBlocker,
                                    videoAdBlocker: content.videoAdBlocker,
                                    makeActive: true)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            Divider()
            if let tab = pane.selectedTab {
                content.makeWebView(for: tab, manager: pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(String(localized: "No agent tabs"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
