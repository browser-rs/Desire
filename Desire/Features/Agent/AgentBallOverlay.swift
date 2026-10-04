import SwiftUI

/// 悬浮球覆盖层（**浏览器窗口内**，主窗 ZStack 顶层）—— **V3 辅佐触盘**形态
/// （design/agent-ball/prototype-v1.html，2026-10-04 用户定稿）：
/// - 真液态玻璃：`.glassEffect` 在主窗内能采样网页内容（独立透明面板
///   采样不到跨进程背景，会退化成实心灰——前两版实拍）；
/// - 交互 = iOS AssistiveTouch：点球弹出径向触盘（2×2 大圆按钮依次弹入，
///   热区大、盲点得中），球图标切换 ✕；点触盘外任意处 / 再点球收起；
///   拖动任意位置、松手 spring 吸附最近左右缘（命名坐标空间，见 body 注释）；
/// - 动效口径（并行润色定下的"克制"原则，勿回退）：**不做常驻动画**
///   （无呼吸/无旋转环——忙碌 = 静态强调环），悬停 = 轻微放大 + brightness；
///   唯一例外是触盘按钮的弹入 stagger（V3 定稿时用户明确批准）与录音扩散波纹
///   （录音是瞬态活跃态）；
/// - 状态全在球上：忙碌静态环 / 录音红玻璃 + 波纹 / 回复就绪绿徽章；
///   录音时触盘内附实时转写条；语音发出后球旁弹"已发送"玻璃胶囊（3.6s 自散）；
/// - 位置持久化（吸附侧 + 纵向比例）。
struct AgentBallOverlay: View {
    /// overlay 的固定坐标空间名（拖动手势用，见 body 注释）。
    static let overlaySpace = "agentBallOverlay"

    @ObservedObject var state: AgentBallPanel
    @Environment(\.appAccent) private var appAccent: Color

    @AppStorage(AgentBallPanel.sizeKey) private var ballSize: Double = 52
    @AppStorage(AgentBallPanel.edgeKey) private var edge: String = "left"
    @AppStorage(AgentBallPanel.offsetKey) private var offsetFraction: Double = 0.5

    /// 球心**不存储绝对坐标**：静止位置永远由持久化 (edge, offsetFraction)
    /// + 当前窗口尺寸推导。存绝对坐标会在窗口冷启动布局链（实测 geo 走
    /// 0×0 → 900×600 → 真实尺寸）里被播种进过渡尺寸的坐标系，真实窗口下
    /// 偏到页面中间——位置类竞态整类消除。拖动期间才用 dragPos 临时坐标。
    @State private var dragPos: CGPoint?
    /// 拖动起点时的球心。用 translation（相对起点的累计位移）而非
    /// 逐帧 location 差：手势坐标空间挂在会移动的球上，location 差会
    /// 自我抵消（实测拖 300pt 只走一半）。
    @State private var dragStartCenter: CGPoint?
    @State private var dragged = false
    @State private var lastTap: Date?
    @State private var dragTilt: Double = 0
    @State private var hoverScale: CGFloat = 1.0
    /// 语音已发送提示（球旁玻璃胶囊，短暂显示）。
    @State private var sentToast: String?
    @State private var toastTask: Task<Void, Never>?
    /// 触盘弹入驱动（HubContent 拿它做按钮 stagger）。
    @State private var hubAppeared = false

