import SwiftUI

/// 悬浮球覆盖层（**浏览器窗口内**，主窗 ZStack 顶层）—— **V3 辅佐触盘**形态
/// （design/agent-ball/prototype-v1.html，2026-10-04 用户定稿）：
/// - 真液态玻璃：`.glassEffect` 在主窗内能采样网页内容（独立透明面板
///   采样不到跨进程背景，会退化成实心灰——前两版实拍）；
/// - 交互 = iOS AssistiveTouch：点球弹出径向触盘（2×2 大圆按钮依次弹入，
///   热区大、盲点得中），球图标切换 ✕；点触盘外任意处 / 再点球收起；
///   拖动任意位置、松手 spring 吸附最近左右缘（命名坐标空间，见 body 注释）；
/// - 动效口径（v5 方向 A「绽放」定稿，design/agent-ball/prototype-v2.html
///   2026-10-07 用户拍板）：开盘 = 盘从球的位置弹性放大 + 格子外弹过冲 +
///   一次性掠光；**不做常驻装饰动画**（无呼吸），悬停 = 轻微放大 + brightness；
///   瞬态活跃态例外：触盘弹入 stagger、录音波纹 + 球内五柱波形、忙碌缺口弧旋转；
/// - 状态全在球上：忙碌缺口弧 / 录音红玻璃 + 波形 / 回复就绪绿徽章
///   （悬停球出回复预览气泡）；录音时触盘内附实时转写条；
///   语音发出后球旁弹"已发送"玻璃胶囊（3.6s 自散）；
/// - 触盘带页面上下文菜单头（favicon + 标题 + 问本页）；长按球或 ⌄
///   切换全 8 能力（4×2）；拖拽投递松手弹动作选择（总结/翻译/提问）；
/// - 位置持久化（吸附侧 + 纵向比例）。
struct AgentBallOverlay: View {
    /// overlay 的固定坐标空间名（拖动手势用，见 body 注释）。
    static let overlaySpace = "agentBallOverlay"

    @ObservedObject var state: AgentBallPanel
    @Environment(\.appAccent) private var appAccent: Color

    @AppStorage(AgentBallPanel.sizeKey) private var ballSize: Double = 52
    @AppStorage(AgentBallPanel.edgeKey) private var edge: String = "left"
    @AppStorage(AgentBallPanel.offsetKey) private var offsetFraction: Double = 0.5
    // v6 个性化（悬浮球设置子页）。
    @AppStorage(AgentBallPanel.opacityKey) private var ballOpacity: Double = 1.0
    @AppStorage(AgentBallPanel.idleStyleKey) private var idleStyle: String = "ring"
    @AppStorage(AgentBallPanel.hubScaleKey) private var hubScale: Double = 1.0
    @AppStorage(AgentBallPanel.hubAnimationKey) private var hubAnimation: Bool = true
    @AppStorage(AgentBallPanel.doubleClickVoiceKey) private var doubleClickVoice: Bool = true

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
    /// 拖拽投递悬停（v4）：拖链接/选区悬到球上时球放大 + 强调环。
    @State private var dropHover = false
    /// 语音已发送提示（球旁玻璃胶囊，短暂显示）。
    @State private var sentToast: String?
    @State private var toastTask: Task<Void, Never>?
    /// 触盘弹入驱动（HubContent 拿它做按钮 stagger）。
    @State private var hubAppeared = false

