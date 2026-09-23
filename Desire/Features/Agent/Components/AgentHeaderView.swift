import AppKit
import SwiftUI

/// Header strip for the AI panel. Shows a brand mark, an animated status
/// dot when streaming, and trailing
/// actions (history / clear).
struct AgentHeaderView: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject var store: AgentSessionStore
    let hasHistory: Bool
    var onShowHistory: () -> Void
    var onShowCapabilities: (() -> Void)?
    var onShowMemory: (() -> Void)?
    var onNewChat: (() -> Void)?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            brandMark

            VStack(alignment: .leading, spacing: 0) {
                Text("Agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                statusLine
            }

            Spacer(minLength: 4)

            if store.fullAccess {
                fullAccessBadge
            }

            if store.isProcessing {
                if store.isPaused {
                    Button {
                        store.resume()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Resume (paused between steps)")
                } else {
                    Button {
                        store.pause()
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Pause (stops before the next step)")
                }
                stopButton
            }

            if let onShowCapabilities {
                HoverIcon(
                    systemName: "sparkles.rectangle.stack",
                    action: onShowCapabilities,
                    help: "Agent capabilities & tools"
                )
            }

            if let onShowMemory {
                HoverIcon(
                    systemName: "brain.head.profile",
                    action: onShowMemory,
                    help: "Memory"
                )
            }

            HoverIcon(
                systemName: "clock.arrow.circlepath",
                action: onShowHistory,
                help: "Conversation history"
            )
            .opacity(hasHistory ? 1 : 0.35)
            .disabled(!hasHistory)

            if let onNewChat {
                HoverIcon(
                    systemName: "plus.bubble",
                    action: onNewChat,
                    help: "New chat"
                )
            }

            HoverIcon(
                systemName: "trash",
                action: { store.clear() },
                help: "Clear conversation"
            )
            .opacity(canClear ? 1 : 0.35)
            .disabled(!canClear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(headerBackground)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.6)
        }
    }

    // MARK: - Sub-views

    private var brandMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            appAccent,
                            appAccent.opacity(0.7),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
        .shadow(color: appAccent.opacity(0.25), radius: 3, y: 1)
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            // 状态点：**只有真的在忙时才脉动**。此前 `onAppear` 无条件置 `isDotPulsing = true`，
            // 于是 Ready 状态下绿灯也在闪；而 `.animation(repeatForever, value:)` 在面板
            // 频繁重绘（打开面板时的布局/滚动/task）会不断重启动画，看起来就是"闪动"。
            // 脉动改成按**时间**算（TimelineView）：纯时间函数，重绘不会打断它，不忙时连
            // 这个分支都不存在。
            if store.isProcessing {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.6) / 1.6
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.62 + 0.38 * (0.5 + 0.5 * cos(phase * 2 * .pi)))
                }
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // 回合进行中显示已用时：长工具跑起来时，"在动"和"卡住"的区别就在这。
            // TimelineView 只包裹这一小块文字，不会带动整块面板重绘。
            if store.isProcessing, let started = store.processingStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    Text(verbatim: "· \(seconds)s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            // 上下文占用：口径与 `compactForContext` 相同，所以它变红时就是
            // "快要压缩 / 快要开始丢上下文"的时候（累计 token 数对用户没有行动意义）。
            if store.contextFraction >= 0.02 {
                HStack(spacing: 3) {
                    Image(systemName: contextSymbol)
                        .font(.system(size: 9))
                    Text(verbatim: "\(Int((store.contextFraction * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(contextColor)
                .help(contextHelp)
            }
        }
    }

    /// 上下文占用的颜色分级：60% 起提醒、85% 起警告（此时 /new 更划算）。
    private var contextColor: Color {
        if store.contextFraction >= 0.85 { return .red }
        if store.contextFraction >= 0.6 { return .orange }
        return .secondary
    }

    private var contextSymbol: String {
        store.contextFraction >= 0.6 ? "exclamationmark.triangle.fill" : "gauge.medium"
    }

    /// 提示里带上"最近一次请求的 prompt token"，但主信号是百分比。
    private var contextHelp: String {
        var text = String(localized: "Context") + String(format: " %d%%", Int((store.contextFraction * 100).rounded()))
        if store.lastPromptTokens > 0 {
            text += String(format: " · ≈%.1fk tokens", Double(store.lastPromptTokens) / 1000)
        }
        if store.contextFraction >= 0.6 {
            text += " · " + String(localized: "Context is getting long — /new starts a fresh conversation")
        }
        return text
    }

    private var fullAccessBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 8, weight: .bold))
            Text("FULL ACCESS")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .overlay(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 0.8))
        .help("All tools run without approval — including code execution. Toggle in the input bar.")
    }

    private var stopButton: some View {
        Button {
            store.cancel()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8))
                Text("Stop")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help("Stop generation")
        .transition(.scale.combined(with: .opacity))
    }

    private var headerBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    appAccent.opacity(0.04),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Computed

    private var canClear: Bool {
        !store.messages.isEmpty
    }

    private var statusColor: Color {
        if store.isProcessing { return Color.orange }
        if !store.messages.isEmpty { return Color.green }
        return Color.secondary.opacity(0.5)
    }

    private var statusText: String {
        if store.isProcessing {
            if let action = store.currentAction {
                return "Running \(action)…"
            }
            return "Thinking…"
        }
        if !store.messages.isEmpty { return "Ready" }
        return "Idle"
    }
}