    // 触盘几何（照原型 V3 定稿：2×2 大圆按钮）
    private let hubCell: CGFloat = 84
    private let hubGap: CGFloat = 10
    private let hubPad: CGFloat = 14
    private var hubWidth: CGFloat { hubPad * 2 + hubCell * 2 + hubGap }
    private var hubHeight: CGFloat {
        hubPad * 2 + hubCell * 2 + hubGap + (state.voice.isRecording ? 44 : 0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if state.isExpanded, !state.hiddenForFullscreen {
                    // 点外收起层：挡在网页与触盘之间（触盘自己吞掉背景点击）。
                    // 打开期间页面点击不可用——命令模式语义，与 AssistiveTouch 一致。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { state.isExpanded = false }
                    hub(in: geo.size)
                        .transition(.opacity)
                }
                if !state.hiddenForFullscreen {
                    ball(in: geo.size)
                        .position(ballPosition(in: geo.size))
                }
                if let toast = sentToast, !state.hiddenForFullscreen {
                    toastPill(toast, in: geo.size)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            // 固定坐标空间：手势挂在会移动的球上，默认 .local 会随球
            // 一起动——translation 被自我抵消，拖动只剩半速（实测 492pt
            // 只走 246pt）。命名空间相对 overlay 静止，手势值才准。
            .coordinateSpace(.named(Self.overlaySpace))
            // 触盘弹出/收起与球图标 ✕ 切换由这一个动画驱动。
            .animation(.spring(response: 0.4, dampingFraction: 0.78), value: state.isExpanded)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: sentToast)
            .onChange(of: state.voiceTranscriptSent) { _, sent in
                guard let sent, !sent.isEmpty else { return }
                toastTask?.cancel()
                sentToast = sent
                toastTask = Task {
                    try? await Task.sleep(for: .seconds(3.6))
                    guard !Task.isCancelled else { return }
                    sentToast = nil
                }
            }
        }
    }

    // MARK: - 位置

    /// 静止球心：由持久化 (edge, offsetFraction) + 当前窗口尺寸推导。
    private func restingCenter(in size: CGSize) -> CGPoint {
        let x = edge == "left" ? ballSize / 2 + 6 : size.width - ballSize / 2 - 6
        let travel = max(0, size.height - ballSize - 20)
        let y = ballSize / 2 + 10 + travel * min(max(offsetFraction, 0), 1)
        return CGPoint(x: x, y: y)
    }

    /// 球的实时位置：拖动中用 dragPos，其余时刻用推导位置。
    private func ballPosition(in size: CGSize) -> CGPoint {
        dragPos ?? restingCenter(in: size)
    }

    // MARK: - 球（AssistiveTouch 主球）

