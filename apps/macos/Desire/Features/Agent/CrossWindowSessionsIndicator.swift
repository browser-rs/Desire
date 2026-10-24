import SwiftUI

/// 跨窗口 Agent 会话指示器（v0.9.0）：Agent 面板头部显示其他窗口的活跃会话，
/// 点击可切换到该窗口。不做复杂 UI——每个窗口一行（标题 + 运行状态 + 切换按钮）。
struct CrossWindowSessionsIndicator: View {
    /// 本窗口的会话 store（排除自己）。
    let currentStore: AgentSessionStore
    @ObservedObject private var scheduler = AgentScheduler.shared
    @Environment(\.appAccent) private var appAccent
    @State private var showPopover = false

    private var otherSessions: [(label: String, isProcessing: Bool, conversationTitle: String?)] {
        scheduler.liveSessions()
            .compactMap { entry -> (String, AgentSessionStore)? in
                guard let store = entry.store, store !== currentStore else { return nil }
                return (entry.displayLabel, store)
            }
            .map { label, store in
                (label: label,
                 isProcessing: store.isProcessing,
                 conversationTitle: store.conversationTitle)
            }
    }

    var body: some View {
        let active = otherSessions
        if !active.isEmpty {
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 8.5, weight: .medium))
                    Text("\(active.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(active.contains { $0.isProcessing } ? appAccent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Other windows have Agent sessions"))
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Other windows"))
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(Array(active.enumerated()), id: \.offset) { _, session in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.isProcessing ? Color.orange : Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.conversationTitle ?? session.label)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Text(session.label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if session.isProcessing {
                                Text(String(localized: "Running"))
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            Button(String(localized: "Switch")) {
                                // 通过 windowTitle 匹配 NSWindow 切换。
                                if let window = NSApp.windows.first(where: {
                                    $0.title == session.label && $0.isVisible
                                }) {
                                    window.makeKeyAndOrderFront(nil)
                                    NSApp.activate(ignoringOtherApps: true)
                                }
                                showPopover = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(10)
                .frame(width: 260)
            }
        }
    }
}
