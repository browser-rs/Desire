import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 多轨时间线编辑器（v0.8.27 剪辑批，剪映式 v1）：视频轨 + 多音频轨 + 文字轨，
/// 片段拖移/裁边/播放头分割/删除，合成实时预览，文字烧录导出，工程存开。
/// 编辑操作全走 TimelineCore（重叠校验失败即弹回原位）。
struct MultiTrackEditorView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @StateObject private var store = VideoEditorStore()

    static let laneHeights: [TimelineCore.TrackKind: CGFloat] = [.text: 30, .video: 56, .audio: 40]
    static let laneGap: CGFloat = 6
    static let rulerHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbarRow
            EditorPreview(store: store, accent: appAccent)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            zoomRow
            EditorTimeline(store: store, accent: appAccent)
                .frame(height: timelineHeight)
            if store.selectedClip != nil {
                inspectorRow
            }
            exportRow
        }
    }

    private var timelineHeight: CGFloat {
        let lanes = store.project.tracks.reduce(CGFloat(0)) { $0 + (Self.laneHeights[$1.kind] ?? 40) }
        return Self.rulerHeight + CGFloat(store.project.tracks.count) * Self.laneGap + lanes + 8
    }

    // MARK: - 工具行

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Add Media…")) { addMedia() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(String(localized: "Add Text")) { store.addTextClip() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Divider().frame(height: 14)
            Button {
                store.splitAtPlayhead()
            } label: {
                Label(String(localized: "Split"), systemImage: "scissors")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.selectedClip == nil && !store.playheadOverlapsClip)
            Button(role: .destructive) {
                store.deleteSelected()
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.selectedClip == nil)
            Button {
                store.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.canUndo)
            .help(String(localized: "Undo"))
            Divider().frame(height: 14)
            Menu {
                Button(String(localized: "Video Track")) {
                    store.commit(TimelineCore.addTrack(store.project, kind: .video))
                }
                Button(String(localized: "Audio Track")) {
                    store.commit(TimelineCore.addTrack(store.project, kind: .audio))
                }
                Button(String(localized: "Text Track")) {
                    store.commit(TimelineCore.addTrack(store.project, kind: .text))
                }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help(String(localized: "Add Track"))
            Spacer()
            Button(String(localized: "New Project")) { store.newProject() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(String(localized: "Open Project…")) { openProject() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button(String(localized: "Save Project…")) { saveProject() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Duration: \(MediaEditCore.formatClock(store.projectDuration))"))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "minus.magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: $store.pixelsPerSecond, in: 12...200)
                .frame(width: 160)
            Image(systemName: "plus.magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 检查器

    private var inspectorRow: some View {
        Group {
            if let (track, clip) = store.selectedClip {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        if let text = clip.text {
                            Text(String(localized: "Text Content"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            TextField("", text: Binding(
                                get: { text },
                                set: { store.updateSelectedText($0) }))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                        } else {
                            Text(clip.label)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(String(localized: "In: \(MediaEditCore.formatClock(clip.start)) · Length: \(MediaEditCore.formatClock(clip.duration))"))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            // 音频片段可在多条音频轨之间移动
                            if track.kind == .audio {
                                Menu {
                                    ForEach(store.project.tracks.filter { $0.kind == .audio }) { target in
                                        Button(target.name) {
                                            store.moveSelected(toTrack: target.id, start: clip.start)
                                        }
                                    }
                                } label: {
                                    Label(String(localized: "Move to Track"), systemImage: "arrow.up.arrow.down")
                                }
                                .menuStyle(.button)
                                .buttonStyle(.borderless)
                                .fixedSize()
                            }
                        }
                        Spacer()
                    }
                    // 片段效果检查器（音视频片段：速度/音量/淡入淡出）
                    if clip.sourceURL != nil {
                        effectsRow(clip)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private func effectsRow(_ clip: TimelineCore.Clip) -> some View {
        HStack(spacing: 14) {
            // 速度（0.25×–4×；改完提交重定时）
            HStack(spacing: 5) {
                Text(String(localized: "Speed"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button(String(format: "%.2g×", speed)) {
                            store.setSpeed(of: clip.id, speed)
                        }
                    }
                } label: {
                    Text(String(format: "%.2g×", clip.speed))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            // 音量
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { clip.volume },
                    set: { store.setAudioEffects(of: clip.id, volume: $0) }), in: 0...2)
                    .frame(width: 80)
                Text("\(Int((clip.volume * 100).rounded()))%")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34)
            }
            // 淡入 / 淡出
            HStack(spacing: 5) {
                Text(String(localized: "Fade In"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { clip.fadeIn },
                    set: { store.setAudioEffects(of: clip.id, fadeIn: $0) }), in: 0...5)
                    .frame(width: 60)
                Text(String(localized: "Fade Out"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { clip.fadeOut },
                    set: { store.setAudioEffects(of: clip.id, fadeOut: $0) }), in: 0...5)
                    .frame(width: 60)
            }
            Spacer()
        }
    }

    // MARK: - 导出行

    @ViewBuilder
    private var exportRow: some View {
        HStack(spacing: 10) {
            switch store.exportState {
            case .idle:
                Button {
                    store.export()
                } label: {
                    Label(String(localized: "Export Timeline"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.projectDuration <= 0)
            case .running(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 260)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(String(localized: "Cancel")) { store.cancelExport() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .done(let url):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(url.lastPathComponent) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.plain)
                .foregroundStyle(appAccent)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    // MARK: - 面板

    private func addMedia() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        store.addSourceFiles(panel.urls)
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(store.project.title).dtl"
        if let type = UTType(filenameExtension: "dtl") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.saveProject(to: url)
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "dtl") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.loadProject(from: url)
    }
}

// MARK: - 预览（合成播放 + 文字轨叠加 + 走带控制）

private struct EditorPreview: View {
    @ObservedObject var store: VideoEditorStore
    let accent: Color

    var body: some View {
        ZStack {
            Color.black
            PlayerSurfaceOnly(player: store.player)
            if let overlay = currentText {
                Text(overlay)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 18)
                    .allowsHitTesting(false)
            }
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        store.togglePlay()
                    } label: {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    Text("\(MediaEditCore.formatClock(store.playhead)) / \(MediaEditCore.formatClock(store.projectDuration))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    /// 文字轨当前台词（与导出烧录同一规则：片段区间内显示）。
    private var currentText: String? {
        for track in store.project.tracks where track.kind == .text {
            if let clip = track.clips.first(where: {
                store.playhead >= $0.start && store.playhead < $0.end
            }) {
                return clip.text
            }
        }
        return nil
    }
}

/// 纯渲染命中层：AVPlayerLayer。
private struct PlayerSurfaceOnly: NSViewRepresentable {
    let player: AVPlayer

    final class SurfaceView: NSView {
        var player: AVPlayer? {
            didSet { (layer as? AVPlayerLayer)?.player = player }
        }

        override var acceptsFirstResponder: Bool { true }
        override func makeBackingLayer() -> CALayer {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspect
            return layer
        }
    }

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.player = player
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.player = player
    }
}

// MARK: - 时间线

private struct EditorTimeline: View {
    @ObservedObject var store: VideoEditorStore
    let accent: Color

    var body: some View {
        ScrollView([.horizontal]) {
            ZStack(alignment: .topLeading) {
                ruler
                VStack(alignment: .leading, spacing: MultiTrackEditorView.laneGap) {
                    ForEach(store.project.tracks) { track in
                        lane(for: track)
                    }
                }
                .padding(.top, MultiTrackEditorView.rulerHeight)
                playhead
            }
            .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private var contentWidth: CGFloat {
        max(600, CGFloat(store.projectDuration + 8) * store.pixelsPerSecond)
    }

    private var totalWidth: CGFloat { contentWidth }
    private var totalHeight: CGFloat {
        let lanes = store.project.tracks.reduce(CGFloat(0)) { $0 + (MultiTrackEditorView.laneHeights[$1.kind] ?? 40) }
        return MultiTrackEditorView.rulerHeight + CGFloat(store.project.tracks.count) * MultiTrackEditorView.laneGap + lanes
    }

    // MARK: 标尺

    private var ruler: some View {
        Canvas { context, size in
            let pps = store.pixelsPerSecond
            let majorInterval: Double = pps > 90 ? 1 : (pps > 36 ? 5 : 10)
            var second = 0.0
            while second * pps < size.width {
                let x = second * pps
                let isMajor = second.truncatingRemainder(dividingBy: majorInterval) == 0
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: x, y: isMajor ? 6 : 14))
                        p.addLine(to: CGPoint(x: x, y: MultiTrackEditorView.rulerHeight))
                    },
                    with: .color(.secondary.opacity(isMajor ? 0.5 : 0.25)), lineWidth: 0.5)
                if isMajor, second.truncatingRemainder(dividingBy: majorInterval * 2) == 0 {
                    context.draw(Text(MediaEditCore.formatClock(second))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary),
                        at: CGPoint(x: x + 3, y: 8))
                }
                second += 1
            }
        }
        .frame(width: contentWidth, height: MultiTrackEditorView.rulerHeight)
        .contentShape(Rectangle())
        .gesture(scrubGesture(height: MultiTrackEditorView.rulerHeight))
    }

    // MARK: 轨道

    private func lane(for track: TimelineCore.Track) -> some View {
        let laneHeight = MultiTrackEditorView.laneHeights[track.kind] ?? 40
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(track.kind == .video ? Color.secondary.opacity(0.07) : Color.secondary.opacity(0.045))
            Text(track.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.top, 3)
                .allowsHitTesting(false)
            ForEach(track.clips) { clip in
                TimelineClipView(
                    store: store, track: track, clip: clip,
                    accent: accent, laneHeight: laneHeight - 6)
                    .padding(.top, 3)
                    .padding(.leading, 3)
            }
        }
        .frame(width: contentWidth, height: laneHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(scrubGesture(height: laneHeight))
    }

    private func scrubGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = value.location.x / store.pixelsPerSecond
                store.setPlayhead(time, seekPlayer: true)
            }
    }

    // MARK: 播放头

    private var playhead: some View {
        Rectangle()
            .fill(accent)
            .frame(width: 1.5, height: totalHeight)
            .offset(x: store.playhead * store.pixelsPerSecond)
            .allowsHitTesting(false)
    }
}

// MARK: - 片段视图（拖移 + 两缘裁边）

private struct TimelineClipView: View {
    @ObservedObject var store: VideoEditorStore
    let track: TimelineCore.Track
    let clip: TimelineCore.Clip
    let accent: Color
    let laneHeight: CGFloat

    @State private var dragOffset: Double = 0
    @State private var trimDelta: Double = 0
    /// 正在拖的裁边（-1 左缘 / 1 右缘 / 0 无）——决定预览从哪端伸缩。
    @State private var trimmingSide: CGFloat = 0

    private var isSelected: Bool { store.selectedClipID == clip.id }

    private var fillColor: Color {
        switch track.kind {
        case .video: return accent.opacity(isSelected ? 0.5 : 0.32)
        case .audio: return .green.opacity(isSelected ? 0.45 : 0.28)
        case .text: return .yellow.opacity(isSelected ? 0.5 : 0.3)
        }
    }

    var body: some View {
        let pps = store.pixelsPerSecond
        let previewStart = trimmingSide < 0 ? clip.start + trimDelta : clip.start
        let previewDuration = trimmingSide < 0
            ? clip.duration - trimDelta
            : clip.duration + trimDelta
        let x = (previewStart + dragOffset) * pps
        let width = max(18, previewDuration * pps)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 1.5))
            HStack(spacing: 4) {
                Image(systemName: track.kind == .video ? "film"
                        : track.kind == .audio ? "waveform" : "textformat")
                    .font(.system(size: 8.5))
                Text(track.kind == .text ? (clip.text ?? "") : clip.label)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if clip.speed != 1 {
                    Text(String(format: "%.2g×", clip.speed))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(Color.white.opacity(0.35)))
                }
                if clip.volume == 0 {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 8))
                }
                if clip.clampedFadeIn > 0 || clip.clampedFadeOut > 0 {
                    Image(systemName: "chart.line.downtrend.xyaxis")
                        .font(.system(size: 8))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
            // 左右裁边把手
            HStack {
                trimHandle(direction: -1)
                Spacer()
                trimHandle(direction: 1)
            }
            .allowsHitTesting(true)
        }
        .frame(width: width, height: laneHeight)
        .offset(x: x)
        .contentShape(Rectangle().inset(by: 1))
        .onTapGesture { store.selectedClipID = clip.id }
        .gesture(moveGesture)
    }

    private func trimHandle(direction: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(0.75))
            .frame(width: 6, height: laneHeight - 10)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        trimmingSide = direction
                        trimDelta = value.translation.width / store.pixelsPerSecond * direction
                    }
                    .onEnded { _ in
                        let delta = trimDelta
                        trimDelta = 0
                        trimmingSide = 0
                        commitTrim(direction: direction, delta: delta)
                    })
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragOffset = value.translation.width / store.pixelsPerSecond
            }
            .onEnded { _ in
                let delta = dragOffset
                dragOffset = 0
                let newStart = max(0, clip.start + delta)
                if delta != 0 {
                    // 不合法（重叠/越界）就弹回原位——commit(nil) 无副作用。
                    store.commit(TimelineCore.moveClip(store.project, clipID: clip.id,
                                                       toTrack: track.id, start: newStart))
                }
                store.selectedClipID = clip.id
            }
    }

    private func commitTrim(direction: CGFloat, delta: Double) {
        if direction < 0 {
            store.commit(TimelineCore.trimClip(store.project, clipID: clip.id,
                                               newStart: clip.start + delta))
        } else {
            store.commit(TimelineCore.trimClip(store.project, clipID: clip.id,
                                               newDuration: clip.duration + delta))
        }
    }
}
