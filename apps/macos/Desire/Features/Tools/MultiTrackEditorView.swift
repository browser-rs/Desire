import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 多轨时间线编辑器（v0.8.27 剪辑批，剪映式 v1）：视频轨 + 多音频轨 + 文字轨，
/// 片段拖移/裁边/播放头分割/删除，合成实时预览，文字烧录导出，工程存开。
/// 编辑操作全走 TimelineCore（重叠校验失败即弹回原位）。
struct MultiTrackEditorView: View {
    @Environment(\.appAccent) private var appAccent: Color
    @StateObject private var store = VideoEditorStore()
    /// 源监视器正在查看的素材（nil = 关闭）。
    @State private var monitoring: VideoEditorStore.SourceMedia?
    @State private var showHistory = false

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
            sourcePool
            EditorTimeline(store: store, accent: appAccent)
                .frame(height: timelineHeight)
            if store.selectedClip != nil {
                inspectorRow
            }
            exportRow
        }
        .sheet(item: $monitoring) { _ in
            sourceMonitor
        }
    }

    private var presetSummary: String {
        let height = store.exportTargetHeight.map { "\(Int($0))p" }
            ?? String(localized: "Source Resolution")
        return store.exportAudioOnly ? String(localized: "Audio Only (m4a)") : height
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
            .disabled(store.selectedClip == nil && store.multiSelection.isEmpty)
            if store.multiSelection.count > 1 {
                Button {
                    store.toggleMuteSelection()
                } label: {
                    Label(String(localized: "Toggle Mute"), systemImage: "speaker.slash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("\(store.multiSelection.count) selected")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button {
                store.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.canUndo)
            .help(String(localized: "Undo"))
            Button {
                showHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.historyEntries.count < 2)
            .help(String(localized: "History"))
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                historyPanel
            }
            Button {
                store.splitAllTracks()
            } label: {
                Image(systemName: "square.split.2x1")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.playheadOverlapsClip)
            .help(String(localized: "Split All Tracks at Playhead"))
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

    /// 撤销历史面板（对齐图片编辑器）：栈底在前，点任意步跳回。
    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("History")
                .font(.system(size: 11, weight: .semibold))
            ScrollView {
                VStack(spacing: 2) {
                    let entries = store.historyEntries
                    ForEach(Array(entries.enumerated().reversed()), id: \.offset) { index, entry in
                        Button {
                            store.jumpToHistory(index)
                            showHistory = false
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(index)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 18)
                                Text(entry.isCurrent
                                     ? String(localized: "Current")
                                     : String(localized: "Step \(index)"))
                                    .font(.system(size: 10.5))
                                Spacer()
                                if entry.isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8))
                                        .foregroundStyle(appAccent)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(entry.isCurrent ? appAccent.opacity(0.14) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
            }
            .frame(width: 180, height: 180)
        }
        .padding(10)
    }

    /// 素材池（v0.8.28 批次二）：点名字开源监视器，点 + 直接插入时间线。
    @ViewBuilder
    private var sourcePool: some View {
        if !store.sources.isEmpty {
            ScrollView([.horizontal]) {
                HStack(spacing: 6) {
                    ForEach(store.sources) { source in
                        HStack(spacing: 5) {
                            Button {
                                monitoring = source
                            } label: {
                                Label(source.name, systemImage: source.hasVideo ? "film" : "waveform")
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .help(String(localized: "Open in Source Monitor"))
                            Button {
                                store.insertSource(source)
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(appAccent)
                            .help(String(localized: "Insert at Playhead"))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// 源监视器（剪映式）：预览 + 入出点修剪 + 插入播放头。
    private var sourceMonitor: some View {
        SourceMonitorSheet(source: monitoring!, store: store, onClose: { monitoring = nil })
            .padding(24)
            .frame(minWidth: 640)
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
                        effectsRow(clip, track: track)
                        envelopeRow(clip)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    /// 音量包络编辑器（v0.8.29）：以播放头落点加点、逐点音量滑杆、
    /// 清空回退简单淡变。
    private func envelopeRow(_ clip: TimelineCore.Clip) -> some View {
        HStack(spacing: 10) {
            Button {
                store.addEnvelopePoint(on: clip.id)
            } label: {
                Label(String(localized: "Add Point at Playhead"), systemImage: "plus.circle")
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(!(store.playhead > clip.start && store.playhead < clip.end))
            if !clip.volumeEnvelope.isEmpty {
                ForEach(Array(clip.volumeEnvelope.enumerated()), id: \.offset) { index, point in
                    HStack(spacing: 3) {
                        Text(String(format: "%.0f%%", point.offset * 100))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { point.volume },
                            set: { store.updateEnvelopePoint(on: clip.id, index: index, volume: $0) }),
                            in: 0...2)
                            .frame(width: 56)
                        Button {
                            store.removeEnvelopePoint(on: clip.id, index: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button(String(localized: "Clear Envelope")) {
                    store.clearEnvelope(on: clip.id)
                }
                .font(.system(size: 10))
                .buttonStyle(.borderless)
            }
            Spacer()
        }
    }

    private func effectsRow(_ clip: TimelineCore.Clip, track: TimelineCore.Track) -> some View {
        HStack(spacing: 14) {
            // 旋转（视频片段）
            if track.kind == .video {
                HStack(spacing: 3) {
                    Button {
                        store.rotateSelected(-1)
                    } label: {
                        Image(systemName: "rotate.left")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(String(localized: "Rotate Left"))
                    Button {
                        store.rotateSelected(1)
                    } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(String(localized: "Rotate Right"))
                    if clip.quarterTurns != 0 {
                        Text("\(clip.quarterTurns * 90)°")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // 转场（与后邻片段之间的交叉溶解）
            if track.kind == .video, store.hasSuccessor(of: clip.id) {
                Button {
                    store.toggleCrossDissolve(after: clip.id)
                } label: {
                    Label(TimelineCore.crossDissolve(after: clip.id, in: store.project) > 0
                          ? String(localized: "Remove Transition")
                          : String(localized: "Cross Dissolve"),
                          systemImage: "rectangle.leftthird.inset.filled")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
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
                Menu {
                    Button(String(localized: "Source Resolution")) {
                        store.exportTargetHeight = nil
                    }
                    Button("1080p") { store.exportTargetHeight = 1080 }
                    Button("720p") { store.exportTargetHeight = 720 }
                    Divider()
                    Button(store.exportAudioOnly
                           ? String(localized: "Video + Audio")
                           : String(localized: "Audio Only (m4a)")) {
                        store.exportAudioOnly.toggle()
                    }
                } label: {
                    Label(presetSummary, systemImage: "slider.horizontal.3")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help(String(localized: "Export Preset"))
                Button {
                    store.export()
                } label: {
                    Label(String(localized: "Export Timeline"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.projectDuration <= 0
                          || (store.exportAudioOnly
                              && !store.project.tracks.contains { $0.kind == .video && !$0.clips.isEmpty }
                              && false))
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
        .padding(.vertical, 2)
        .background {
            if !store.exportHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    ForEach(Array(store.exportHistory.prefix(3).enumerated()),
                            id: \.offset) { _, url in
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label(url.lastPathComponent, systemImage: "film")
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(appAccent.opacity(0.85))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
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
        .focusable()
        .onKeyPress(keys: [.delete]) { _ in
            if store.multiSelection.isEmpty && store.selectedClipID != nil {
                store.deleteSelected()
            } else {
                store.deleteSelectedClips()
            }
            return .handled
        }
        .onKeyPress("s") {
            store.splitAtPlayhead()
            return .handled
        }
        .onKeyPress("a") {
            if NSEvent.modifierFlags.contains(.command) {
                store.multiSelection = Set(store.project.tracks.flatMap { $0.clips.map { $0.id } })
                return .handled
            }
            return .ignored
        }
        .onKeyPress("z") {
            if NSEvent.modifierFlags.contains(.command) {
                store.undo()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: [.leftArrow]) { _ in
            store.setPlayhead(store.playhead - (store.pixelsPerSecond > 90 ? 1 : 5))
            return .handled
        }
        .onKeyPress(keys: [.rightArrow]) { _ in
            store.setPlayhead(store.playhead + (store.pixelsPerSecond > 90 ? 1 : 5))
            return .handled
        }
        .onKeyPress(keys: [.home]) { _ in
            store.setPlayhead(0)
            return .handled
        }
        .onKeyPress(keys: [.end]) { _ in
            store.setPlayhead(store.projectDuration)
            return .handled
        }
        .onKeyPress("=") {
            store.pixelsPerSecond = min(200, store.pixelsPerSecond * 1.25)
            return .handled
        }
        .onKeyPress("-") {
            store.pixelsPerSecond = max(12, store.pixelsPerSecond / 1.25)
            return .handled
        }
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
            HStack(spacing: 4) {
                Text(track.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(track.muted ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                if track.kind == .audio {
                    Button {
                        store.toggleTrackMute(track.id)
                    } label: {
                        Image(systemName: track.muted ? "speaker.slash" : "speaker.wave.1")
                            .font(.system(size: 7.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(track.muted ? .orange : .secondary)
                    .help(String(localized: "Mute Track"))
                }
                if track.kind != .video {
                    Button {
                        store.moveTrack(track.id, up: true)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 7))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Move Track Up"))
                    Button {
                        store.moveTrack(track.id, up: false)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 7))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Move Track Down"))
                    Button {
                        store.commit(TimelineCore.removeTrack(store.project, trackID: track.id))
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Delete"))
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 3)
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
    /// 音频波形（整源 400 桶 + 源时长；后台采样，绘图时按片段源区间切片）。
    @State private var fullWaveform: [WaveformCore.Column]?
    @State private var sourceDuration: Double = 0

    private var isSelected: Bool {
        store.selectedClipID == clip.id || store.multiSelection.contains(clip.id)
    }

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
            // 音频波形（v0.8.30）：镜像振幅条，切源区间
            if track.kind == .audio, clip.sourceURL != nil,
               let fullWaveform, sourceDuration > 0 {
                WaveformOverlay(
                    columns: WaveformCore.slice(
                        fullWaveform: fullWaveform, sourceDuration: sourceDuration,
                        sourceStart: clip.sourceStart,
                        sourceEnd: clip.sourceEnd, targetColumns: 160))
                    .frame(height: laneHeight - 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, 14)
                    .allowsHitTesting(false)
            }
            // 包络折线（底部 1/3）：点间连线直读形状
            if !clip.volumeEnvelope.isEmpty {
                EnvelopeOverlay(points: clip.volumeEnvelope)
                    .frame(height: laneHeight / 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: laneHeight)
        .offset(x: x)
        .contentShape(Rectangle().inset(by: 1))
        .task(id: clip.id) {
            guard track.kind == .audio, let url = clip.sourceURL else { return }
            let wave = await WaveformCache.shared.waveform(for: url)
            let duration = await MediaEditProbe.duration(url) ?? 0
            fullWaveform = wave
            sourceDuration = duration
        }
        .onTapGesture { tapSelect(with: NSEvent.modifierFlags) }
        .contextMenu {
            Button(String(localized: "Split")) { store.splitAtPlayhead() }
            Button(String(localized: "Duplicate")) { store.duplicateClip(clip.id) }
            if track.kind == .video, clip.sourceURL != nil {
                Button(String(localized: "Detach Audio")) { store.detachAudio(of: clip.id) }
            }
            Button(track.kind == .video
                   ? String(localized: "Cross Dissolve")
                   : String(localized: "Toggle Mute")) {
                if track.kind == .video {
                    store.toggleCrossDissolve(after: clip.id)
                } else {
                    store.setAudioEffects(of: clip.id, volume: clip.volume == 0 ? 1 : 0)
                }
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                store.deleteClips([clip.id])
            }
        }
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
            .onEnded { value in
                let delta = dragOffset
                dragOffset = 0
                if delta != 0 {
                    let rawStart = max(0, clip.start + delta)
                    // 贴齐（⌘ 按住临时禁用；DragGesture.Value 无修饰键，
                    // 读 NSEvent 的当前修饰键——松手瞬间仍按着即生效）；不合法弹回原位。
                    let snappedStart = store.snappedTime(
                        rawStart, movingClipID: clip.id,
                        commandDown: NSEvent.modifierFlags.contains(.command))
                    store.commit(TimelineCore.moveClip(store.project, clipID: clip.id,
                                                       toTrack: track.id, start: snappedStart))
                }
                tapSelect(with: NSEvent.modifierFlags)
            }
    }

    /// 点击选择语义：plain=单选；⌘=翻转；⇧=区间扩展。
    private func tapSelect(with flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift) {
            store.select(clipID: clip.id, range: true)
        } else if flags.contains(.command) {
            store.select(clipID: clip.id, additive: true)
        } else {
            store.select(clipID: clip.id)
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

// MARK: - 源监视器（v0.8.28 批次二）

/// 素材预览 + 入出点修剪：插入的片段带 sourceStart（源内入点），
/// 时间线时长 = 出 - 入。与时间线插入口径一致（播放头，被占顺延）。
private struct SourceMonitorSheet: View {
    @Environment(\.appAccent) private var appAccent: Color
    let source: VideoEditorStore.SourceMedia
    @ObservedObject var store: VideoEditorStore
    let onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var inText = "0:00"
    @State private var outText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(source.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(MediaEditCore.formatClock(source.duration))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            MediaPlayerPreview(url: source.url, player: $player)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            SourceWaveformStrip(url: source.url, accent: appAccent)
                .frame(height: 34)
            HStack(spacing: 14) {
                MediaTimeField(label: String(localized: "In Point"), text: $inText)
                MediaTimeField(label: String(localized: "Out Point"), text: $outText)
                Button(String(localized: "Mark In")) {
                    inText = MediaEditCore.formatTime(player?.currentTime().seconds ?? 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(String(localized: "Mark Out")) {
                    outText = MediaEditCore.formatTime(player?.currentTime().seconds ?? 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Button(String(localized: "Insert at Playhead")) { insert() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedDuration <= 0)
            }
        }
        .onAppear {
            outText = MediaEditCore.formatTime(source.duration)
        }
    }

    private var trimmedDuration: Double {
        guard let plan = MediaEditCore.trimPlan(startRaw: inText, endRaw: outText,
                                                duration: source.duration) else { return 0 }
        return plan.duration
    }

    private func insert() {
        guard let plan = MediaEditCore.trimPlan(startRaw: inText, endRaw: outText,
                                                duration: source.duration) else { return }
        store.insertTrimmed(source: source, sourceStart: plan.start, duration: plan.duration)
        onClose()
    }
}


/// 音量包络折线（片段块底部 1/3）：独立子视图——内联在 TimelineClipView
/// body 里会触发 type-check 超时（本轮实测）。
private struct EnvelopeOverlay: View {
    let points: [TimelineCore.VolumePoint]

    var body: some View {
        Canvas { context, size in
            let height: CGFloat = size.height * 0.32
            var path = Path()
            for (index, point) in points.enumerated() {
                let x: CGFloat = CGFloat(point.offset) * size.width
                let y: CGFloat = height * (1.0 - min(CGFloat(1.0), CGFloat(point.volume) / 2.0))
                let location = CGPoint(x: x, y: y)
                if index == 0 {
                    path.move(to: location)
                } else {
                    path.addLine(to: location)
                }
            }
            context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.2)
            for point in points {
                let x: CGFloat = CGFloat(point.offset) * size.width
                let y: CGFloat = height * (1.0 - min(CGFloat(1.0), CGFloat(point.volume) / 2.0))
                let rect = CGRect(x: x - 2, y: y - 2, width: 4, height: 4)
                context.fill(Path(rect), with: .color(.white))
            }
        }
    }
}


/// 音频波形（v0.8.30 批次一）：镜像振幅条（白 60% 叠在音轨绿色上）。
/// 独立子视图——Canvas 内联进复杂 body 会 type-check 超时（同 EnvelopeOverlay）。
private struct WaveformOverlay: View {
    let columns: [WaveformCore.Column]

    var body: some View {
        Canvas { context, size in
            guard !columns.isEmpty, size.width > 0 else { return }
            let mid = size.height / 2
            let columnWidth = size.width / CGFloat(columns.count)
            let style = StrokeStyle(lineWidth: max(0.8, columnWidth * 0.7), lineCap: .round)
            var path = Path()
            for (index, column) in columns.enumerated() {
                let x = (CGFloat(index) + 0.5) * columnWidth
                let top = mid - CGFloat(column.max) * (size.height / 2 - 1)
                let bottom = mid - CGFloat(column.min) * (size.height / 2 - 1)
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
            }
            context.stroke(path, with: .color(.white.opacity(0.65)), style: style)
        }
    }
}


/// 源监视器波形带（v0.8.30 追加批）：整源 400 桶直画，裁剪时对齐入出点。
private struct SourceWaveformStrip: View {
    let url: URL
    let accent: Color
    @State private var waveform: [WaveformCore.Column]?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.08))
            if let waveform {
                GeometryReader { geo in
                    Canvas { context, size in
                        let mid = size.height / 2
                        let columnWidth = size.width / CGFloat(waveform.count)
                        var path = Path()
                        for (index, column) in waveform.enumerated() {
                            let x = (CGFloat(index) + 0.5) * columnWidth
                            let top = mid - CGFloat(column.max) * (size.height / 2 - 2)
                            let bottom = mid - CGFloat(column.min) * (size.height / 2 - 2)
                            path.move(to: CGPoint(x: x, y: top))
                            path.addLine(to: CGPoint(x: x, y: max(top + 0.5, bottom)))
                        }
                        context.stroke(path, with: .color(accent.opacity(0.75)),
                                       lineWidth: max(0.7, columnWidth * 0.6))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .task { waveform = await WaveformCache.shared.waveform(for: url) }
    }
}
