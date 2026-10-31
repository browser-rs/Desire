import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// 播放模式 ↔ chrome 收放（IINA 式）：写 BrowserState.mediaPlayerImmersive。
    var onImmersiveChange: ((Bool) -> Void)? = nil
    /// 播放队列自动切下一首：由 SelectedTabContent 换 mediaViewerURL。
    var onSwitchFile: ((URL) -> Void)? = nil
    @ObservedObject private var playlist = MediaPlaylistStore.shared

    @StateObject private var model: MediaPlayerModel
    @State private var playbackMode = false
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var flashIcon: String?
    @State private var flashTask: Task<Void, Never>?
    @State private var scrubTarget: Double?
    /// 自持光标隐藏标志：NSCursor.hide/unhide 是计数栈，靠这个标志保证配对。
    @State private var cursorHidden = false
    /// 命中层引用（窗口按画面比例缩放时读 window 与实际播放面积）。
    @State private var surfaceView: PlayerSurfaceView?
    // 字幕样式（按应用记忆）。
    @AppStorage("media.subtitleScale") private var subtitleScale = 1.0
    @AppStorage("media.subtitlePosition") private var subtitlePosition = "bottom"

    init(fileURL: URL, fileName: String, onBack: @escaping () -> Void,
         onEdit: (() -> Void)? = nil, onImmersiveChange: ((Bool) -> Void)? = nil,
         onSwitchFile: ((URL) -> Void)? = nil) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.onBack = onBack
        self.onEdit = onEdit
        self.onImmersiveChange = onImmersiveChange
        self.onSwitchFile = onSwitchFile
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
                              onLayerReady: { model.setupPictureInPicture(layer: $0) },
                              onSurfaceReady: { surfaceView = $0 })
            } else {
                // 音频模式：透明命中层接点击/键盘，艺术位不抢手势。
                PlayerSurface(player: nil,
                              onActivity: userActivity,
                              onClick: handleSurfaceClick,
                              onKey: handleKey,
                              onSurfaceReady: { surfaceView = $0 })
                audioArtwork
            }
            subtitleOverlay
            if model.loadError == nil {
                controlsOverlay
            }
        }
        .id(fileURL)
        .onAppear {
            MediaPlaylistStore.shared.activate(fileURL)
            setPlaybackMode(model.hasVideo)
            scheduleHide()
        }
        .onChange(of: playlist.autoAdvanceTo) { _, next in
            guard let next else { return }
            playlist.consumeAutoAdvance()
            onSwitchFile?(next)
        }
        .onDisappear {
            hideTask?.cancel()
            model.savePosition()
            setCursorHidden(false)
            setPlaybackMode(false)
            surfaceView = nil
        }
        .onChange(of: model.isPlaying) { _, _ in scheduleHide() }
    }

    // MARK: - 字幕浮层（外挂字幕；不随控制条隐藏——播着就得看得见）

    @ViewBuilder
    private var subtitleOverlay: some View {
        if model.subtitlesEnabled, !model.currentSubtitleText.isEmpty {
            Text(model.currentSubtitleText)
                .multilineTextAlignment(.center)
                .font(.system(size: 17 * subtitleScale, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 2)
                .shadow(color: .black.opacity(0.85), radius: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: subtitlePosition == "top" ? .top
                           : (subtitlePosition == "middle" ? .center : .bottom))
                .padding(.horizontal, 48)
                .padding(.bottom, subtitlePosition == "bottom" ? (controlsVisible ? 96 : 26) : 0)
                .padding(.top, subtitlePosition == "top" ? (controlsVisible ? 96 : 26) : 0)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
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
                addToQueue()
            } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
            .help(String(localized: "Add to Queue"))
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
                if playlist.hasMultiple {
                    Button {
                        if let previous = playlist.skip(-1) { onSwitchFile?(previous) }
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                    .help(String(localized: "Previous"))
                    Button {
                        if let next = playlist.skip(1) { onSwitchFile?(next) }
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                    .help(String(localized: "Next"))
                }
                playButton
                stepButtons
                Text(timeDisplay)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .contentShape(Rectangle())
                Spacer(minLength: 10)
                speedMenu
                subtitleMenu
                volumeGroup
                repeatButton
                if model.hasVideo {
                    loopButton
                    pipButton
                    windowSizeMenu
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

    private var subtitleMenu: some View {
        Menu {
            if model.subtitleFileName != nil {
                Button(model.subtitlesEnabled
                       ? String(localized: "Hide Subtitles")
                       : String(localized: "Show Subtitles")) {
                    model.toggleSubtitles()
                }
                Button(String(localized: "Unload Subtitles"), role: .destructive) {
                    model.unloadSubtitles()
                }
                Divider()
                Button(String(format: "Subtitle Delay: %+.1fs (−0.5)", model.subtitleOffset)) {
                    model.subtitleOffset -= 0.5
                }
                Button(String(format: "Subtitle Delay: %+.1fs (+0.5)", model.subtitleOffset)) {
                    model.subtitleOffset += 0.5
                }
                if model.subtitleOffset != 0 {
                    Button(String(localized: "Reset Delay")) { model.subtitleOffset = 0 }
                }
                Divider()
                Menu(String(localized: "Subtitle Size")) {
                    ForEach([("80%", 0.8), ("100%", 1.0), ("130%", 1.3), ("160%", 1.6)], id: \.1) { label, scale in
                        Button(label) { subtitleScale = scale }
                    }
                }
                Menu(String(localized: "Subtitle Position")) {
                    Button(String(localized: "Bottom")) { subtitlePosition = "bottom" }
                    Button(String(localized: "Middle")) { subtitlePosition = "middle" }
                    Button(String(localized: "Top")) { subtitlePosition = "top" }
                }
            }
            Button(String(localized: "Load Subtitle File…")) { loadSubtitlePanel() }
        } label: {
            Image(systemName: model.subtitlesEnabled ? "captions.fill" : "captions")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(model.subtitleFileName != nil
              ? String(localized: "Subtitles: \(model.subtitleFileName ?? "")")
              : String(localized: "Subtitles"))
    }

    private func loadSubtitlePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = SubtitleCore.subtitleExtensions
            .compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.loadSubtitles(at: url)
    }

    /// IINA 式窗口缩放：把窗口内容面积调成「chrome 高度 + 画面 × 倍率」，
    /// 左上角不动，钳到屏幕可见区。读命中层实测高度，播放模式（chrome 收起）
    /// 与普通模式都成立。
    private func resizeWindow(toScale scale: Double) {
        guard let surface = surfaceView, let window = surface.window,
              let contentView = window.contentView,
              model.videoSize.width > 0, model.videoSize.height > 0 else { return }
        let chromeWidth = contentView.bounds.width - surface.bounds.width
        let chromeHeight = contentView.bounds.height - surface.bounds.height
        let titlebarHeight = window.frame.height - contentView.bounds.height
        var width = model.videoSize.width * scale + chromeWidth
        var height = model.videoSize.height * scale + chromeHeight
        if let screen = window.screen ?? NSScreen.main {
            let maxContentWidth = screen.visibleFrame.width
            let maxContentHeight = screen.visibleFrame.height - titlebarHeight
            let fit = min(1, maxContentWidth / max(1, width), maxContentHeight / max(1, height))
            if fit < 1 {
                width *= fit
                height *= fit
            }
        }
        width = max(width, window.minSize.width)
        height = max(height, window.minSize.height - titlebarHeight)
        let newFrame = NSRect(x: window.frame.minX,
                              y: window.frame.maxY - height - titlebarHeight,
                              width: width, height: height + titlebarHeight)
        window.setFrame(newFrame, display: true, animate: true)
    }

    private var windowSizeMenu: some View {
        Menu {
            Button("50%") { resizeWindow(toScale: 0.5) }
            Button("100%") { resizeWindow(toScale: 1) }
            Button("200%") { resizeWindow(toScale: 2) }
        } label: {
            Image(systemName: "macwindow")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(String(localized: "Resize window to picture size"))
    }

    private var repeatButton: some View {
        Button {
            switch playlist.repeatMode {
            case .off: playlist.repeatMode = .list
            case .list: playlist.repeatMode = .single
            case .single: playlist.repeatMode = .off
            }
        } label: {
            Image(systemName: playlist.repeatMode == .single
                  ? "repeat.1" : "repeat")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(playlist.repeatMode == .off
                                 ? AnyShapeStyle(.white.opacity(0.9))
                                 : AnyShapeStyle(appAccent))
        }
        .buttonStyle(.plain)
        .help(playlist.repeatMode == .off
              ? String(localized: "Repeat Off")
              : (playlist.repeatMode == .list
                 ? String(localized: "Repeat List")
                 : String(localized: "Repeat One")))
    }

    private var loopButton: some View {
        Button {
            model.cycleLoopPoint()
        } label: {
            Image(systemName: model.isLoopActive ? "repeat.1.circle.fill" : "repeat.1")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.isLoopActive ? appAccent : .white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .help(loopHelp)
    }

    private var loopHelp: String {
        if model.isLoopActive, let a = model.loopA, let b = model.loopB {
            return String(format: "A-B %.1fs–%.1fs", a, b)
        }
        if model.loopA != nil { return String(localized: "Mark Loop End (B)") }
        return String(localized: "Mark Loop Start (A)")
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
        setPlaybackMode(!playbackMode)
    }

    /// 播放模式切换统一收口：状态 + chrome 通知（BrowserState.mediaPlayerImmersive
    /// → ContentView 的 PlayerImmersiveGate 收起标签栏/工具栏）+ 光标复位。
    private func setPlaybackMode(_ on: Bool) {
        guard playbackMode != on else { return }
        playbackMode = on
        controlsVisible = true
        onImmersiveChange?(on)
        if !on { setCursorHidden(false) }
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
        case 4:    // h
            captureFrame()
            return true
        case 37:   // l
            model.cycleLoopPoint()
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

    /// 顶栏「加入队列」：选多个媒体文件接在当前队列后。
    private func addToQueue() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        MediaPlaylistStore.shared.add(panel.urls)
    }

    /// H 键截当前帧：AVAssetImageGenerator 精准取帧 → PNG 进剪贴板。
    private func captureFrame() {
        let time = model.currentTime
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        Task { @MainActor in
            do {
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                let rep = NSBitmapImageRep(cgImage: image)
                if let png = rep.representation(using: .png, properties: [:]) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(png, forType: .png)
                    showFlash("camera.viewfinder")
                }
            } catch {
                showFlash("exclamationmark.triangle")
            }
        }
    }

    // MARK: - 控制条显隐

    private func userActivity() {
        setControlsVisible(true)
        scheduleHide()
    }

    /// 切换沿统一收口：NSCursor.hide/unhide 是**计数栈**，每轮 hide 会叠加、
    /// 一次 unhide 解不开——只在状态变化的那一次配对调用。
    private func setControlsVisible(_ visible: Bool) {
        guard visible != controlsVisible else { return }
        withAnimation(visible ? .easeIn(duration: 0.15) : .easeOut(duration: 0.3)) {
            controlsVisible = visible
        }
        setCursorHidden(playbackMode && !visible)
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard playbackMode, model.isPlaying else {
            setControlsVisible(true)
            setCursorHidden(false)
            return
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, playbackMode, model.isPlaying else { return }
            setControlsVisible(false)
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
    var onSurfaceReady: ((PlayerSurfaceView) -> Void)? = nil

    func makeNSView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.player = player
        if let onLayerReady, let videoLayer = view.layer as? AVPlayerLayer {
            onLayerReady(videoLayer)
        }
        if let onSurfaceReady {
            DispatchQueue.main.async { onSurfaceReady(view) }
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
