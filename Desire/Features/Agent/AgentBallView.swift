import SwiftUI

/// 悬浮球视图——**iOS 26 Liquid Glass 风格**（macOS 26 原生 `.glassEffect`）：
/// 半透明液态玻璃球（可交互反馈）+ 同材质操作条，状态用 tint 表达
/// （录音=红 tint、忙碌=进度环）。交互由 AgentBallHostingView（AppKit）
/// 承担，这里只做视觉。
struct AgentBallView: View {
    @ObservedObject var panel: AgentBallPanel
    @ObservedObject var voice: VoiceInputManager
    @Environment(\.appAccent) private var appAccent: Color

    @AppStorage(AgentBallPanel.sizeKey) private var ballSize: Double = 52
    @AppStorage(AgentBallPanel.edgeKey) private var edge: String = "left"
    @State private var hoverScale: CGFloat = 1.0
    @State private var pulse: CGFloat = 1.0
    @State private var ringRotation: Double = 0

    private var alignLeft: Bool { edge != "right" }

    var body: some View {
        // 卡在球上方、同贴吸附侧
        VStack(alignment: alignLeft ? .leading : .trailing, spacing: 8) {
            if panel.isExpanded {
                menuCard
                    .padding(.leading, alignLeft ? 4 : 0)
                    .padding(.trailing, alignLeft ? 0 : 4)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8, anchor: alignLeft ? .bottomLeading : .bottomTrailing)
                            .combined(with: .opacity),
                        removal: .opacity))
            }
            ball
                .padding(.leading, panel.isExpanded && alignLeft ? 2 : 0)
                .padding(.trailing, panel.isExpanded && !alignLeft ? 2 : 0)
        }
        .frame(width: panelWidth, height: panelHeight,
               alignment: alignLeft ? .bottomLeading : .bottomTrailing)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = 1.03
            }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
        }
    }

    private var panelWidth: CGFloat { panel.isExpanded ? max(240, ballSize + 188) : ballSize }
    private var panelHeight: CGFloat { panel.isExpanded ? ballSize + 176 : ballSize }

    // MARK: - 液态玻璃球

    private var ball: some View {
        ZStack {
            // 回复就绪徽章（busy 下降沿闪光）
            if panel.replyFlash {
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
            // 忙碌：外圈进度环（玻璃外的状态层）
            if panel.agentBusy {
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(appAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: ballSize + 12, height: ballSize + 12)
                    .rotationEffect(.degrees(ringRotation))
            }
            Image(systemName: voice.isRecording ? "mic.fill" : "sparkles")
                .font(.system(size: ballSize * 0.36, weight: .medium))
                .foregroundStyle(voice.isRecording ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: ballSize, height: ballSize)
                .glassEffect(
                    voice.isRecording
                        ? .regular.tint(Color.red.opacity(0.55)).interactive()
                        : .regular.interactive(),
                    in: .circle
                )
        }
        .scaleEffect(hoverScale * pulse)
        .rotationEffect(.degrees(panel.dragTilt))
        .contentShape(Circle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { hoverScale = hovering ? 1.06 : 1.0 }
        }
    }

    // MARK: - 操作条（液态玻璃卡）

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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(width: panelWidth - 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var transcriptChip: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 6, height: 6)
            Text(voice.transcribedText.isEmpty ? "聆听中…" : voice.transcribedText)
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
