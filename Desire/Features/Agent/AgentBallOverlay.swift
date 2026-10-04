import SwiftUI

/// 悬浮球覆盖层（**浏览器窗口内**，主窗 ZStack 顶层）：
/// - 真液态玻璃：`.glassEffect` 在主窗内能采样网页内容（独立透明面板
///   采样不到跨进程背景，会退化成实心灰——前两版实拍）；
/// - SwiftUI 手势在主窗内完全可靠：拖动任意位置、松手吸附最近左右缘
///   （spring）、单击开合操作条、双击直达语音、右键菜单；
/// - 位置持久化（吸附侧 + 纵向比例）。
struct AgentBallOverlay: View {
    /// overlay 的固定坐标空间名（拖动手势用，见 body 注释）。
    static let overlaySpace = "agentBallOverlay"

    @ObservedObject var state: AgentBallPanel
    @Environment(\.appAccent) private var appAccent: Color

    @AppStorage(AgentBallPanel.sizeKey) private var ballSize: Double = 52
    @AppStorage(AgentBallPanel.edgeKey) private var edge: String = "left"
    @AppStorage(AgentBallPanel.offsetKey) private var offsetFraction: Double = 0.5

    /// 球心（窗口内容区坐标）。nil = 尚未按几何初始化。
    @State private var center: CGPoint?
    /// 拖动起点时的球心。用 translation（相对起点的累计位移）而非
    /// 逐帧 location 差：手势坐标空间挂在会移动的球上，location 差会
    /// 自我抵消（实测拖 300pt 只走一半）。
    @State private var dragStartCenter: CGPoint?
    @State private var dragged = false
    @State private var lastTap: Date?
    @State private var dragTilt: Double = 0
    @State private var hoverScale: CGFloat = 1.0
    @State private var pulse: CGFloat = 1.0
    @State private var ringRotation: Double = 0