    private func ball(in size: CGSize) -> some View {
        ZStack {
            // 录音：单圈扩散波纹（瞬态活跃态；静态之外的唯一常动）
            if state.voice.isRecording {
                BallPulseRing(size: ballSize)
            }
            // 忙碌：静态强调环（不做常驻旋转——克制；状态由环的有无表达）
            if state.agentBusy {
                Circle()
                    .stroke(appAccent.opacity(0.9), lineWidth: 2)
                    .frame(width: ballSize + 10, height: ballSize + 10)
            }
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
            // 液态玻璃球体：图标 = 目标环 ↔ ✕（录音时 = 麦克风，红玻璃）
            ZStack {
                targetIcon
                    .opacity(iconState == .target ? 1 : 0)
                    .scaleEffect(iconState == .target ? 1 : 0.55)
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .opacity(iconState == .close ? 1 : 0)
                    .scaleEffect(iconState == .close ? 1 : 0.55)
                Image(systemName: "mic.fill")
                    .font(.system(size: ballSize * 0.34, weight: .medium))
                    .foregroundStyle(.white)
                    .opacity(iconState == .mic ? 1 : 0)
                    .scaleEffect(iconState == .mic ? 1 : 0.55)
            }
            .frame(width: ballSize, height: ballSize)
            .glassEffect(
                state.voice.isRecording
                    ? .regular.tint(Color.red.opacity(0.55)).interactive()
                    : .regular.interactive(),
                in: .circle
            )
        }
        .scaleEffect(hoverScale)
        .rotationEffect(.degrees(dragTilt))
        .brightness(hoverScale > 1 ? 0.03 : 0)
        .contentShape(Circle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hoverScale = hovering ? 1.05 : 1.0 }
        }
        .contextMenu {
            Button("重置位置") { resetPosition(in: size) }
            Divider()
            Button("隐藏悬浮球") { state.setEnabled(false) }
        }
        .gesture(dragGesture(in: size))
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: state.replyFlash)
    }

    private enum BallIcon { case target, close, mic }

    private var iconState: BallIcon {
        if state.voice.isRecording { return .mic }
        return state.isExpanded ? .close : .target
    }

    /// 触盘待机图标：外环 + 心点（AssistiveTouch 语汇）。
    private var targetIcon: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.8)
            Circle()
                .fill(Color.primary.opacity(0.75))
                .frame(width: 7, height: 7)
        }
        .frame(width: ballSize * 0.42, height: ballSize * 0.42)
    }

    // MARK: - 拖动 / 点击

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.overlaySpace))
            .onChanged { value in
                guard !state.isExpanded else { return }
                if dragStartCenter == nil { dragStartCenter = restingCenter(in: size) }
                let t = value.translation
                if abs(t.width) > 4 || abs(t.height) > 4 { dragged = true }
                if dragged, let start = dragStartCenter {
                    var c = CGPoint(x: start.x + t.width, y: start.y + t.height)
                    c.x = min(max(c.x, ballSize / 2 + 4), max(ballSize / 2 + 4, size.width - ballSize / 2 - 4))
                    c.y = min(max(c.y, ballSize / 2 + 4), max(ballSize / 2 + 4, size.height - ballSize / 2 - 4))
                    dragPos = c
                    dragTilt = max(-10, min(10, value.velocity.width / 36))
                }
            }
            .onEnded { _ in
                defer {
                    dragStartCenter = nil
                    dragPos = nil
                    dragged = false
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { dragTilt = 0 }
                if dragged {
                    snapToEdge(in: size)
                    lastTap = nil
                    return
                }
                if state.voice.isRecording {
                    // 录音中点击球 = 开合触盘（停止入口在触盘的"停止并发送"）
                    lastTap = nil
                    state.isExpanded.toggle()
                } else if let last = lastTap, Date().timeIntervalSince(last) < 0.35 {
                    // 双击 = 直达语音（转写条随录音在触盘里展开）
                    state.isExpanded = false
                    state.voice.toggle()
                    lastTap = nil
                } else {
                    lastTap = Date()
                    state.isExpanded.toggle()
                }
            }
    }

    /// 松手吸附：把拖动终点换算成 (edge, offsetFraction) 持久化——
    /// 静止位置由推导给出，弹簧动画跟随 AppStorage 值变化。
    private func snapToEdge(in size: CGSize) {
        let c = dragPos ?? restingCenter(in: size)
        let toLeft = c.x < size.width / 2
        let travel = max(1, size.height - ballSize - 20)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            edge = toLeft ? "left" : "right"
            offsetFraction = min(max((c.y - ballSize / 2 - 10) / travel, 0), 1)
        }
    }

    private func resetPosition(in size: CGSize) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            edge = "left"
            offsetFraction = 0.5
        }
    }

    // MARK: - 触盘（2×2 径向圆按钮，球上方或下方）

    private func hub(in size: CGSize) -> some View {
        let c = restingCenter(in: size)
        let above = c.y - ballSize / 2 - 10 - hubHeight < 8
        let hubY = above
            ? c.y + ballSize / 2 + 10 + hubHeight / 2
            : c.y - ballSize / 2 - 10 - hubHeight / 2
        let halfW = hubWidth / 2
        let hubX = min(max(c.x, halfW + 6), max(halfW + 6, size.width - halfW - 6))
        return AgentBallHub(state: state, cellSize: hubCell, appear: hubAppeared)
            .frame(width: hubWidth)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .onTapGesture {}  // 吞掉触盘背景点击：不落到"点外收起"层
            .position(x: hubX, y: hubY)
            .onAppear { hubAppeared = true }
            .onDisappear { hubAppeared = false }
    }

    // MARK: - 已发送胶囊

    private func toastPill(_ text: String, in size: CGSize) -> some View {
        let c = restingCenter(in: size)
        let nearBottom = c.y + ballSize / 2 + 60 > size.height - 8
        let y = nearBottom
            ? c.y - ballSize / 2 - 34
            : c.y + ballSize / 2 + 30
        let x = min(max(c.x, 130), max(130, size.width - 130))
        return HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
            Text("已发送：\(String(text.prefix(18)))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .position(x: x, y: y)
    }
}

