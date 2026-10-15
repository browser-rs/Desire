import AppKit
import os
import SwiftUI

extension Notification.Name {
    /// 菜单栏快速入口请求亮出 Agent 面板。走 NotificationCenter 而不是
    /// CommandBus：那条件是 `hostingWindow === NSApp.keyWindow`，而按键时
    /// 焦点还在弹窗链路上（且这里要按"持有投递会话的窗口"收敛到唯一目标，
    /// 多窗口下 CommandBus 会广播给所有窗口）。ContentView 的监听按该身份
    /// 过滤后亮面板并把窗口拉前台。
    static let desireShowAgentPanel = Notification.Name("desire.showAgentPanel")
}

/// 菜单栏快速入口（v19）：不打开浏览器窗口，在任何应用里问一句自己的
/// Agent。宿主是 NSStatusItem + NSPopover（见 MenuBarQuickEntryController
/// 头注释——SwiftUI MenuBarExtra 的 isInserted 动态绑定会触发启动无限循环）。
/// 发送走 `AgentScheduler.deliveryTarget`（最新注册的会话，与定时任务/桥
/// 同一个投递口径），答案照常落在该会话里——「打开 Agent 面板」先收起弹窗
/// 再把目标窗口拉前台并亮出面板。默认开启，可在 设置 › 通用 关闭。
struct MenuBarQuickEntryView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @State private var sentHint = false
    @FocusState private var fieldFocused: Bool

    /// 显式 internal init（Xcode 26 教训：全 private 存储属性会把 memberwise
    /// init 降成 private，跨文件构造在 CI 的旧编译器上被拒——本地新 Xcode 不报）。
    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appAccent)
                Text("Ask Desire")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if sentHint {
                    Text("Sent ✓")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(appAccent)
                }
            }

            TextField(String(localized: "Ask anything…"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...4)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
                )
                .focused($fieldFocused)
                // 回车/小键盘回车发送（Shift+回车换行，与 Agent 面板同语义）；
                // .onKeyPress 在更新事务里执行 → 提交必须跳一帧（既定教训）。
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    Task { @MainActor in submit() }
                    return .handled
                }

            HStack(spacing: 8) {
                Button {
                    submit()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)

                Button {
                    openAgentPanel()
                } label: {
                    Label("Open Agent Panel", systemImage: "rectangle.rightthird.inset.filled")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Bring Desire to the front"))
            }

            if AgentScheduler.shared.deliveryTarget == nil {
                Text("No live agent session — open a Desire window first.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            // @FocusState 在 onAppear 里直接置真常不生效（既定教训），跳一帧再试。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                fieldFocused = true
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && AgentScheduler.shared.deliveryTarget != nil
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let store = AgentScheduler.shared.deliveryTarget else { return }
        draft = ""
        store.sendMessage(text)
        Log.agent.info("menu bar quick entry: sent \(text.count, privacy: .public) chars to delivery target")
        withAnimation(.transitionNormal) { sentHint = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.transitionNormal) { sentHint = false }
        }
    }

    /// 把目标窗口拉前台并亮出 Agent 面板。先收起弹窗（key window 归还给
    /// 浏览器窗口）。没有活动会话（全部窗口已关）时先开一扇主窗，稍后重投
    /// 一次通知（新窗的会话在 init 时就注册为投递目标，重投即可命中）。
    private func openAgentPanel() {
        MenuBarQuickEntryController.shared.closePopover()
        NSApp.activate(ignoringOtherApps: true)
        if AgentScheduler.shared.deliveryTarget == nil {
            Log.agent.info("menu bar quick entry: no delivery target — opening a main window, retrying")
            openWindow(id: "main", value: UUID())
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                NotificationCenter.default.post(name: .desireShowAgentPanel, object: nil)
            }
            return
        }
        Log.agent.info("menu bar quick entry: requesting agent panel")
        NotificationCenter.default.post(name: .desireShowAgentPanel, object: nil)
    }
}
