import AVFoundation
import AVKit
import SwiftUI

/// 本地媒体播放器（v0.8.27 播放器批）：AVPlayerLayer + 定制控制层，替代
/// AVKit 默认控件——顶栏（返回/文件名/剪辑/QuickTime）+ 底部控制条（播放/
/// ±10s/进度含缓冲/时间/倍速/音量/画中画/播放模式）。
///
/// - **播放模式**（像真播放器）：拖入视频自动进入——头栏收起、控制条 3 秒
///   无操作自动隐藏、光标同步隐藏；双击切换、Esc/按钮退出。
/// - **键盘**（PlayerSurfaceView 作 firstResponder，点画面即夺焦）：
///   空格 播放暂停、←/→ ±5s、↑/↓ 音量、F 播放模式、Esc 退出播放模式。
/// - **音频文件**：黑场 + 强调色圆形艺术位 + 波形，同一套底部控制条。
/// - 引擎在 MediaPlayerModel；剪辑入口走 ToolboxHandoff（v0.8.27 媒体批）。
struct MediaViewerView: View {
    @Environment(\.appAccent) private var appAccent: Color
    let fileURL: URL
    let fileName: String
    let onBack: () -> Void
    /// 「剪辑」入口：文件递给工具页的视频/音频剪辑（SelectedTabContent 接线）。
    var onEdit: (() -> Void)? = nil

    @StateObject private var model: MediaPlayerModel
    @State private var playbackMode = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var flashIcon: String?
    @State private var flashTask: Task<Void, Never>?
    @State private var scrubTarget: Double?

