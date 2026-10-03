import SwiftUI

/// 悬浮球视图：收起 = 52pt 渐变圆球（呼吸 + 录音红脉冲）；点击展开操作条；
/// 拖动经回调驱动面板移动（拖动阈值 5pt，以内算点击）。面板命中规则见
/// `AgentBallHostingView`（透明区域穿透，球/菜单可点）。
struct AgentBallView: View {
    @ObservedObject var panel: AgentBallPanel
    @ObservedObject var voice: VoiceInputManager
    @State private var dragTilt: Double = 0
    @Environment(\.appAccent) private var appAccent: Color

    @State private var dragStart: CGPoint?
    @State private var dragged = false

    private let ballSize: CGFloat = 52
    /// 球在面板内的 x（吸附侧）：面板宽 240，左缘球贴左、右缘球贴右。
    private var ballAlignedRight: Bool {
        UserDefaults.standard.string(forKey: AgentBallPanel.edgeKey) != "left"
    }

    var body: some View {
        ZStack(alignment: ballAlignedRight ? .topTrailing : .topLeading) {
            if panel.isExpanded {
                menuCard
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
            ball
        }
        .frame(width: 240, height: 420, alignment: ballAlignedRight ? .topTrailing : .topLeading)
        .allowsHitTesting(true)
    }

    // MARK: - 球

    private var ball: some View {
        ZStack {
            if voice.isRecording {
                Circle()
                    .stroke(Color.red.opacity(0.5), lineWidth: 2)
                    .frame(width: ballSize + 14, height: ballSize + 14)
                    .scaleEffect(voice.isRecording ? 1.0 : 0.8)
                    .opacity(voice.isRecording ? 0.9 : 0.2)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: voice.isRecording)
            }
            Circle()
                .fill(
                    LinearGradient(
                        colors: voice.isRecording
                            ? [Color.red, Color.red.opacity(0.65)]
                            : [appAccent, appAccent.opacity(0.62)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: (voice.isRecording ? Color.red : appAccent).opacity(0.45),
                        radius: voice.isRecording ? 10 : 6, y: 2)
            Image(systemName: voice.isRecording ? "mic.fill" : "sparkles")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: ballSize, height: ballSize)
        .scaleEffect(hoverScale * pulse)
        .rotationEffect(.degrees(dragTilt))
        .contentShape(Circle())
        .contextMenu {
            Button("重置位置") { panel.resetPosition() }
            Divider()
            Button("隐藏悬浮球") { panel.setEnabled(false) }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = 1.05
            }
        }
        .gesture(dragGesture)
        .onHover { hovering in
            // hover 实感：微放大
            withAnimation(.easeInOut(duration: 0.15)) {
                hoverScale = hovering ? 1.08 : 1.0
            }
        }
    }

    @State private var hoverScale: CGFloat = 1.0
    @State private var pulse: CGFloat = 1.0

    // MARK: - 展开菜单

    private var menuCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if voice.isRecording {
                transcriptChip
            }
            actionRow(icon: "bubble.left.and.text.bubble.right", title: "Agent 对话") {
                panel.openAgentPanel()
            }
            actionRow(icon: voice.isRecording ? "stop.circle" : "mic.fill",
                      title: voice.isRecording ? "停止并发送" : "语音输入",
                      tint: voice.isRecording ? .red : nil) {
                panel.voice.toggle()
            }
            actionRow(icon: "doc.text.magnifyingglass", title: "总结本页") {
                panel.askAboutPage()
            }
            actionRow(icon: "rectangle.dashed", title: "白板") {
                panel.openWhiteboard()
            }
            if let sent = panel.voiceTranscriptSent {
                Text("已发送：\(sent.prefix(24))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 212)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
    }

    private var transcriptChip: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text(voice.transcribedText.isEmpty ? "聆听中…" : voice.transcribedText)
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 192, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
    }

    private func actionRow(icon: String, title: String, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint ?? appAccent)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.clear))
    }

    // MARK: - 拖动（阈值内 = 点击展开/收起）

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !panel.isExpanded else { return }
                if let start = dragStart {
                    let dx = value.location.x - start.x
                    let dy = value.location.y - start.y
                    if abs(dx) > 4 || abs(dy) > 4 { dragged = true }
                    if dragged {
                        panel.moveBy(dx: dx, dy: -dy)
                        // 拖动倾斜：随水平速度倾斜，松手回正
                        let tilt = max(-14, min(14, value.velocity.width / 28))
                        withAnimation(.easeOut(duration: 0.08)) { dragTilt = tilt }
                    }
                }
                dragStart = value.location
            }
            .onEnded { _ in
                defer {
                    dragStart = nil
                    dragged = false
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { dragTilt = 0 }
                if dragged {
                    panel.snapToEdge()
                } else if !voice.isRecording {
                    panel.isExpanded.toggle()
                }
            }
    }
}

/// 透明面板命中穿透：只有球/菜单等**子视图**接收事件，透明背景让点击
/// 落到下层网页（悬浮球不遮窗口交互的关键）。
final class AgentBallHostingView: NSHostingView<AgentBallView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