    // 触盘几何（照原型 V3 定稿：2×2 大圆按钮）。v6：尺寸随设置页
    // 「触盘尺寸」档位整体缩放（紧凑 0.86 / 标准 1.0 / 宽松 1.14）。
    private var hubCell: CGFloat { 84 * hubScale }
    private var hubGap: CGFloat { 10 * hubScale }
    private var hubPad: CGFloat { 14 * hubScale }
    /// 开盘掠光（v5 方向 A）+ 球按下压感（微交互精修）。
    @State private var shimmer = false
    @State private var pressing = false
    /// 长按计时起点（DragGesture onChanged 首帧起算；≥0.4s = 全 8 能力切换）。
    @State private var pressStarted: Date?
    /// 球悬停（回复预览气泡的显示条件之一）。
    @State private var ballHovering = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if state.isExpanded, !state.hiddenForFullscreen {
                    // 点外收起层：挡在网页与触盘之间（触盘自己吞掉背景点击）。
                    // 打开期间页面点击不可用——命令模式语义，与 AssistiveTouch 一致。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.isExpanded = false
                            state.cancelDrop()
                        }
                    hub(in: geo.size)
                        .transition(.opacity)
                }
                if !state.hiddenForFullscreen {
                    ball(in: geo.size)
                        .position(ballPosition(in: geo.size))
                }
                // 回复预览气泡（v5）：徽章在窗 + 悬停球 → 免开面板先睹。
                if state.replyFlash, let preview = state.replyPreview,
                   !state.isExpanded, ballHovering, !state.hiddenForFullscreen {
                    replyBubble(preview, in: geo.size)
                        .transition(.scale(scale: 0.94, anchor: .trailing).combined(with: .opacity))
                }
                // 拖投动作选择（v5）：松手后挂在球旁，点选才起回合。
                if state.pendingDrop != nil, !state.hiddenForFullscreen {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { state.cancelDrop() }
                    dropMenu(in: geo.size)
                        .transition(.scale(scale: 0.92, anchor: .trailing).combined(with: .opacity))
                }
                if let toast = sentToast, !state.hiddenForFullscreen {
                    toastPill(toast, in: geo.size)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                // v7 快捷动作反馈（AI 去广告/视频下载的结果）——同款胶囊。
                if let toast = state.actionToast, !state.hiddenForFullscreen {
                    toastPill(toast, in: geo.size)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            // 固定坐标空间：手势挂在会移动的球上，默认 .local 会随球
            // 一起动——translation 被自我抵消，拖动只剩半速（实测 492pt
            // 只走 246pt）。命名空间相对 overlay 静止，手势值才准。
            .coordinateSpace(.named(Self.overlaySpace))
            // 触盘弹出/收起与球图标 ✕ 切换由这一个动画驱动。
            // 展开/收起分速（v7 精修）：展开要有"绽放"弹性，收起要干脆——
            // 同一根弹簧两头都黏。
            .animation(
                hubAnimation
                    ? (state.isExpanded
                        ? .spring(response: 0.42, dampingFraction: 0.75)
                        : .spring(response: 0.3, dampingFraction: 0.88))
                    : nil,
                value: state.isExpanded)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: sentToast)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.actionToast)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.pendingDrop)
            .animation(.easeOut(duration: 0.2), value: ballHovering)
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

    /// 窗口圆角避让距（0.7.1 走查实测：6/10pt 的旧间距让球深陷窗口圆角
    /// 半径区，左下被窗口遮罩裁成扁椭圆）。侧向 16 / 纵向 26 让球整体
    /// 离开圆角区。
    private var sideInset: CGFloat { 16 }
    private var edgeInset: CGFloat { 26 }

    /// 静止球心：由持久化 (edge, offsetFraction) + 当前窗口尺寸推导。
    private func restingCenter(in size: CGSize) -> CGPoint {
        let x = edge == "left" ? ballSize / 2 + sideInset : size.width - ballSize / 2 - sideInset
        let travel = max(0, size.height - ballSize - edgeInset * 2)
        let y = ballSize / 2 + edgeInset + travel * min(max(offsetFraction, 0), 1)
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
            // 忙碌：缺口弧旋转（v5 微交互精修——替代整圈静环，动而不闹）
            if state.agentBusy {
                BusyArc(color: appAccent)
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
            // 液态玻璃球体：图标 = 目标环 ↔ ✕（录音时 = 球内五柱波形，红玻璃）
            ZStack {
                targetIcon
                    .opacity(iconState == .target ? 1 : 0)
                    .scaleEffect(iconState == .target ? 1 : 0.55)
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .opacity(iconState == .close ? 1 : 0)
                    .scaleEffect(iconState == .close ? 1 : 0.55)
                if state.voice.isRecording {
                    // 录音波形（v5 微交互精修：球内五柱起伏，替代静态麦克风）
                    BallWaveform(color: .white)
                        .opacity(iconState == .mic ? 1 : 0)
                        .scaleEffect(iconState == .mic ? 1 : 0.55)
                }
            }
            .frame(width: ballSize, height: ballSize)
            .glassEffect(
                state.voice.isRecording
                    ? .regular.tint(Color.red.opacity(0.55)).interactive()
                    : .regular.interactive(),
                in: .circle
            )
        }
        // 展开时球微缩退后（v7 精修）：视觉焦点让给触盘，球从"操作对象"
        // 变"关闭按钮"。压感 0.9 与之复合。
        .scaleEffect(dropHover ? 1.16 : hoverScale * (pressing ? 0.9 : 1) * (state.isExpanded ? 0.94 : 1))
        .rotationEffect(.degrees(dragTilt))
        .brightness(hoverScale > 1 ? 0.03 : 0)
        .contentShape(Circle())
        .onHover { hovering in
            ballHovering = hovering
            withAnimation(.easeOut(duration: 0.15)) { hoverScale = hovering ? 1.05 : 1.0 }
        }
        .contextMenu {
            Button("重置位置") { resetPosition(in: size) }
            Divider()
            Button("隐藏悬浮球") { state.setEnabled(false) }
        }
        .gesture(dragGesture(in: size))
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: state.replyFlash)
        // 拖拽投递（v4）：拖链接/选区文本到球上 → 球放大 + 强调环提示，松手
        // 以带上下文的提示起回合。悬停态优先于普通 hover 缩放。
        .scaleEffect(dropHover ? 1.16 : hoverScale)
        .overlay {
            if dropHover {
                Circle()
                    .stroke(appAccent.opacity(0.9), lineWidth: 3)
                    .frame(width: ballSize + 14, height: ballSize + 14)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            state.deliverDrop(url.absoluteString)
            return true
        } isTargeted: { dropHover = $0 }
        .dropDestination(for: String.self) { texts, _ in
            guard let text = texts.first else { return false }
            state.deliverDrop(text)
            return true
        } isTargeted: { dropHover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dropHover)
        // v6 个性化：球体不透明度（设置子页 Slider；半透明仍可点，热区不变）。
        .opacity(ballOpacity)
    }

    private enum BallIcon { case target, close, mic }

    private var iconState: BallIcon {
        if state.voice.isRecording { return .mic }
        return state.isExpanded ? .close : .target
    }

    /// 触盘待机图标（v6 可定制）：「触环」= 外环 + 心点（AssistiveTouch 语汇，
    /// 默认）；「图标」= Agent 徽标（wand.and.stars，一眼识别这是 AI 入口）。
    @ViewBuilder
    private var targetIcon: some View {
        if idleStyle == "icon" {
            Image(systemName: "wand.and.stars")
                .font(.system(size: ballSize * 0.34, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .frame(width: ballSize * 0.42, height: ballSize * 0.42)
        } else {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.8)
                Circle()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 7, height: 7)
            }
            .frame(width: ballSize * 0.42, height: ballSize * 0.42)
        }
    }

    // MARK: - 拖动 / 点击

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.overlaySpace))
            .onChanged { value in
                guard !state.isExpanded else { return }
                if dragStartCenter == nil {
                    dragStartCenter = restingCenter(in: size)
                    pressStarted = Date()
                }
                // 按压回弹（v7 精修）：压下/释放都走弹簧，不再瞬时突变。
                withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                    pressing = dragged == false
                }
                let t = value.translation
                if abs(t.width) > 4 || abs(t.height) > 4 {
                    dragged = true
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                        pressing = false
                    }
                }
                if dragged, let start = dragStartCenter {
                    var c = CGPoint(x: start.x + t.width, y: start.y + t.height)
                    c.x = min(max(c.x, ballSize / 2 + sideInset), max(ballSize / 2 + sideInset, size.width - ballSize / 2 - sideInset))
                    c.y = min(max(c.y, ballSize / 2 + edgeInset), max(ballSize / 2 + edgeInset, size.height - ballSize / 2 - edgeInset))
                    dragPos = c
                    dragTilt = max(-10, min(10, value.velocity.width / 36))
                }
            }
            .onEnded { _ in
                defer {
                    dragStartCenter = nil
                    dragPos = nil
                    dragged = false
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.62)) {
                        pressing = false
                    }
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { dragTilt = 0 }
                if dragged {
                    snapToEdge(in: size)
                    lastTap = nil
                    return
                }
                // 长按（≥0.4s）= 2×2 ⇄ 全 8 能力切换（v5；本分支先于点按
                // 开合返回，天然吞掉本次点按）。
                if let started = pressStarted, Date().timeIntervalSince(started) >= 0.4 {
                    pressStarted = nil
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        state.hubShowsAll.toggle()
                    }
                    state.isExpanded = true
                    return
                }
                pressStarted = nil
                if state.voice.isRecording {
                    // 录音中点击球 = 开合触盘（停止入口在触盘的"停止并发送"）
                    lastTap = nil
                    state.isExpanded.toggle()
                } else if doubleClickVoice,
                          let last = lastTap, Date().timeIntervalSince(last) < 0.35 {
                    // 双击 = 直达语音（v6 可关：关掉后双击当两次普通点按）
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
        let travel = max(1, size.height - ballSize - edgeInset * 2)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            edge = toLeft ? "left" : "right"
            offsetFraction = min(max((c.y - ballSize / 2 - edgeInset) / travel, 0), 1)
        }
    }

    private func resetPosition(in size: CGSize) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            edge = "left"
            offsetFraction = 0.5
        }
    }

    // MARK: - 触盘（2×2 径向圆按钮，球上方或下方）

    /// 全 8 能力模式的格子尺寸（4×2，比主格小一号）。
    private var hubCellSmall: CGFloat { 52 * hubScale }
    private var hubWidth: CGFloat {
        state.hubShowsAll ? hubPad * 2 + hubCellSmall * 4 + hubGap * 3 : hubPad * 2 + hubCell * 2 + hubGap
    }
    private var hubHeight: CGFloat {
        let grid: CGFloat = state.hubShowsAll ? hubCellSmall * 2 + hubGap : hubCell * 2 + hubGap
        // +26 = 菜单头（favicon + 页面标题 + 问本页）；+16 = ⌄ chip 行（仅 2×2）
        let chip: CGFloat = state.hubShowsAll ? 0 : 16
        var height = hubPad * 2 + grid + 26 + chip
        if state.voice.isRecording { height += 44 }
        return height
    }

    private func hub(in size: CGSize) -> some View {
        let c = restingCenter(in: size)
        let above = c.y - ballSize / 2 - 10 - hubHeight < 8
        let hubY = above
            ? c.y + ballSize / 2 + 10 + hubHeight / 2
            : c.y - ballSize / 2 - 10 - hubHeight / 2
        let halfW = hubWidth / 2
        let hubX = min(max(c.x, halfW + 6), max(halfW + 6, size.width - halfW - 6))
        return AgentBallHub(state: state, cellSize: state.hubShowsAll ? hubCellSmall : hubCell,
                            appear: hubAppeared, animate: hubAnimation,
                            // 弹入方向 = 从球的一侧进入：盘在球上方时格子自下
                            // 而上浮入（+14），盘在下方时自上而下（-14）——
                            // 此前固定 +14，盘在球下方时方向是反的。
                            enterOffset: above ? 14 : -14)
            .frame(width: hubWidth)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            // v5 · 方向 A「绽放」：盘从球的位置弹性放大（锚点朝球一侧）。
            // v6：弹入动画可在设置子页整体关闭（绽放/弹入/掠光全跳过，盘直接出现）。
            .scaleEffect(hubAppeared || !hubAnimation ? 1 : 0.55, anchor: above ? .bottom : .top)
            .animation(hubAnimation ? .spring(response: 0.42, dampingFraction: 0.78) : nil,
                       value: hubAppeared)
            // 开盘一次性掠光（0.8s，延迟到格子弹出中段）。
            .overlay { hubShimmer }
            .onTapGesture {}  // 吞掉触盘背景点击：不落到"点外收起"层
            .position(x: hubX, y: hubY)
            .onAppear {
                // 动画关闭：不做 stagger/掠光节奏，直接落位。
                if !hubAnimation {
                    hubAppeared = true
                } else {
                    hubAppeared = true
                    shimmer = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(40))
                        shimmer = true
                        try? await Task.sleep(for: .milliseconds(1100))
                        shimmer = false
                    }
                }
            }
            .onDisappear {
                hubAppeared = false
                shimmer = false
            }
    }

    /// 掠光：斜向白渐变从右扫到左（掩在盘形里，不挡交互）。动画总开关关闭时不跑。
    @ViewBuilder
    private var hubShimmer: some View {
        if shimmer, hubAnimation {
            GeometryReader { geo in
                LinearGradient(colors: [.clear, .white.opacity(0.30), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: shimmer ? geo.size.width : -geo.size.width)
                    .animation(.easeOut(duration: 0.9), value: shimmer)
            }
            .clipShape(.rect(cornerRadius: 26))
            .allowsHitTesting(false)
        }
    }

    // MARK: - 球旁浮卡（v5：回复预览气泡 / 拖投动作选择）

    /// 浮卡横向落点：球在哪缘，卡就朝窗口内侧展开。
    private func sideCardX(_ c: CGPoint, in size: CGSize, width: CGFloat) -> CGFloat {
        let onLeft = c.x < size.width / 2
        let x = onLeft ? c.x + ballSize / 2 + 10 + width / 2
                       : c.x - ballSize / 2 - 10 - width / 2
        return max(width / 2 + 6, x)
    }

    private func replyBubble(_ preview: String, in size: CGSize) -> some View {
        let c = ballPosition(in: size)
        let width: CGFloat = 232
        return VStack(alignment: .leading, spacing: 4) {
            Text("已回复 · 刚刚")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.green)
            Text(preview)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Button {
                state.openAgentPanel()
            } label: {
                Text("打开对话 →")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(appAccent)
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .frame(width: width, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .onTapGesture {}  // 卡内点击不落到关闭层（「打开对话」自己有回调）
        .position(x: sideCardX(c, in: size, width: width), y: c.y)
    }

    private func dropMenu(in size: CGSize) -> some View {
        let c = ballPosition(in: size)
        let width: CGFloat = 176
        let isURL = state.pendingDropIsURL
        let noun = isURL ? "此链接" : "此选区"
        return VStack(alignment: .leading, spacing: 2) {
            Text(isURL ? "链接已拖入" : "选区已拖入")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
            dropItem("sparkles", "总结\(noun)") { state.resolveDrop(.summarize) }
            dropItem("character.book.closed", "翻译\(noun)") { state.resolveDrop(.translate) }
            dropItem(isURL ? "arrow.up.forward" : "questionmark.bubble",
                     isURL ? "打开并询问" : "就此提问") { state.resolveDrop(.ask) }
        }
        .padding(6)
        .frame(width: width, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .onTapGesture {}
        .position(x: sideCardX(c, in: size, width: width), y: c.y)
    }

    private func dropItem(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    /// 弹入动画总开关（v6 设置页可关）——false 时不加 stagger 延时，
    /// 格子直接落位（外层绽放/掠光同被关闭）。
    let animate: Bool
    /// 弹入的纵向进入方向（v7 精修）：+14 = 自下而上（盘在球上方），
    /// -14 = 自上而下（盘在球下方）。
    let enterOffset: CGFloat

    @State private var hovered: Int?
    /// 拖拽投递悬停（v4）：拖链接/选区悬到球上时球放大 + 强调环。
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                hubHead
                if state.hubShowsAll {
                    // 全能力网格（v7：14 项 → 4 列动态行数；**顺序 = 设置子页
                    // 的个人排序表**，不是固定的 allCases）。stagger 序号 = 表
                    // 内下标（别改 hashValue：每次启动随机，乘进 delay 是
                    // 天文数字，格子会永远停在 opacity 0——实测）。
                    let ordered = state.slots
                    let rows = stride(from: 0, to: ordered.count, by: 4).map {
                        Array(ordered[$0..<min($0 + 4, ordered.count)])
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(rows[row]) { capability in
                                hubCell(ordered.firstIndex(of: capability) ?? 0, capability)
                            }
                        }
                    }
                    collapseChip
                        .transition(.opacity)
                } else {
                    // 主槽 2×2（V3 定稿布局；编号 = 槽位**位置** 0…3，同时是
                    // 弹入动画的 stagger 序号——别改成 hashValue：它每次启动
                    // 随机且量级 ±2^63，乘进动画 delay 就是天文数字，格子会
                    // 永远停在 opacity 0（实测）。
                    HStack(spacing: 10) {
                        hubCell(0, state.slots[0])
                        hubCell(1, state.slots[1])
                    }
                    HStack(spacing: 10) {
                        hubCell(2, state.slots[2])
                        hubCell(3, state.slots[3])
                    }
                    moreChip
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.hubShowsAll)
            if state.voice.isRecording {
                transcriptChip
                    .transition(.opacity)
            }
        }
        .padding(14)
    }

    /// 页面上下文菜单头（v5）：favicon + 页面标题 + 「问本页」。
    @ViewBuilder
    private var hubHead: some View {
        if let ctx = state.pageContextProvider?() {
            HStack(spacing: 7) {
                FaviconView(urlString: ctx.urlString, size: 15)
                Text(ctx.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button {
                    state.askAboutPage()
                } label: {
                    Text("问本页")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(appAccent.opacity(0.14), in: Capsule())
                        .foregroundStyle(appAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 9)
            .opacity(appear ? 1 : 0)
            .animation(animate ? .easeOut(duration: 0.32).delay(0.24) : nil, value: appear)
        }
    }

    private var moreChip: some View {
        Button {
            state.hubShowsAll = true
        } label: {
            Text("⌄ 全部 \(BallCapability.allCases.count) 项")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .opacity(appear ? 1 : 0)
        .animation(animate ? .easeOut(duration: 0.3).delay(0.3) : nil, value: appear)
    }

    /// 全览态的退回 chip（v7 修复："展开全部后不能退回"）——收起回 2×2
    /// 主盘；收起触盘时 isExpanded didSet 也会自动复位 hubShowsAll。
    private var collapseChip: some View {
        Button {
            state.hubShowsAll = false
        } label: {
            Text("⌃ 回到主盘")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .opacity(appear ? 1 : 0)
        .animation(animate ? .easeOut(duration: 0.3).delay(0.3) : nil, value: appear)
    }

    @ViewBuilder
    private func hubCell(_ index: Int, _ capability: BallCapability) -> some View {
        let recording = capability == .voice && state.voice.isRecording
        let title = recording ? "停止并发送" : capability.displayName
        let icon = recording ? "stop.circle.fill" : capability.icon
        cell(index, icon: icon, title: title, recording: recording) {
            state.perform(capability)
        }
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
                    .font(.system(size: cellSize < 60 ? 9.5 : 10.5, weight: .medium))
                    .minimumScaleFactor(cellSize < 60 ? 0.8 : 1)
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
            withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                hovered = hovering ? index : (hovered == index ? nil : hovered)
            }
        }
        // 悬停微浮起（v7 精修）：1pt 上移让"选中感"有位移分量，不只填色。
        .offset(y: hovered == index && appear ? -1 : (appear ? 0 : enterOffset))
        .scaleEffect(appear ? 1 : 0.4)
        .opacity(appear ? 1 : 0)
        .animation(animate
            ? .spring(response: 0.4, dampingFraction: 0.68).delay(Double(index) * 0.05)
            : nil,
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
/// 忙碌缺口弧（v5 微交互精修）：3/4 圆弧持续旋转——动而不闹
/// （替代原整圈静环；克制口径的例外与录音波纹同规：瞬态活跃态）。
private struct BusyArc: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// 录音球内五柱波形（v5 微交互精修）：起伏错相，替代静态麦克风。
private struct BallWaveform: View {
    let color: Color
    @State private var animate = false
    private let peaks: [CGFloat] = [10, 16, 11, 17, 8]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.6, height: animate ? peaks[i] : 5)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.09), value: animate)
            }
        }
        .onAppear { animate = true }
    }
}

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