    init(fileURL: URL, fileName: String, onBack: @escaping () -> Void,
         onEdit: (() -> Void)? = nil) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.onBack = onBack
        self.onEdit = onEdit
        _model = StateObject(wrappedValue: MediaPlayerModel(url: fileURL))
    }

    var body: some View {
        ZStack {
            Color.black
            if let error = model.loadError {
                errorView(error)
            } else if model.hasVideo {
                PlayerSurface(player: model.player,
                              onActivity: userActivity,
                              onClick: handleSurfaceClick,
                              onKey: handleKey,
                              onLayerReady: { model.setupPictureInPicture(layer: $0) })
            } else {
                // 音频模式：透明命中层接点击/键盘，艺术位不抢手势。
                PlayerSurface(player: nil,
                              onActivity: userActivity,
                              onClick: handleSurfaceClick,
                              onKey: handleKey)
                audioArtwork
            }
            if model.loadError == nil {
                controlsOverlay
            }
        }
        .id(fileURL)
        .onAppear {
            if model.hasVideo { playbackMode = true }
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            model.savePosition()
            NSCursor.unhide()
        }
        .onChange(of: playbackMode) { _, _ in
            if !playbackMode { NSCursor.unhide() }
            scheduleHide()
        }
        .onChange(of: model.isPlaying) { _, _ in scheduleHide() }
    }

    // MARK: - 覆盖层

    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Couldn't play this file")
                .font(.system(size: 12, weight: .medium))
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            if controlsVisible {
                topBar
                    .transition(.opacity)
            }
            Spacer()
            if let icon = flashIcon {
                Image(systemName: icon)
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(24)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .transition(.opacity)
            }
            if controlsVisible {
                bottomControls
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: flashIcon)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .help(String(localized: "Back to Page"))
            Text(fileName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 8)
            if let onEdit {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
                .help(String(localized: "Edit (trim / merge)"))
            }
            Button {
                NSWorkspace.shared.open(fileURL)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .help(String(localized: "Open in QuickTime Player"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var bottomControls: some View {
        VStack(spacing: 4) {
            seekBar
                .padding(.horizontal, 14)
                .padding(.top, 2)
            HStack(spacing: 12) {
                playButton
                stepButtons
                Text(timeDisplay)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .contentShape(Rectangle())
                Spacer(minLength: 10)
                speedMenu
                volumeGroup
                if model.hasVideo {
                    pipButton
                }
                modeButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var playButton: some View {
        Button {
            togglePlayWithFlash()
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(model.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }

    private var stepButtons: some View {
        HStack(spacing: 4) {
            Button {
                model.step(-10)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .help(String(localized: "Skip back 10 seconds"))
            Button {
                model.step(10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .help(String(localized: "Skip forward 10 seconds"))
        }
    }

    private var timeDisplay: String {
        let current = MediaEditCore.formatClock(scrubTarget ?? model.currentTime)
        let total = MediaEditCore.formatClock(model.duration)
        return "\(current) / \(total)"
    }

    private var speedMenu: some View {
        Menu {
            ForEach(MediaPlayerModel.speeds, id: \.self) { speed in
                Button {
                    model.setRate(speed)
                } label: {
                    if speed == model.rate {
                        Label(speedText(speed), systemImage: "checkmark")
                    } else {
                        Text(speedText(speed))
                    }
                }
            }
        } label: {
            Text(speedText(model.rate))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(String(localized: "Playback speed"))
    }

    private func speedText(_ speed: Double) -> String {
        speed == speed.rounded() ? "\(Int(speed))×" : String(format: "%.2g×", speed)
    }

    private var volumeGroup: some View {
        HStack(spacing: 5) {
            Button {
                model.isMuted.toggle()
            } label: {
                Image(systemName: model.isMuted || model.volume == 0
                      ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .help(model.isMuted
                  ? String(localized: "Unmute")
                  : String(localized: "Mute"))
            Slider(value: Binding(
                get: { model.isMuted ? 0 : model.volume },
                set: { newValue in
                    model.volume = newValue
                    if newValue > 0 { model.isMuted = false }
                }), in: 0...1)
                .frame(width: 68)
                .tint(.white)
                .help(String(localized: "Playback Volume"))
        }
    }

    private var pipButton: some View {
        Button {
            model.togglePictureInPicture()
        } label: {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .disabled(!model.canPictureInPicture)
        .help(String(localized: "Picture in Picture"))
    }

    private var modeButton: some View {
        Button {
            togglePlaybackMode()
        } label: {
            Image(systemName: playbackMode
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help(playbackMode
              ? String(localized: "Exit Playback Mode")
              : String(localized: "Playback Mode"))
    }

    // MARK: - 进度条

    private var seekBar: some View {
        PlayerSeekBar(
            current: scrubTarget ?? model.currentTime,
            duration: model.duration,
            buffered: model.bufferedSeconds,
            accent: appAccent,
            onScrubStart: { userActivity() },
            onScrubChanged: { scrubTarget = $0 },
            onScrubEnded: {
                if let target = scrubTarget {
                    model.seek(to: target)
                }
                scrubTarget = nil
            })
    }

    // MARK: - 音频艺术位

    private var audioArtwork: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [appAccent.opacity(0.55), appAccent.opacity(0.14)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 190, height: 190)
                if model.isBuffering {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
            Text(fileName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 动作

    private func handleSurfaceClick(_ clickCount: Int) {
        userActivity()
        if clickCount >= 2 {
            // 单击已先切过一次播放状态：双击补一次切回（净效果不变），再切模式。
            model.togglePlay()
            togglePlaybackMode()
        } else {
            togglePlayWithFlash()
        }
    }

    private func togglePlayWithFlash() {
        model.togglePlay()
        showFlash(model.isPlaying ? "pause.fill" : "play.fill")
    }

    private func togglePlaybackMode() {
        playbackMode.toggle()
        controlsVisible = true
        scheduleHide()
    }

    /// 键盘：返回 true 表示已消费（PlayerSurfaceView 不再上抛）。
    private func handleKey(_ event: NSEvent) -> Bool {
        userActivity()
        switch event.keyCode {
        case 49:   // 空格
            togglePlayWithFlash()
            return true
        case 123:  // ←
            model.step(-5)
            return true
        case 124:  // →
            model.step(5)
            return true
        case 126:  // ↑
            model.volume = min(1, model.volume + 0.1)
            return true
        case 125:  // ↓
            model.volume = max(0, model.volume - 0.1)
            return true
        case 3:    // f
            if playbackMode { togglePlaybackMode() }
            return true
        case 53:   // Esc
            if playbackMode {
                togglePlaybackMode()
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: - 控制条显隐

    private func userActivity() {
        if !controlsVisible {
            withAnimation(.easeIn(duration: 0.15)) { controlsVisible = true }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard playbackMode, model.isPlaying else {
            controlsVisible = true
            NSCursor.unhide()
            return
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
            if playbackMode { NSCursor.hide() }
        }
    }

    private func showFlash(_ icon: String) {
        flashTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { flashIcon = icon }
        flashTask = Task {
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { flashIcon = nil }
        }
    }
}

// MARK: - 进度条（自绘：缓冲浅色 + 已播强调色 + 悬停放大）

private struct PlayerSeekBar: View {
    let current: Double
    let duration: Double
    let buffered: Double
    let accent: Color
    var onScrubStart: () -> Void
    var onScrubChanged: (Double) -> Void
    var onScrubEnded: () -> Void

    @State private var isDragging = false
    @State private var isHovering = false

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, current / duration))
    }

    private var bufferedFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, buffered / duration))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = isDragging || isHovering ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.white.opacity(0.34))
                    .frame(width: max(0, width * bufferedFraction), height: trackHeight)
                Capsule()
                    .fill(accent)
                    .frame(width: max(0, width * fraction), height: trackHeight)
                Circle()
                    .fill(accent)
                    .frame(width: 12, height: 12)
                    .shadow(radius: 1.5)
                    .opacity(isDragging || isHovering ? 1 : 0)
                    .offset(x: max(0, width * fraction) - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(dragGesture(width: width))
        }
        .frame(height: 18)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onScrubStart()
                }
                let target = min(1, max(0, width > 0 ? value.location.x / width : 0)) * duration
                onScrubChanged(target)
            }
            .onEnded { _ in
                isDragging = false
                onScrubEnded()
            }
    }
}

// MARK: - 命中层（视频面/音频命中）

/// 承载 AVPlayerLayer 的命中面：firstResponder（键盘）、点击（单击播放/
/// 双击播放模式）、鼠标移动唤起控制条。音频模式 player=nil 作透明命中层。
final class PlayerSurfaceView: NSView {
    var player: AVPlayer? {
        didSet { (layer as? AVPlayerLayer)?.player = player }
    }
    var onActivity: (() -> Void)?
    var onClick: ((Int) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) {
        fatalError("PlayerSurfaceView is created in code only")
    }

    override func makeBackingLayer() -> CALayer {
        let videoLayer = AVPlayerLayer()
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.clear.cgColor
        return videoLayer
    }

    override func mouseMoved(with event: NSEvent) {
        onActivity?()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true {
            super.keyDown(with: event)
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?
    var onActivity: () -> Void
    var onClick: (Int) -> Void
    var onKey: (NSEvent) -> Bool
    var onLayerReady: ((AVPlayerLayer) -> Void)? = nil

    func makeNSView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.player = player
        if let onLayerReady, let videoLayer = view.layer as? AVPlayerLayer {
            onLayerReady(videoLayer)
        }
        // 拖入即想播放：稍候夺焦（有文本编辑器在用时不抢——跳一帧的既有规矩）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak view] in
            guard let view, let window = view.window,
                  !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: PlayerSurfaceView, context: Context) {
        view.player = player
        view.onActivity = onActivity
        view.onClick = onClick
        view.onKey = onKey
    }

    static func dismantleNSView(_ view: PlayerSurfaceView, with coordinator: ()) {
        view.player?.pause()
    }
}