    private var cardWidth: CGFloat { max(240, ballSize + 188) }
    private var cardHeight: CGFloat { 172 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if state.isExpanded, !state.hiddenForFullscreen {
                    menuCard(in: geo.size)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity),
                            removal: .opacity))
                }
                if !state.hiddenForFullscreen {
                    ball(in: geo.size)
                        .position(resolvedCenter(in: geo.size))
                }
            }
            // 固定坐标空间：手势挂在会移动的球上，默认 .local 会随球
            // 一起动——translation 被自我抵消，拖动只剩半速（实测 492pt
            // 只走 246pt）。命名空间相对 overlay 静止，手势值才准。
            .coordinateSpace(.named(Self.overlaySpace))
            .onAppear {
                if center == nil { center = initialCenter(in: geo.size) }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    pulse = 1.03
                }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    ringRotation = 360
                }
            }
            .onChange(of: geo.size) { _, size in
                clampCenter(in: size)
            }
        }
    }

    // MARK: - 位置

    private func initialCenter(in size: CGSize) -> CGPoint {
        let x = edge == "left" ? ballSize / 2 + 6 : size.width - ballSize / 2 - 6
        let travel = max(0, size.height - ballSize - 20)
        let y = ballSize / 2 + 10 + travel * min(max(offsetFraction, 0), 1)
        return CGPoint(x: x, y: y)
    }

    private func resolvedCenter(in size: CGSize) -> CGPoint {
        center ?? initialCenter(in: size)
    }

    private func clampCenter(in size: CGSize) {
        guard var c = center else { return }
        c.x = min(max(c.x, ballSize / 2 + 4), max(ballSize / 2 + 4, size.width - ballSize / 2 - 4))
        c.y = min(max(c.y, ballSize / 2 + 4), max(ballSize / 2 + 4, size.height - ballSize / 2 - 4))
        center = c
    }

    // MARK: - 球

    private func ball(in size: CGSize) -> some View {
        ZStack {
            // 回复就绪徽章（busy 下降沿闪光）
            if state.replyFlash {
                ZStack {
                    Circle().fill(.green)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: ballSize * 0.36, height: ballSize * 0.36)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .offset(x: ballSize * 0.34, y: -ballSize * 0.30)
                .transition(.scale.combined(with: .opacity))
            }
            // 忙碌：进度环
            if state.agentBusy {
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(appAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: ballSize + 12, height: ballSize + 12)
                    .rotationEffect(.degrees(ringRotation))
            }
            // 液态玻璃球体
            Image(systemName: state.voice.isRecording ? "mic.fill" : "sparkles")
                .font(.system(size: ballSize * 0.36, weight: .medium))
                .foregroundStyle(state.voice.isRecording
                    ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: ballSize, height: ballSize)
                .glassEffect(
                    state.voice.isRecording
                        ? .regular.tint(Color.red.opacity(0.55)).interactive()
                        : .regular.interactive(),
                    in: .circle
                )
        }
        .scaleEffect(hoverScale * pulse)
        .rotationEffect(.degrees(dragTilt))
        .contentShape(Circle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hoverScale = hovering ? 1.06 : 1.0 }
        }
        .contextMenu {
            Button("重置位置") { resetPosition(in: size) }
            Divider()
            Button("隐藏悬浮球") { state.setEnabled(false) }
        }
        .gesture(dragGesture(in: size))
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: state.replyFlash)
    }

    // MARK: - 拖动 / 点击

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.overlaySpace))
            .onChanged { value in
                guard !state.isExpanded else { return }
                if dragStartCenter == nil { dragStartCenter = resolvedCenter(in: size) }
                let t = value.translation
                if abs(t.width) > 4 || abs(t.height) > 4 { dragged = true }
                if dragged, let start = dragStartCenter {
                    var c = CGPoint(x: start.x + t.width, y: start.y + t.height)
                    c.x = min(max(c.x, ballSize / 2 + 4), max(ballSize / 2 + 4, size.width - ballSize / 2 - 4))
                    c.y = min(max(c.y, ballSize / 2 + 4), max(ballSize / 2 + 4, size.height - ballSize / 2 - 4))
                    center = c
                    dragTilt = max(-14, min(14, value.velocity.width / 28))
                }
            }
            .onEnded { _ in
                defer {
                    dragStartCenter = nil
                    dragged = false
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { dragTilt = 0 }
                if dragged {
                    snapToEdge(in: size)
                    lastTap = nil
                    return
                }
                if !state.voice.isRecording {
                    // 双击 = 直达语音；单击 = 展开/收起操作条
                    let now = Date()
                    if let last = lastTap, now.timeIntervalSince(last) < 0.35 {
                        state.isExpanded = false
                        state.voice.toggle()
                        lastTap = nil
                    } else {
                        lastTap = now
                        state.isExpanded.toggle()
                    }
                }
            }
    }

    private func snapToEdge(in size: CGSize) {
        var c = resolvedCenter(in: size)
        let toLeft = c.x < size.width / 2
        c.x = toLeft ? ballSize / 2 + 6 : size.width - ballSize / 2 - 6
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { center = c }
        UserDefaults.standard.set(toLeft ? "left" : "right", forKey: AgentBallPanel.edgeKey)
        let travel = max(1, size.height - ballSize - 20)
        offsetFraction = min(max((c.y - ballSize / 2 - 10) / travel, 0), 1)
    }

    private func resetPosition(in size: CGSize) {
        edge = "left"
        offsetFraction = 0.5
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            center = initialCenter(in: size)
        }
    }

    // MARK: - 操作条（液态玻璃卡，球上方或下方）

    private func menuCard(in size: CGSize) -> some View {
        let c = resolvedCenter(in: size)
        let below = c.y - ballSize / 2 - 10 - cardHeight < 8
        let cardCenterY = below
            ? c.y + ballSize / 2 + 10 + cardHeight / 2
            : c.y - ballSize / 2 - 10 - cardHeight / 2
        let halfWidth = cardWidth / 2
        let cardCenterX = min(max(c.x, halfWidth + 6), max(halfWidth + 6, size.width - halfWidth - 6))
        return menuCardContent
            .frame(width: cardWidth)
            .position(x: cardCenterX, y: cardCenterY)
    }

    private var menuCardContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            if state.voice.isRecording {
                transcriptChip
                    .padding(.bottom, 4)
            }
            actionRow(icon: "bubble.left.and.text.bubble.right", title: "Agent 对话") {
                state.openAgentPanel()
            }
            actionRow(icon: state.voice.isRecording ? "stop.circle.fill" : "mic.fill",
                      title: state.voice.isRecording ? "停止并发送" : "语音输入",
                      tint: state.voice.isRecording ? .red : nil) {
                state.voice.toggle()
            }
            actionRow(icon: "doc.text.magnifyingglass", title: "总结本页") {
                state.askAboutPage()
            }
            actionRow(icon: "rectangle.dashed", title: "白板") {
                state.openWhiteboard()
            }
            if let sent = state.voiceTranscriptSent {
                Text("已发送：\(sent.prefix(24))")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var transcriptChip: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text(state.voice.transcribedText.isEmpty ? "聆听中…" : state.voice.transcribedText)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06)))
    }

    private func actionRow(icon: String, title: String, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint ?? appAccent)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
