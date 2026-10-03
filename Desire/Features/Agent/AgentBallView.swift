import SwiftUI

/// 悬浮球视图。视觉：墨黑玻璃球（呼应品牌"墨与朱"）——深色渐变底、
/// 顶部高光、细白环，点缀朱砂；录音态整球转朱砂红脉冲；忙碌态朱砂
/// 进度环。展开操作条为黑玻璃白字卡片，spring 弹出。
struct AgentBallView: View {
    @ObservedObject var panel: AgentBallPanel
    @ObservedObject var voice: VoiceInputManager
    @Environment(\.appAccent) private var appAccent: Color

    @State private var dragStart: CGPoint?
    @State private var dragged = false
    @State private var dragTilt: Double = 0
    @State private var lastTapTime: Date?
    @AppStorage(AgentBallPanel.sizeKey) private var ballSize: Double = 52
    @State private var hoverScale: CGFloat = 1.0
    @State private var pulse: CGFloat = 1.0
    @State private var ringRotation: Double = 0

    // 墨与朱
    private var inkTop: Color { Color(red: 0.18, green: 0.18, blue: 0.19) }
    private var inkBottom: Color { Color(red: 0.07, green: 0.07, blue: 0.08) }
    private var vermilion: Color { Color(red: 0.88, green: 0.25, blue: 0.12) }

    var body: some View {
        ZStack(alignment: .bottom) {
            if panel.isExpanded {
                menuCard
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                        removal: .opacity))
            }
            ball
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .bottom)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = 1.04
            }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
        }
    }

    private var panelWidth: CGFloat { max(240, ballSize + 188) }
    private var panelHeight: CGFloat { ballSize + 176 }

    // MARK: - 球

    private var ball: some View {
        ZStack {
            // 忙碌：朱砂进度环
            if panel.agentBusy {
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(vermilion, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: ballSize + 12, height: ballSize + 12)
                    .rotationEffect(.degrees(ringRotation))
            }
            // 录音：整球转朱砂
            Circle()
                .fill(
                    LinearGradient(
                        colors: voice.isRecording
                            ? [vermilion, vermilion.opacity(0.72)]
                            : [inkTop, inkBottom],
                        startPoint: .top, endPoint: .bottom))
            // 顶部高光（玻璃感——上半弧内渐隐白）
            Circle()
                .fill(
                    LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0)],
                                   startPoint: .top, endPoint: .center))
                .padding(1.5)
            // 细白环
            Circle()
                .strokeBorder(.white.opacity(voice.isRecording ? 0.32 : 0.16), lineWidth: 0.75)
            Image(systemName: voice.isRecording ? "mic.fill" : "sparkles")
                .font(.system(size: ballSize * 0.34, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: ballSize, height: ballSize)
        .shadow(color: .black.opacity(voice.isRecording ? 0.4 : 0.3),
                radius: voice.isRecording ? 10 : 7, y: 3)
        .scaleEffect(hoverScale * pulse)
        .rotationEffect(.degrees(dragTilt))
        .contentShape(Circle())
        .contextMenu {
            Button("重置位置") { panel.resetPosition() }
            Divider()
            Button("隐藏悬浮球") { panel.setEnabled(false) }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hoverScale = hovering ? 1.07 : 1.0 }
        }
        .gesture(dragGesture)
    }

    // MARK: - 操作条（黑玻璃白字）

    private var menuCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            if voice.isRecording {
                transcriptChip
                    .padding(.bottom, 4)
            }
            actionRow(icon: "bubble.left.and.text.bubble.right", title: "Agent 对话") {
                panel.openAgentPanel()
            }
            actionRow(icon: voice.isRecording ? "stop.circle.fill" : "mic.fill",
                      title: voice.isRecording ? "停止并发送" : "语音输入",
                      tint: voice.isRecording ? vermilion : nil) {
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
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(width: panelWidth - 4)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        )
    }

    private var transcriptChip: some View {
        HStack(spacing: 6) {
            Circle().fill(vermilion).frame(width: 6, height: 6)
            Text(voice.transcribedText.isEmpty ? "聆听中…" : voice.transcribedText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
    }

    private func actionRow(icon: String, title: String, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint ?? vermilion)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 拖动（阈值内 = 点击展开/收起；双击 = 直达语音）

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
                    lastTapTime = nil
                    return
                }
                if !voice.isRecording {
                    // 双击 = 直达语音（跳过菜单）；单击 = 展开操作条
                    let now = Date()
                    if let last = lastTapTime, now.timeIntervalSince(last) < 0.35 {
                        panel.isExpanded = false
                        panel.voice.toggle()
                        lastTapTime = nil
                    } else {
                        lastTapTime = now
                        panel.isExpanded.toggle()
                    }
                }
            }
    }
}