// MARK: - 触盘内容（2×2 大圆按钮 + 录音转写条）

/// 按钮依次弹入的径向触盘。弹入动画用 appear 状态驱动
/// （onAppear 置真，容器 transition 只管淡入——避免双重缩放）。
/// 悬停口径与操作行一致：填强调色、图标反白。
private struct AgentBallHub: View {
    @ObservedObject var state: AgentBallPanel
    @Environment(\.appAccent) private var appAccent: Color
    let cellSize: CGFloat
    let appear: Bool

    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    cell(0, icon: "bubble.left.and.text.bubble.right", title: "Agent 对话") {
                        state.isExpanded = false
                        state.openAgentPanel()
                    }
                    cell(1,
                         icon: state.voice.isRecording ? "stop.circle.fill" : "mic.fill",
                         title: state.voice.isRecording ? "停止并发送" : "语音输入",
                         recording: state.voice.isRecording) {
                        state.voice.toggle()
                    }
                }
                HStack(spacing: 10) {
                    cell(2, icon: "doc.text.magnifyingglass", title: "总结本页") {
                        state.isExpanded = false
                        state.askAboutPage()
                    }
                    cell(3, icon: "rectangle.dashed", title: "白板") {
                        state.isExpanded = false
                        state.openWhiteboard()
                    }
                }
            }
            if state.voice.isRecording {
                transcriptChip
                    .transition(.opacity)
            }
        }
        .padding(14)
    }

    private func cell(_ index: Int, icon: String, title: String,
                      recording: Bool = false,
                      action: @escaping () -> Void) -> some View {
        let hoveredCell = hovered == index && !recording
        return Button {
            action()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(recording
                              ? AnyShapeStyle(Color.red.opacity(0.16))
                              : hoveredCell
                              ? AnyShapeStyle(appAccent)
                              : AnyShapeStyle(Color.primary.opacity(0.06)))
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(recording
                                         ? AnyShapeStyle(Color.red)
                                         : hoveredCell
                                         ? AnyShapeStyle(.white)
                                         : AnyShapeStyle(Color.primary.opacity(0.72)))
                }
                .frame(width: 46, height: 46)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(recording
                                     ? AnyShapeStyle(Color.red)
                                     : hoveredCell
                                     ? AnyShapeStyle(appAccent)
                                     : AnyShapeStyle(Color.primary.opacity(0.6)))
                    .lineLimit(1)
            }
            .frame(width: cellSize, height: cellSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hovered = hovering ? index : (hovered == index ? nil : hovered)
            }
        }
        .scaleEffect(appear ? 1 : 0.55)
        .opacity(appear ? 1 : 0)
        .animation(.spring(response: 0.34, dampingFraction: 0.72).delay(Double(index) * 0.055),
                   value: appear)
    }

    private var transcriptChip: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text(state.voice.transcribedText.isEmpty ? "聆听中…" : state.voice.transcribedText)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - 录音扩散波纹

/// 单圈从球缘向外扩散消隐的红环（录音是瞬态活跃态——红玻璃本身已
/// 改变整个球，一圈波纹足够，不做多圈连发）。
private struct BallPulseRing: View {
    var size: CGFloat
    @State private var on = false

    var body: some View {
        Circle()
            .stroke(Color.red.opacity(0.45), lineWidth: 2)
            .frame(width: size, height: size)
            .scaleEffect(on ? 1.45 : 1.0)
            .opacity(on ? 0 : 0.8)
            .animation(.easeOut(duration: 1.9).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}
