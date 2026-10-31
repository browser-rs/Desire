import AVFoundation
import AppKit
import Combine
import Foundation
import QuartzCore

/// 多轨视频剪辑执行引擎（v0.8.27 剪辑批）：素材池 / 播放头 / **合成重构预览**
/// （AVMutableComposition 按工程实时拼装）/ 导出（HighestQuality 重编码 +
/// 文字轨经 CoreAnimationTool 烧录；无视频片段则出 m4a）。
/// 纯编辑操作在 TimelineCore（harness 覆盖）；本文件只管 AVFoundation 侧。
@MainActor
final class VideoEditorStore: ObservableObject {

    struct SourceMedia: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let duration: Double
        let hasVideo: Bool
        var name: String { url.lastPathComponent }
    }

    enum ExportState: Equatable {
        case idle
        case running(Double)
        case done(URL)
        case failed(String)
    }

    @Published var project = TimelineCore.Project()
    @Published var playhead: Double = 0
    @Published var selectedClipID: UUID?
    /// 多选（⌘ 点选累积；⇧ 区间；批量操作作用于全集）。
    @Published var multiSelection: Set<UUID> = []
    /// 贴齐开关（⌘ 按住临时反转；默认开）。
    @Published var snappingEnabled = true
    /// 导出预设：目标高度（nil=源分辨率）与仅音频。
    @Published var exportTargetHeight: Double?
    @Published var exportAudioOnly = false
    @Published var pixelsPerSecond: Double = 60
    @Published private(set) var isPlaying = false
    @Published private(set) var sources: [SourceMedia] = []
    @Published private(set) var exportState: ExportState = .idle
    @Published private(set) var canUndo = false

    let player = AVPlayer()

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var rebuildTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    /// 播放头由观察者推进时不再回写 seek（防回环）。
    private var isScrubbingProgrammatically = false
    /// 撤销快照栈（cap 50；redo 不做——剪辑场景撤销到头重做价值有限）。
    private var undoStack: [TimelineCore.Project] = []

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, !self.isScrubbingProgrammatically else { return }
                    self.playhead = max(0, time.seconds)
                }
            }
        player.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                self?.isPlaying = status != .paused
            }
            .store(in: &cancellables)
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    var projectDuration: Double { TimelineCore.projectDuration(project) }

    /// 当前生效的选择集（多选非空用多选，否则单选）。
    var effectiveSelection: [UUID] {
        multiSelection.isEmpty
            ? (selectedClipID.map { [$0] } ?? [])
            : Array(multiSelection)
    }

    /// 时间线点击选择：plain=单选清多选；⌘=翻转该项；⇧=区间扩展。
    func select(clipID: UUID, additive: Bool = false, range: Bool = false) {
        if additive {
            if multiSelection.contains(clipID) {
                multiSelection.remove(clipID)
            } else {
                multiSelection.insert(clipID)
            }
            selectedClipID = clipID
        } else if range, let anchor = selectedClipID {
            multiSelection = Set(TimelineCore.clipIDs(in: project,
                                                      between: anchor, and: clipID))
        } else {
            multiSelection = []
            selectedClipID = clipID
        }
    }

    func clearSelection() {
        selectedClipID = nil
        multiSelection = []
    }

    /// 拖移落点的贴齐换算（⌘ 按住 = 临时关闭；视图传 modifierFlags）。
    func snappedTime(_ time: Double, movingClipID: UUID?, commandDown: Bool) -> Double {
        let enabled = commandDown ? !snappingEnabled : snappingEnabled
        guard enabled else { return max(0, time) }
        return TimelineCore.snapped(time: max(0, time), movingClipID: movingClipID,
                                    project: project, playhead: playhead,
                                    tolerance: 8 / pixelsPerSecond)
    }

    /// 播放头是否压在某个片段上（决定"分割"是否可用）。
    var playheadOverlapsClip: Bool {
        project.tracks.contains { track in
            track.clips.contains { playhead > $0.start + 0.1 && playhead < $0.end - 0.1 }
        }
    }

    /// 视频轨上某片段是否存在后邻（转场按钮的可用性）。
    func hasSuccessor(of clipID: UUID) -> Bool {
        guard let (track, clip) = TimelineCore.clip(project, withID: clipID),
              track.kind == .video else { return false }
        return track.clips.contains { $0.start > clip.start + 1e-6 }
    }

    var selectedClip: (TimelineCore.Track, TimelineCore.Clip)? {
        guard let selectedClipID else { return nil }
        return TimelineCore.clip(project, withID: selectedClipID)
    }

    // MARK: - 编辑提交（失败 = 保持原状 + 合成不重构）

    func commit(_ newProject: TimelineCore.Project?) {
        guard let newProject else { return }
        pushUndo()
        project = newProject
        selectedClipID = selectedClipID.flatMap { id in
            TimelineCore.clip(project, withID: id) != nil ? id : nil
        }
        rebuildPreview()
    }

    private func pushUndo() {
        guard TimelineCore.shouldPushUndo(undoStack, project) else { return }
        undoStack.append(project)
        if undoStack.count > 50 { undoStack.removeFirst() }
        canUndo = true
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        project = previous
        selectedClipID = selectedClipID.flatMap { id in
            TimelineCore.clip(project, withID: id) != nil ? id : nil
        }
        canUndo = !undoStack.isEmpty
        rebuildPreview()
    }

    // MARK: - 片段效果

    func setSpeed(of clipID: UUID, _ speed: Double) {
        commit(TimelineCore.setSpeed(project, clipID: clipID, speed: speed))
    }

    func setAudioEffects(of clipID: UUID, volume: Double? = nil,
                         fadeIn: Double? = nil, fadeOut: Double? = nil) {
        commit(TimelineCore.setAudioEffects(project, clipID: clipID,
                                            volume: volume, fadeIn: fadeIn, fadeOut: fadeOut))
    }

    /// 转场：选中片段与它的后邻之间设置/移除交叉溶解。
    func toggleCrossDissolve(after clipID: UUID) {
        let existing = TimelineCore.crossDissolve(after: clipID, in: project)
        let right = project.tracks
            .first { $0.kind == .video }?.clips
            .filter { $0.start > (TimelineCore.clip(project, withID: clipID)?.1.start ?? 0) + 1e-6 }
            .min { $0.start < $1.start }?.id
        guard let right else { return }
        commit(TimelineCore.setCrossDissolve(project, leftID: clipID, rightID: right,
                                             overlap: existing > 0 ? 0 : 0.8))
    }

    /// 音量包络：以播放头在片段内的进度落点新增/更新；删点按 offset 最近。
    func addEnvelopePoint(on clipID: UUID) {
        guard let (_, clip) = TimelineCore.clip(project, withID: clipID),
              playhead > clip.start, playhead < clip.end else { return }
        let offset = (playhead - clip.start) / clip.duration
        var points = TimelineCore.clip(project, withID: clipID)?.1.volumeEnvelope ?? []
        points.append(TimelineCore.VolumePoint(offset: offset, volume: 1))
        commit(TimelineCore.setVolumeEnvelope(project, clipID: clipID, points: points))
    }

    func updateEnvelopePoint(on clipID: UUID, index: Int, volume: Double) {
        guard let (_, clip) = TimelineCore.clip(project, withID: clipID),
              clip.volumeEnvelope.indices.contains(index) else { return }
        var points = clip.volumeEnvelope
        points[index].volume = volume
        commit(TimelineCore.setVolumeEnvelope(project, clipID: clipID, points: points))
    }

    func removeEnvelopePoint(on clipID: UUID, index: Int) {
        guard let (_, clip) = TimelineCore.clip(project, withID: clipID),
              clip.volumeEnvelope.indices.contains(index) else { return }
        var points = clip.volumeEnvelope
        points.remove(at: index)
        commit(TimelineCore.setVolumeEnvelope(project, clipID: clipID, points: points))
    }

    func clearEnvelope(on clipID: UUID) {
        commit(TimelineCore.setVolumeEnvelope(project, clipID: clipID, points: []))
    }

    /// 轨道相邻交换。
    func moveTrack(_ trackID: UUID, up: Bool) {
        commit(TimelineCore.moveTrack(project, trackID: trackID, up: up))
    }

    /// 历史面板：撤销栈快照（栈底在前，含当前工程）。
    var historyEntries: [(project: TimelineCore.Project, isCurrent: Bool)] {
        var entries = undoStack.map { (project: $0, isCurrent: false) }
        entries.append((project: project, isCurrent: true))
        return entries
    }

    /// 跳回历史第 index 步（0=栈底）：其后快照丢弃。
    func jumpToHistory(_ index: Int) {
        let entries = historyEntries
        guard entries.indices.contains(index), !entries[index].isCurrent else { return }
        project = entries[index].project
        undoStack.removeSubrange(index...)
        canUndo = !undoStack.isEmpty
        selectedClipID = nil
        multiSelection = []
        rebuildPreview()
    }

    /// 切换轨道静音（音频轨）。
    func toggleTrackMute(_ trackID: UUID) {
        commit(TimelineCore.toggleTrackMute(project, trackID: trackID))
    }

    /// 旋转选中片段（turns 步进）。
    func rotateSelected(_ turns: Int) {
        guard let selectedClipID else { return }
        commit(TimelineCore.rotate(project, clipID: selectedClipID, turns: turns))
    }

    /// 复制片段：贴到原片段尾部之后（同轨找空位），内容同参。
    func duplicateClip(_ clipID: UUID) {
        guard let (track, clip) = TimelineCore.clip(project, withID: clipID) else { return }
        var copy = clip
        copy.id = UUID()
        copy.start = TimelineCore.makeInsertStart(project: project, trackID: track.id,
                                                  at: clip.end, duration: clip.duration)
        commit(TimelineCore.upsertClip(project, trackID: track.id, clip: copy))
    }

    /// 分割全部轨道（播放头处）。
    func splitAllTracks() {
        pushUndo()
        project = TimelineCore.splitAllAtPlayhead(project, at: playhead)
        rebuildPreview()
    }

    /// 删除指定片段集合（右键单删与批量共用）。
    func deleteClips(_ ids: [UUID]) {
        commit(TimelineCore.deleteClips(project, ids: ids))
    }

    /// 批量删除选中（多选 id 集合）。
    func deleteSelectedClips() {
        let ids = effectiveSelection
        guard !ids.isEmpty else { return }
        commit(TimelineCore.deleteClips(project, ids: ids))
        clearSelection()
    }

    /// 批量静音/取消静音选中片段。
    func toggleMuteSelection() {
        let ids = effectiveSelection
        guard !ids.isEmpty else { return }
        pushUndo()
        var updated = project
        let idSet = Set(ids)
        // 取多数派的反义：多数有声则全部静音，反之恢复。
        let clips = project.tracks.flatMap { $0.clips }.filter { idSet.contains($0.id) }
        let mostlyMuted = clips.filter { $0.volume == 0 }.count * 2 >= clips.count
        for index in updated.tracks.indices {
            for clipIndex in updated.tracks[index].clips.indices
            where idSet.contains(updated.tracks[index].clips[clipIndex].id) {
                updated.tracks[index].clips[clipIndex].volume = mostlyMuted ? 1 : 0
            }
        }
        project = updated
        rebuildPreview()
    }

    func setPlayhead(_ seconds: Double, seekPlayer: Bool = true) {
        playhead = max(0, min(seconds, max(projectDuration, 0)))
        if seekPlayer {
            isScrubbingProgrammatically = true
            player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600)) { [weak self] _ in
                // 完成回调的队列不保证是主线程——跳一帧再放闸。
                DispatchQueue.main.async {
                    self?.isScrubbingProgrammatically = false
                }
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if playhead >= projectDuration - 0.05 { setPlayhead(0) }
            player.play()
        }
    }

    // MARK: - 素材池

    func addSourceFiles(_ urls: [URL]) {
        for url in urls where !sources.contains(where: { $0.url == url }) {
            Task { [weak self] in
                let duration = await MediaEditProbe.duration(url) ?? 0
                let hasVideo = ((try? await AVURLAsset(url: url)
                    .loadTracks(withMediaType: .video).count) ?? 0) > 0
                await MainActor.run { [weak self] in
                    guard let self, duration > 0 else { return }
                    self.sources.append(SourceMedia(url: url,
                                                    duration: duration, hasVideo: hasVideo))
                }
            }
        }
    }

    /// 把素材插到对应轨道（视频→主视频轨，音频→第一条音频轨），起点=播放头
    /// （被占则顺延到空位）。
    func insertSource(_ source: SourceMedia) {
        let kind: TimelineCore.TrackKind = source.hasVideo ? .video : .audio
        guard let track = project.tracks.first(where: { $0.kind == kind }) else { return }
        let start = TimelineCore.makeInsertStart(project: project, trackID: track.id,
                                                 at: playhead, duration: source.duration)
        let clip = TimelineCore.Clip(start: start, duration: source.duration,
                                     sourceURL: source.url, label: source.name)
        commit(TimelineCore.upsertClip(project, trackID: track.id, clip: clip))
    }

    /// 源监视器的修剪插入：片段带源内入点，落在播放头（被占顺延）。
    func insertTrimmed(source: SourceMedia, sourceStart: Double, duration: Double) {
        let kind: TimelineCore.TrackKind = source.hasVideo ? .video : .audio
        guard let track = project.tracks.first(where: { $0.kind == kind }) else { return }
        let start = TimelineCore.makeInsertStart(project: project, trackID: track.id,
                                                 at: playhead, duration: duration)
        let clip = TimelineCore.Clip(start: start, duration: duration,
                                     sourceStart: sourceStart, sourceURL: source.url,
                                     label: source.name)
        commit(TimelineCore.upsertClip(project, trackID: track.id, clip: clip))
    }

    func addTextClip() {
        guard let track = project.tracks.first(where: { $0.kind == .text }) else { return }
        let start = TimelineCore.makeInsertStart(project: project, trackID: track.id,
                                                 at: playhead, duration: 3)
        let clip = TimelineCore.Clip(start: start, duration: 3, label: "文字",
                                     text: String(localized: "Enter text"))
        commit(TimelineCore.upsertClip(project, trackID: track.id, clip: clip))
        selectedClipID = clip.id
    }

    func splitAtPlayhead() {
        // 优先分割选中片段；没选中就找播放头压着的片段。
        let target = selectedClip.flatMap { track, clip in
            playhead > clip.start && playhead < clip.end ? clip.id : nil
        } ?? project.tracks.compactMap { track in
            track.clips.first { playhead > $0.start + 0.1 && playhead < $0.end - 0.1 }?.id
        }.first
        guard let target else { return }
        commit(TimelineCore.splitClip(project, clipID: target, at: playhead))
    }

    func deleteSelected() {
        guard let selectedClipID else { return }
        commit(TimelineCore.deleteClip(project, clipID: selectedClipID))
    }

    func moveSelected(toTrack trackID: UUID, start: Double) {
        guard let selectedClipID else { return }
        commit(TimelineCore.moveClip(project, clipID: selectedClipID,
                                     toTrack: trackID, start: start))
    }

    func trimSelected(newStart: Double? = nil, newDuration: Double? = nil) {
        guard let selectedClipID else { return }
        commit(TimelineCore.trimClip(project, clipID: selectedClipID,
                                     newStart: newStart, newDuration: newDuration))
    }

    func updateSelectedText(_ text: String) {
        guard let (track, clip) = selectedClip, clip.text != nil else { return }
        var updated = clip
        updated.text = text
        commit(TimelineCore.upsertClip(project, trackID: track.id, clip: updated))
    }

    // MARK: - 工程存开

    func saveProject(to url: URL) {
        if let data = try? JSONEncoder().encode(project) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadProject(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(TimelineCore.Project.self, from: data) else { return }
        player.pause()
        project = loaded
        selectedClipID = nil
        setPlayhead(0)
        rebuildPreview()
    }

    func newProject() {
        player.pause()
        project = TimelineCore.Project()
        sources = []
        selectedClipID = nil
        setPlayhead(0)
        rebuildPreview()
    }

    // MARK: - 合成预览

    func rebuildPreview() {
        rebuildTask?.cancel()
        let snapshot = project
        let atPlayhead = playhead
        rebuildTask = Task { [weak self] in
            let (composition, audioMix, videoConfig) = await Self.buildComposition(project: snapshot)
            guard let self, !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: composition)
            item.audioMix = audioMix
            if let videoConfig {
                let renderSize = await Self.compositionNaturalSize(composition)
                item.videoComposition = AVVideoComposition(configuration: videoConfig(renderSize))
            }
            self.player.replaceCurrentItem(with: item)
            await self.player.seek(to: CMTime(seconds: atPlayhead, preferredTimescale: 600))
        }
    }

    /// 工程的合成：视频轨/音频轨各建一条 composition track，片段按时间线落位
    /// （空隙天然留白）；速度 ≠1 的片段经 scaleTimeRange 重定时（源消耗 =
    /// 时长 × 速度）；音量/淡变经 AVMutableAudioMix 自动化（淡入淡出线性坡）。
    /// 返回 (合成, 音频混合, 视频配置构造器)，预览与导出共用同一份。
    private nonisolated static func buildComposition(project: TimelineCore.Project) async -> (AVMutableComposition, AVMutableAudioMix?, ((CGSize) -> AVVideoComposition.Configuration)?) {
        let composition = AVMutableComposition()
        var mixParameters: [AVAudioMixInputParameters] = []
        var videoClips: [(track: AVMutableCompositionTrack, clip: TimelineCore.Clip)] = []
        for track in project.tracks where !track.clips.isEmpty {
            let mediaType: AVMediaType = track.kind == .audio ? .audio : .video
            guard track.kind != .text,
                  let compositionTrack = composition.addMutableTrack(
                      withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var clipMix: AVMutableAudioMixInputParameters?
            if mediaType == .audio, !track.muted {
                clipMix = AVMutableAudioMixInputParameters(track: compositionTrack)
            }
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                guard let url = clip.sourceURL else { continue }
                let asset = AVURLAsset(url: url)
                if let source = try? await asset.loadTracks(withMediaType: mediaType).first {
                    let range = CMTimeRange(
                        start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                        duration: CMTime(seconds: clip.duration * clip.speed, preferredTimescale: 600))
                    let at = CMTime(seconds: clip.start, preferredTimescale: 600)
                    try? compositionTrack.insertTimeRange(range, of: source, at: at)
                    if clip.speed != 1 {
                        compositionTrack.scaleTimeRange(range, toDuration:
                            CMTime(seconds: clip.duration, preferredTimescale: 600))
                    }
                }
                if mediaType == .video {
                    videoClips.append((compositionTrack, clip))
                }
                // 音量自动化：包络（非空）与简单模式（基线+淡变）统一出自
                // TimelineCore.volumeRamps——预览与导出听到同一条包络。
                if let clipMix {
                    for ramp in TimelineCore.volumeRamps(for: clip) {
                        clipMix.setVolumeRamp(
                            fromStartVolume: Float(ramp.from), toEndVolume: Float(ramp.to),
                            timeRange: CMTimeRange(
                                start: CMTime(seconds: ramp.start, preferredTimescale: 600),
                                end: CMTime(seconds: ramp.end, preferredTimescale: 600)))
                    }
                }
            }
            if let clipMix { mixParameters.append(clipMix) }
        }
        guard !mixParameters.isEmpty else { return (composition, nil, nil) }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters
        let clipsForVideo = videoClips
        let configBuilder: ((CGSize) -> AVVideoComposition.Configuration) = { renderSize in
            Self.buildVideoConfiguration(clips: clipsForVideo, renderSize: renderSize)
        }
        return (composition, audioMix, configBuilder)
    }

    /// 视频配置：旋转（transform）+ 相邻交叠段的交叉溶解（转场）。
    private nonisolated static func buildVideoConfiguration(
        clips: [(track: AVMutableCompositionTrack, clip: TimelineCore.Clip)],
        renderSize: CGSize) -> AVVideoComposition.Configuration {
        var config = AVVideoComposition.Configuration()
        config.renderSize = renderSize
        config.frameDuration = CMTime(value: 1, timescale: 30)
        var instructions: [AVVideoCompositionInstruction] = []
        let sorted = clips.sorted { $0.clip.start < $1.clip.start }
        var index = 0
        while index < sorted.count {
            let (track, clip) = sorted[index]
            // 与下一段的交叠 = 交叉溶解：下一段 opacity 0→1 顶上来。
            let overlap = index + 1 < sorted.count
                ? max(0, clip.end - sorted[index + 1].clip.start) : 0
            // 前段指令覆盖 [start, end - overlap)（交叠期间让位）；
            // 后段指令覆盖 [start - overlap, end)，交叠头 opacity 0→1。
            let frontEnd = overlap > 0.05 ? clip.end - overlap : clip.end
            var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            layerConfig.setTransform(rotationTransform(quarterTurns: clip.quarterTurns,
                                                       renderSize: renderSize), at: .zero)
            let frontInstruction = AVVideoCompositionInstruction(configuration: .init(
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerConfig)],
                timeRange: CMTimeRange(
                    start: CMTime(seconds: clip.start, preferredTimescale: 600),
                    end: CMTime(seconds: frontEnd, preferredTimescale: 600))))
            instructions.append(frontInstruction)
            if overlap > 0.05, index + 1 < sorted.count {
                let next = sorted[index + 1]
                var nextConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: next.track)
                nextConfig.setTransform(rotationTransform(quarterTurns: next.clip.quarterTurns,
                                                          renderSize: renderSize), at: .zero)
                nextConfig.addOpacityRamp(.init(
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: next.clip.start, preferredTimescale: 600),
                        end: CMTime(seconds: next.clip.start + overlap, preferredTimescale: 600)),
                    start: 0, end: 1))
                let nextInstruction = AVVideoCompositionInstruction(configuration: .init(
                    layerInstructions: [AVVideoCompositionLayerInstruction(configuration: nextConfig)],
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: next.clip.start, preferredTimescale: 600),
                        end: CMTime(seconds: next.clip.end, preferredTimescale: 600))))
                instructions.append(nextInstruction)
                index += 2
                continue
            }
            index += 1
        }
        if !instructions.isEmpty {
            config.instructions = instructions
        }
        return config
    }

    /// 旋转 transform：画面绕中心顺时针转 quarterTurns×90°。
    private nonisolated static func rotationTransform(quarterTurns: Int, renderSize: CGSize) -> CGAffineTransform {
        guard quarterTurns % 4 != 0 else { return .identity }
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: renderSize.width / 2, y: renderSize.height / 2)
        transform = transform.rotated(by: -CGFloat(quarterTurns % 4) * .pi / 2)
        transform = transform.translatedBy(x: -renderSize.width / 2, y: -renderSize.height / 2)
        return transform
    }

    // MARK: - 导出

    func export() {
        guard !isExporting else { return }
        let snapshot = project
        let height = exportTargetHeight
        let audioOnly = exportAudioOnly
        exportState = .running(0)
        // 捕获强引用局部量（不是 var）——Sendable 闭包里捕获 var self 是 Swift 6 错误。
        let store = self
        exportTask = Task { [weak self] in
            do {
                let url = try await Self.export(project: snapshot, progress: { fraction in
                    Task { @MainActor in
                        store.exportState = .running(min(0.99, fraction))
                    }
                }, targetHeight: height, forceAudioOnly: audioOnly)
                await MainActor.run { self?.exportState = .done(url) }
            } catch is CancellationError {
                await MainActor.run { self?.exportState = .idle }
            } catch {
                await MainActor.run { self?.exportState = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    nonisolated static func export(project: TimelineCore.Project,
                                           progress: @escaping @Sendable (Double) -> Void,
                                           targetHeight: Double? = nil,
                                           forceAudioOnly: Bool = false) async throws -> URL {
        let (composition, audioMix, videoConfig) = await buildComposition(project: project)
        let naturalHasVideo = project.tracks.contains { $0.kind == .video && !$0.clips.isEmpty }
        let hasVideo = naturalHasVideo && !forceAudioOnly
        let destination = resolveDestination(title: project.title,
                                             ext: hasVideo ? "mp4" : "m4a")
        let session: AVAssetExportSession
        if hasVideo {
            guard let s = AVAssetExportSession(asset: composition,
                                               presetName: AVAssetExportPresetHighestQuality) else {
                throw MediaEditError.engineUnavailable
            }
            session = s
            // 渲染参数（macOS 26 起 AVMutableVideoComposition 已废弃，
            // 新 API = Configuration + 不可变 AVVideoComposition）——旋转/
            // 转场由 buildComposition 的构造器产出，这里只叠文字烧录。
            var config = videoConfig?(await compositionNaturalSize(composition))
                ?? AVVideoComposition.Configuration()
            if let targetHeight {
                let source = await compositionNaturalSize(composition)
                let ratio = source.height > 0 ? targetHeight / source.height : 1
                config.renderSize = CGSize(width: (source.width * ratio).rounded(),
                                           height: targetHeight)
            }
            let textClips = project.tracks
                .filter { $0.kind == .text }
                .flatMap { $0.clips }
                .sorted { $0.start < $1.start }
            if !textClips.isEmpty {
                let renderSize = config.renderSize
                config.animationTool = makeTextOverlayTool(
                    clips: textClips, totalDuration: max(TimelineCore.projectDuration(project), 0.1),
                    renderSize: renderSize)
            }
            session.videoComposition = AVVideoComposition(configuration: config)
        } else {
            guard let s = AVAssetExportSession(asset: composition,
                                               presetName: AVAssetExportPresetAppleM4A) else {
                throw MediaEditError.engineUnavailable
            }
            session = s
        }
        // 变速不变调（频谱算法，质量最高档）；音量/淡变自动化。
        session.audioTimePitchAlgorithm = .spectral
        session.audioMix = audioMix
        try? FileManager.default.removeItem(at: destination)
        let stream = session.states(updateInterval: 0.25)
        let watcher = Task {
            for try await state in stream {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: destination, as: hasVideo ? .mp4 : .m4a)
        return destination
    }

    /// 合成画面的自然尺寸（第一条视频轨的时间映射，缺省 1280×720）。
    private nonisolated static func compositionNaturalSize(_ composition: AVComposition) async -> CGSize {
        for track in composition.tracks where track.mediaType == .video {
            // naturalSize 走 KVC（AVCompositionTrackSegment 无 async sourceTrack 属性）。
            for segment in track.segments {
                if let size = segment.value(forKey: "naturalSize") as? CGSize,
                   size.width > 0, size.height > 0 {
                    return size
                }
            }
        }
        return CGSize(width: 1280, height: 720)
    }

    /// 文字轨烧录：每个文字片段一个 CATextLayer，透明度按 [start,end] 显隐。
    /// 位置与预览一致（底部居中），字号随渲染分辨率缩放。
    private nonisolated static func makeTextOverlayTool(clips: [TimelineCore.Clip],
                                                        totalDuration: Double,
                                                        renderSize: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)
        let overlay = CALayer()
        overlay.frame = parent.bounds
        overlay.masksToBounds = true
        parent.addSublayer(overlay)

        let fontSize = max(14, renderSize.height * 0.055)
        for clip in clips {
            let textLayer = CATextLayer()
            textLayer.string = NSAttributedString(string: clip.text ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: -3.0,
            ])
            textLayer.alignmentMode = .center
            textLayer.isWrapped = true
            let textHeight = fontSize * 1.6
            textLayer.frame = CGRect(x: renderSize.width * 0.08,
                                     y: renderSize.height * 0.08,
                                     width: renderSize.width * 0.84,
                                     height: textHeight)
            textLayer.opacity = 0
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.beginTime = clip.start
            fadeIn.duration = min(0.2, clip.duration / 4)
            fadeIn.fillMode = .forwards
            fadeIn.isRemovedOnCompletion = false
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.beginTime = clip.end - min(0.2, clip.duration / 4)
            fadeOut.duration = min(0.2, clip.duration / 4)
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false
            let group = CAAnimationGroup()
            group.animations = [fadeIn, fadeOut]
            textLayer.add(group, forKey: "show")
            overlay.addSublayer(textLayer)
        }
        return AVVideoCompositionCoreAnimationTool(configuration:
            .init(postProcessingAsVideoLayer: videoLayer, containingLayer: parent))
    }

    /// 落点：Downloads + 工程名 + 冲突序号（与 MediaEditEngine 同规则）。
    private nonisolated static func resolveDestination(title: String, ext: String) -> URL {
        let sanitized = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = sanitized.isEmpty ? "timeline" : sanitized
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var destination = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return destination
    }
}
