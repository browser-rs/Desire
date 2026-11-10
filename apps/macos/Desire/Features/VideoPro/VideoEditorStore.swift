import AVFoundation
import os
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

    /// 当前活动编辑器（桥/Agent 命令入口）。弱引用，视图销毁自动失效。
    static weak var active: VideoEditorStore?

    /// 全部活着的编辑器会话（弱持有，对象释放自动摘除）。多标签/多窗口各开
    /// 一个工程时，命令 API 靠 `session`（UUID）/`file`（工程路径）定向。
    private static let registry = NSHashTable<VideoEditorStore>.weakObjects()
    static var liveSessions: [VideoEditorStore] {
        registry.objectEnumerator().allObjects.compactMap { $0 as? VideoEditorStore }
    }

    /// 会话稳定标识（命令定向路由 + `/video/state` 的 sessions 清单）。
    let sessionID = UUID()
    /// 最近一次 save/load 的工程文件（`file=` 定向按它匹配）。
    private(set) var projectFileURL: URL?

    /// 打开编辑器时发现了崩溃/强杀留下的草稿（UI 提示恢复/丢弃）。
    @Published var pendingDraftNotice = false
    private var draftTask: Task<Void, Never>?
    /// 草稿键：工程文件路径；未保存工程 = "untitled"（ImagePro 同款语义）。
    var draftSourceKey: String { projectFileURL?.path ?? "untitled" }

    func activate() {
        Self.registry.add(self)
        Self.active = self
    }

    func noteProjectFile(_ url: URL?) {
        projectFileURL = url
        // 切到某个工程文件后，若那工程有未保存草稿，提示恢复。
        if let url {
            pendingDraftNotice = VideoEditorDraft.exists(for: url.path)
        }
    }

    /// 命令路由：`session`/`file` 优先，都没给才回落 active。**显式给了却没
    /// 匹配到 → nil**（调用方报错）——多标签时宁可失败也不改错工程。
    static func resolve(_ body: [String: Any]) -> VideoEditorStore? {
        let rawSession = (body["session"] as? String) ?? (body["session"] as? NSNumber)?.stringValue
        let rawFile = body["file"] as? String
        if let raw = rawSession, !raw.isEmpty, let uuid = UUID(uuidString: raw),
           let hit = liveSessions.first(where: { $0.sessionID == uuid }) {
            return hit
        }
        if let file = rawFile, !file.isEmpty {
            let wanted = (file as NSString).expandingTildeInPath
            if let hit = liveSessions.first(where: {
                $0.projectFileURL?.path == (wanted as NSString).standardizingPath
            }) {
                return hit
            }
        }
        if (rawSession?.isEmpty == false) || (rawFile?.isEmpty == false) { return nil }
        return active
    }

    /// 显式给了 session/file 但没匹配到（用于错误文案区分）。
    static func hasExplicitTarget(_ body: [String: Any]) -> Bool {
        let session = (body["session"] as? String)?.isEmpty == false
        let file = (body["file"] as? String)?.isEmpty == false
        return session || file
    }

    struct SourceMedia: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let duration: Double
        let hasVideo: Bool
        /// 视频素材分辨率（素材池徽标；音频为 nil）。
        var resolution: CGSize?
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
    /// 会话内导出历史（新→旧，cap 8）——对齐下载中心的产物直达体感。
    @Published private(set) var exportHistory: [URL] = []

    let player = AVPlayer()

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var rebuildTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    /// 播放头由观察者推进时不再回写 seek（防回环）。
    private var isScrubbingProgrammatically = false
    /// 撤销快照栈（cap 50；redo 不做——剪辑场景撤销到头重做价值有限）。
    private var undoStack: [TimelineCore.Project] = []

    /// ObjC 异常现场记录器（一次）：AVFCore 拒绝参数时抛 NSException 后
    /// abort——崩溃报告只有 __cxa_throw 栈没有 reason；装全局 handler 把
    /// reason 写进 unified log（VideoPro 排障用，2026-11-10 文字烧录批次）。
    private static let installExceptionHandlerOnce: Void = {
        NSSetUncaughtExceptionHandler { exception in
            Logger(subsystem: "me.siwi.Desire", category: "video")
                .fault("uncaught ObjC exception: \(exception.name.rawValue, privacy: .public) — \(exception.reason ?? "-", privacy: .public) stack: \(exception.callStackSymbols.joined(separator: " | ").prefix(800), privacy: .public)")
        }
    }()

    init() {
        _ = Self.installExceptionHandlerOnce
        // 后台标签里的编辑器也要能被 session/file 定向到（注册在 init，
        // 不等 onAppear——切到后台后 active 会指向别人）。
        Self.registry.add(self)
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
        // 崩溃/强杀留下的未保存工程：不自动套用（可能不是用户想要的那个），
        // 由视图上的提示条让用户选恢复/丢弃。
        if VideoEditorDraft.exists(for: "untitled") {
            pendingDraftNotice = true
        }
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
        scheduleDraftSave()
    }

    // MARK: - 草稿（崩溃恢复）

    /// 编辑后 3s 防抖写草稿（崩溃/强杀后可恢复）。
    func scheduleDraftSave() {
        draftTask?.cancel()
        // 有待决策的草稿时不要写——否则打开工程后第一次 commit 就把
        // 崩溃前的草稿覆盖成刚载入的内容，恢复入口等于失效。
        guard !pendingDraftNotice else { return }
        draftTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            _ = VideoEditorDraft.save(self.project, for: self.draftSourceKey)
        }
    }

    /// 恢复草稿（恢复后草稿即被消费——后续编辑会重新生成）。
    @discardableResult
    func restoreDraft() -> Bool {
        guard let saved = VideoEditorDraft.load(for: draftSourceKey) else { return false }
        player.pause()
        project = saved
        selectedClipID = nil
        multiSelection = []
        undoStack = []
        canUndo = false
        setPlayhead(0)
        rebuildPreview()
        VideoEditorDraft.remove(for: draftSourceKey)
        pendingDraftNotice = false
        return true
    }

    /// 丢弃草稿。
    func discardDraft() {
        VideoEditorDraft.remove(for: draftSourceKey)
        pendingDraftNotice = false
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

    /// 音频分离（剪映式）：视频片段的音轨复制到音频轨、原段静音，选中新段。
    func detachAudio(of clipID: UUID) {
        guard let (project, detachedID) = TimelineCore.detachAudio(project, clipID: clipID) else { return }
        pushUndo()
        self.project = project
        selectedClipID = detachedID
        rebuildPreview()
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

    // MARK: - J/K/L 走带

    private var jogRate: Double = 0  // 0=停；>0 前进倍数；<0 倒放倍数
    private var jogTask: Task<Void, Never>?

    /// J：连按加速倒退（-1×、-2×、-4× 封顶）。
    func jogBackward() {
        let next = jogRate < 0 ? min(-8, jogRate * 2) : -1
        setJog(next)
    }

    /// L：连按加速前进（1×、2×、4× 封顶）。
    func jogForward() {
        let next = jogRate > 0 ? max(8, jogRate * 2) : 1
        setJog(next)
    }

    /// K：停走带（回到正常播放态）。
    func stopJog() {
        setJog(0)
    }

    private func setJog(_ rate: Double) {
        jogRate = rate
        jogTask?.cancel()
        if rate == 0 {
            if isPlaying == false {
                playhead += 0  // no-op；保持播放头
            }
            return
        }
        player.pause()
        jogTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.jogRate != 0 {
                let next = self.playhead + self.jogRate * 0.25
                self.setPlayhead(max(0, min(self.projectDuration, next)))
                try? await Task.sleep(for: .milliseconds(250))
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
                let asset = AVURLAsset(url: url)
                let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
                var resolution: CGSize?
                if let videoTrack, let size = try? await videoTrack.load(.naturalSize),
                   size.width > 0, size.height > 0 {
                    resolution = size
                }
                await MainActor.run { [weak self] in
                    guard let self, duration > 0 else { return }
                    self.sources.append(SourceMedia(url: url,
                                                    duration: duration,
                                                    hasVideo: videoTrack != nil,
                                                    resolution: resolution))
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
        multiSelection = []
        undoStack = []
        canUndo = false
        setPlayhead(0)
        rebuildPreview()
    }

    func newProject() {
        player.pause()
        project = TimelineCore.Project()
        sources = []
        selectedClipID = nil
        multiSelection = []
        undoStack = []
        canUndo = false
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
        // 文字层（小视频段，ProRes 4444 带 alpha）——叠印进 videoComposition
        // 的 layerInstructions（z 顺序：追加在主视频层之后 = 在上）。
        var textLayers: [(track: AVMutableCompositionTrack, clip: TimelineCore.Clip)] = []
        func newTrack(_ mediaType: AVMediaType) -> AVMutableCompositionTrack? {
            composition.addMutableTrack(withMediaType: mediaType,
                                        preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        func insert(_ source: AVAssetTrack, into track: AVMutableCompositionTrack,
                    clip: TimelineCore.Clip) {
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                duration: CMTime(seconds: clip.duration * clip.speed, preferredTimescale: 600))
            let at = CMTime(seconds: clip.start, preferredTimescale: 600)
            do {
                try track.insertTimeRange(range, of: source, at: at)
            } catch {
                Logger(subsystem: "me.siwi.Desire", category: "video").error(
                    "videopro build: insert failed clip=\(clip.label, privacy: .public) \(error.localizedDescription, privacy: .public)")
                return
            }
            // 变速：要缩放的是**插进轨道后的那一段**（at 起、源消耗时长），
            // 不是源内 range——at>0 时旧写法缩错区间。
            if clip.speed != 1 {
                track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration),
                                     toDuration: CMTime(seconds: clip.duration,
                                                        preferredTimescale: 600))
            }
        }
        for projectTrack in project.tracks where !projectTrack.clips.isEmpty {
            switch projectTrack.kind {
            case .text:
                // 文字片段：预渲染小视频（缺失/内容变化时按需生成）按
                // clip.start 插进**各自的 track**——与视频段同一个 layer 模型。
                for clip in projectTrack.clips.sorted(by: { $0.start < $1.start }) {
                    guard let textVideo = await ensureTextClipVideo(for: clip,
                                                                    renderSize: CGSize(width: 1280, height: 720)),
                          let track = newTrack(.video) else { continue }
                    let asset = AVURLAsset(url: textVideo)
                    guard let source = try? await asset.loadTracks(withMediaType: .video).first else { continue }
                    // 文字小视频从 0 开始、无变速：sourceStart 归零。
                    var textClip = clip
                    textClip.sourceStart = 0
                    textClip.speed = 1
                    insert(source, into: track, clip: textClip)
                    textLayers.append((track, clip))
                }
            case .audio:
                guard let track = newTrack(.audio) else { continue }
                let clipMix = projectTrack.muted
                    ? nil : AVMutableAudioMixInputParameters(track: track)
                for clip in projectTrack.clips.sorted(by: { $0.start < $1.start }) {
                    guard let url = clip.sourceURL else { continue }
                    let asset = AVURLAsset(url: url)
                    if let source = try? await asset.loadTracks(withMediaType: .audio).first {
                        insert(source, into: track, clip: clip)
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
            case .video:
                // **一片段一 track**：同一 track 上的 insertTimeRange 是"插入"
                // 语义（交叠段会把前段尾部推后）——转场交叠必须在不同 track 上
                // 才能叠印（2026-11-10 实测：单 track 方案导出比时间线长 0.5s
                // 且交叉溶解不成立）。
                for clip in projectTrack.clips.sorted(by: { $0.start < $1.start }) {
                    guard let url = clip.sourceURL, let track = newTrack(.video) else { continue }
                    let asset = AVURLAsset(url: url)
                    guard let source = try? await asset.loadTracks(withMediaType: .video).first else { continue }
                    insert(source, into: track, clip: clip)
                    videoClips.append((track, clip))
                }
            }
        }
        var audioMix: AVMutableAudioMix?
        if !mixParameters.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParameters
            audioMix = mix
        }
        let clipsForVideo = videoClips
        let layersForText = textLayers
        // **有一条视频或文字层就要 videoComposition**：多轨叠印（转场交叠/
        // 文字层）全靠它；此前这个构造器被 `audioMix == nil` 连带置空，
        // 纯视频工程（无音轨）的转场/旋转/文字根本进不了导出。
        let configBuilder: ((CGSize) -> AVVideoComposition.Configuration)? =
            (clipsForVideo.isEmpty && layersForText.isEmpty) ? nil : { renderSize in
                Self.buildVideoConfiguration(clips: clipsForVideo, textLayers: layersForText,
                                             renderSize: renderSize)
            }
        return (composition, audioMix, configBuilder)
    }

    /// 视频配置：旋转（transform）+ 相邻交叠段的交叉溶解（转场）。
    /// **按时间轴切段生成 instructions**：AVVideoComposition 要求 instructions
    /// 连续且不重叠，交叠区间必须拆成 [前段][交叠][后段]；每段内活动图层集合
    /// 不变，转场段给后段图层挂 opacity 0→1 坡。图层顺序 = 数组顺序，
    /// 后加的在上面（文字层追加在视频层之后）。
    private nonisolated static func buildVideoConfiguration(
        clips: [(track: AVMutableCompositionTrack, clip: TimelineCore.Clip)],
        textLayers: [(track: AVMutableCompositionTrack, clip: TimelineCore.Clip)] = [],
        renderSize: CGSize) -> AVVideoComposition.Configuration {
        var config = AVVideoComposition.Configuration()
        config.renderSize = renderSize
        config.frameDuration = CMTime(value: 1, timescale: 30)
        let videoSorted = clips.sorted { $0.clip.start < $1.clip.start }
        // 每个片段的"入场转场"时长（前段尾部与它交叠的部分）：该片段
        // 在交叠区间里从透明淡入。
        var incoming: [UUID: Double] = [:]
        if videoSorted.count > 1 {
            for index in 1..<videoSorted.count {
                let prev = videoSorted[index - 1].clip
                let cur = videoSorted[index].clip
                let overlap = max(0, prev.end - cur.start)
                if overlap > 0.05 { incoming[cur.id] = overlap }
            }
        }
        var boundaries: Set<Int> = []
        func addBoundary(_ seconds: Double) {
            boundaries.insert(Int((max(0, seconds) * 600).rounded()))
        }
        // 指令必须从 0 起连续覆盖（工程开头有空格时也要有黑场指令）。
        addBoundary(0)
        for (_, clip) in videoSorted { addBoundary(clip.start); addBoundary(clip.end) }
        for (_, clip) in textLayers { addBoundary(clip.start); addBoundary(clip.end) }
        let ticks = boundaries.sorted()
        guard ticks.count >= 2 else { return config }
        var instructions: [AVVideoCompositionInstruction] = []
        for index in 0..<(ticks.count - 1) {
            let startTick = ticks[index], endTick = ticks[index + 1]
            guard endTick > startTick else { continue }
            let t0 = Double(startTick) / 600
            let t1 = Double(endTick) / 600
            var layers: [AVVideoCompositionLayerInstruction] = []
            // **z 顺序 = 数组顺序，索引 0 在最上层**（独立宿主实测：红在前
            // 输出纯红）。所以文字层排最前（盖住视频）；视频层按时间倒序
            // （转场时后段在上，淡入才看得见）。
            for (track, clip) in textLayers
            where clip.start <= t0 + 1e-6 && clip.end >= t1 - 1e-6 {
                let textConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
                layers.append(AVVideoCompositionLayerInstruction(configuration: textConfig))
            }
            for (track, clip) in videoSorted.reversed()
            where clip.start <= t0 + 1e-6 && clip.end >= t1 - 1e-6 {
                var layerConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
                layerConfig.setTransform(layerTransform(natural: track.naturalSize,
                                                        quarterTurns: clip.quarterTurns,
                                                        renderSize: renderSize), at: .zero)
                if let overlap = incoming[clip.id], t0 < clip.start + overlap - 1e-6 {
                    let rampStart = max(t0, clip.start)
                    let rampEnd = min(t1, clip.start + overlap)
                    if rampEnd > rampStart + 1e-6 {
                        layerConfig.addOpacityRamp(.init(
                            timeRange: CMTimeRange(
                                start: CMTime(seconds: rampStart, preferredTimescale: 600),
                                end: CMTime(seconds: rampEnd, preferredTimescale: 600)),
                            start: 0, end: 1))
                    }
                }
                layers.append(AVVideoCompositionLayerInstruction(configuration: layerConfig))
            }
            instructions.append(AVVideoCompositionInstruction(configuration: .init(
                layerInstructions: layers,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: t0, preferredTimescale: 600),
                    end: CMTime(seconds: t1, preferredTimescale: 600)))))
        }
        if !instructions.isEmpty {
            config.instructions = instructions
        }
        return config
    }

    // MARK: - 文字片段小视频（ProRes 4444 alpha，叠加层）

    /// 文字小视频目录。**文件名 = 内容键**（clip id + 文本 + 时长 + 尺寸）：
    /// 改文案/裁剪时长后自动换新文件，同内容复用；不会出现"改了字还播旧片"。
    private nonisolated static func textClipVideoURL(for clip: TimelineCore.Clip,
                                                      renderSize: CGSize) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Desire/VideoProTextClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = "\(clip.id.uuidString)|\(Int(renderSize.width))x\(Int(renderSize.height))|"
            + String(format: "%.3f", clip.duration) + "|" + (clip.text ?? "")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return dir.appendingPathComponent(
            String(clip.id.uuidString.prefix(8)) + "-" + String(hash, radix: 16) + ".mov")
    }

    /// 已落盘的成品是否可用（0 字节/半截文件不复用——上一次崩溃的残件
    /// 拿进合成会让文字层静默消失）。
    private nonisolated static func textClipVideoReady(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 1024
    }

    /// 同内容生成的单飞账本：预览重建与导出会**并发**走到同一个文字片段
    /// （addtext 提交触发 rebuildPreview，紧接 export 又跑一遍 buildComposition）。
    /// 没有这层时两个 AVAssetWriter 写同一个 URL：后者重开文件，session 起不来，
    /// appendPixelBuffer 抛 NSInternalInconsistencyException → 穿 async 帧杀进程
    /// （2026-11-10 实测崩溃栈实证）。共享同一个 Task 即可。
    private nonisolated static let textClipGate = NSLock()
    nonisolated(unsafe) private static var textClipTasks: [String: Task<URL?, Never>] = [:]

    /// 同步门：async 上下文里直接 lock/unlock 会吃 "unavailable from
    /// asynchronous contexts"（Swift 6 是错误），包一层同步函数即可。
    private nonisolated static func withTextClipGate<T>(_ body: () -> T) -> T {
        textClipGate.lock()
        defer { textClipGate.unlock() }
        return body()
    }

    private nonisolated static func ensureTextClipVideo(for clip: TimelineCore.Clip,
                                                        renderSize: CGSize) async -> URL? {
        let url = textClipVideoURL(for: clip, renderSize: renderSize)
        if textClipVideoReady(url) { return url }
        let key = url.lastPathComponent
        let task: Task<URL?, Never> = withTextClipGate {
            if let running = textClipTasks[key] { return running }
            let created = Task.detached(priority: .userInitiated) {
                await generateTextClipVideo(for: clip, renderSize: renderSize, url: url)
            }
            textClipTasks[key] = created
            return created
        }
        let result = await task.value
        withTextClipGate { textClipTasks[key] = nil }
        return result
    }

    /// 生成文字小视频（ProRes 4444 带 alpha；淡入淡出画进帧）。
    /// 生成管线 = AVAssetWriter + PixelBufferAdaptor + CTLineDraw 逐帧
    ///（独立宿主验证安全；AVFCore 的 Configuration+animationTool 组合在本
    /// OS 渲染期失败，见 export 内注释）。
    private nonisolated static func generateTextClipVideo(for clip: TimelineCore.Clip,
                                                          renderSize: CGSize,
                                                          url: URL) async -> URL? {
        // 先写 .partial，完成后原子改名：中途崩溃/取消只留残件，不会污染成品名。
        let partial = url.deletingPathExtension().appendingPathExtension("partial.mov")
        try? FileManager.default.removeItem(at: partial)
        let duration = max(0.2, clip.duration)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        } catch {
            Logger(subsystem: "me.siwi.Desire", category: "video")
                .error("text clip writer init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.appleProRes4444XQ,
            AVVideoWidthKey: renderSize.width,
            AVVideoHeightKey: renderSize.height,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: renderSize.width,
                kCVPixelBufferHeightKey as String: renderSize.height,
            ])
        // 顺序敏感：startWriting → 确认进入 .writing → startSession → 才能
        // appendPixelBuffer。少了 session 或 session 没起来时 AVFCore 抛
        // NSInternalInconsistencyException（穿 async 帧 = 进程 abort）。
        guard writer.startWriting(), writer.status == .writing else {
            Logger(subsystem: "me.siwi.Desire", category: "video")
                .error("text clip writer start failed: \(writer.error?.localizedDescription ?? "status", privacy: .public)")
            return nil
        }
        writer.startSession(atSourceTime: .zero)
        guard writer.status == .writing else { return nil }
        let fps = 24
        let frames = Int(duration * Double(fps))
        let fadeIn = min(0.2, duration / 4)
        let fadeOut = min(0.2, duration / 4)
        let clipRef = clip
        nonisolated(unsafe) let inputRef = input
        nonisolated(unsafe) let adaptorRef = adaptor
        nonisolated(unsafe) let fontRef = CTFontCreateWithName("PingFang SC Semibold" as CFString,
                                                               renderSize.height * 0.055, nil)
        // **必须等数据源跑完再 finishWriting**：requestMediaDataWhenReady 是
        // 异步调度，紧接着 finishWriting 会在闭包首次执行前结束 session——
        // 随后闭包里的 appendPixelBuffer 抛 "Must start a session"
        //（NSInternalInconsistencyException 穿 async 帧 = 进程 abort，
        // 2026-11-10 两次崩溃报告实证）。
        let resumeOnce = TextClipResumeGate()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "videopro.textclip")) {
                var frame = 0
                while inputRef.isReadyForMoreMediaData && frame < frames {
                    guard let pool = adaptorRef.pixelBufferPool else { break }
                    let seconds = Double(frame) / Double(fps)
                    var opacity = 1.0
                    if seconds < fadeIn { opacity = seconds / fadeIn }
                    if seconds > duration - fadeOut { opacity = max(0, (duration - seconds) / fadeOut) }
                    var pixelBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                    guard let buffer = pixelBuffer else { frame += 1; continue }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    if let context = CGContext(
                        data: CVPixelBufferGetBaseAddress(buffer),
                        width: Int(renderSize.width), height: Int(renderSize.height),
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        context.clear(CGRect(origin: .zero, size: renderSize))
                        let text = clipRef.text ?? ""
                        if !text.isEmpty, opacity > 0 {
                            let attributes: [NSAttributedString.Key: Any] = [
                                .font: fontRef, .foregroundColor: NSColor.white,
                                kCTStrokeWidthAttributeName as NSAttributedString.Key: -3.0,
                                kCTStrokeColorAttributeName as NSAttributedString.Key: NSColor.black,
                            ]
                            let line = CTLineCreateWithAttributedString(
                                NSAttributedString(string: text, attributes: attributes))
                            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                            context.setAlpha(opacity)
                            context.textPosition = CGPoint(
                                x: (renderSize.width - min(bounds.width, renderSize.width * 0.84)) / 2,
                                y: renderSize.height * 0.08)
                            CTLineDraw(line, context)
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    adaptorRef.append(buffer, withPresentationTime: CMTime(
                        value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                    frame += 1
                }
                // 一帧都不剩（含 pool 缺失）才收尾；否则等下一次 ready 回调。
                if frame >= frames || adaptorRef.pixelBufferPool == nil {
                    inputRef.markAsFinished()
                    resumeOnce.fire { cont.resume() }
                }
            }
        }
        // 数据源已 markAsFinished，finishWriting 才只是等编码收尾与落盘。
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        // 原子发布：先删旧成品（同内容重生成时很少见），再改名。
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            Logger(subsystem: "me.siwi.Desire", category: "video")
                .error("text clip publish failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        return url
    }

    /// 图层变换：源画面按比例适配到 renderSize（居中），再绕画面中心旋转。
    /// **源尺寸 ≠ 画布尺寸时不缩放会把画面贴在左下角**（导出 height 与源
    /// 分辨率不同时，视频只剩一角、其余透明——2026-11-10 实测）。
    private nonisolated static func layerTransform(natural: CGSize,
                                                   quarterTurns: Int,
                                                   renderSize: CGSize) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: renderSize.width / 2, y: renderSize.height / 2)
        let quarter = quarterTurns % 4
        if quarter != 0 {
            transform = transform.rotated(by: -CGFloat(quarter) * .pi / 2)
        }
        if natural.width > 0, natural.height > 0 {
            // 旋转 90° 时用交换后的尺寸算 fit，避免转完再裁掉两边。
            let sourceW = quarter % 2 == 0 ? natural.width : natural.height
            let sourceH = quarter % 2 == 0 ? natural.height : natural.width
            let scale = min(renderSize.width / sourceW, renderSize.height / sourceH)
            if scale.isFinite, scale > 0 {
                transform = transform.scaledBy(x: scale, y: scale)
            }
        }
        transform = transform.translatedBy(x: -natural.width / 2, y: -natural.height / 2)
        return transform
    }

    // MARK: - 导出

    func export() {
        guard !isExporting else { return }
        let snapshot = project
        let height = exportTargetHeight
        let audioOnly = exportAudioOnly
        exportState = .running(0)
        // 导出进 Jobs 台账（产物可从 Jobs 面板直达；v0.8.48 批 3）。
        let exportJob = JobStore.shared.start(
            title: String(localized: "Timeline export"),
            kind: .media, detail: snapshot.title, source: "videopro")
        // 捕获强引用局部量（不是 var）——Sendable 闭包里捕获 var self 是 Swift 6 错误。
        let store = self
        exportTask = Task { [weak self] in
            do {
                let url = try await Self.export(project: snapshot, progress: { fraction in
                    Task { @MainActor in
                        store.exportState = .running(min(0.99, fraction))
                    }
                }, targetHeight: height, forceAudioOnly: audioOnly)
                await MainActor.run {
                    JobStore.shared.finish(exportJob, state: .done,
                                           detail: url.lastPathComponent,
                                           artifactURL: url.path)
                    self?.exportState = .done(url)
                    if let self, !self.exportHistory.contains(url) {
                        self.exportHistory.insert(url, at: 0)
                        if self.exportHistory.count > 8 {
                            self.exportHistory.removeLast(self.exportHistory.count - 8)
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    JobStore.shared.finish(exportJob, state: .cancelled, detail: "Cancelled")
                    self?.exportState = .idle
                }
            } catch {
                await MainActor.run {
                    JobStore.shared.finish(exportJob, state: .failed,
                                           error: error.localizedDescription)
                    self?.exportState = .failed(error.localizedDescription)
                }
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
        Logger(subsystem: "me.siwi.Desire", category: "video").info(
            "videopro export: composition duration=\(composition.duration.seconds, format: .fixed(precision: 3), privacy: .public) tracks=\(composition.tracks.map { "\($0.mediaType.rawValue):\($0.timeRange.start.seconds)-\($0.timeRange.end.seconds)" }.joined(separator: ","), privacy: .public)")
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
            //
            // **只在真需要 composition 时才 set**（videoConfig 存在 = 有旋转/
            // 转场；或缩放目标；或文字烧录）。无转场直出时 set 一个默认
            // Configuration 会触发 AVFCore 的 ObjC 异常（setVideoComposition:
            // 抛错 → 穿 async 帧就是主 actor 僵尸/进程终止——2026-11-10
            // 崩溃报告 AVFCore __cxa_throw 实证；editTimeline 默认加转场，
            // 所以该路径从没被测过）。
            if videoConfig != nil || targetHeight != nil {
                // 无文字：新 API（Configuration → 不可变 composition）。
                // 无 videoConfig（无旋转/转场）时 Configuration 是空壳——
                // renderSize=.zero / frameDuration=.zero（zero 的 isValid 为
                // true，必须判 positive）——不填全 setVideoComposition: 会抛
                // ObjC 异常。只在真需要（转场/缩放）时构造。
                var config = videoConfig?(await compositionNaturalSize(composition))
                    ?? AVVideoComposition.Configuration()
                if config.renderSize.width <= 0 || config.renderSize.height <= 0 {
                    config.renderSize = await compositionNaturalSize(composition)
                }
                if config.frameDuration.seconds <= 0 {
                    config.frameDuration = CMTime(value: 1, timescale: 30)
                }
                if let targetHeight {
                    let source = await compositionNaturalSize(composition)
                    let ratio = source.height > 0 ? targetHeight / source.height : 1
                    config.renderSize = CGSize(width: (source.width * ratio).rounded(),
                                               height: targetHeight)
                }
                session.videoComposition = AVVideoComposition(configuration: config)
            }
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
        // 文字片段暂不进导出（2026-11-10 诚实降级）：AVFCore 的
        // Configuration+animationTool 组合在 macOS 27.2 渲染期失败（-11841
        // 未能创作视频，独立宿主对照实证），deprecated 老路径进不了零警告
        // 构建，进程内手动画帧管线触发主 actor 僵尸（原因未定位）——文字
        // 烧录挪 v0.8.48 批 2（方案：文字片段预渲染 PNG→小视频段进
        // composition）。UI 预览中文字可见，导出暂不含；命令层返回 warning。
        return destination
    }

    /// 合成画面的自然尺寸（第一条视频轨的时间映射，缺省 1280×720）。
    private nonisolated static func compositionNaturalSize(_ composition: AVComposition) async -> CGSize {
        // 类型化 track.naturalSize（**不要走 KVC value(forKey:)**：segment 级
        // value(forKey:"naturalSize") 在占位段上抛 valueForUndefinedKey——
        // NSException 穿 async 帧 = 进程终止，2026-11-10 崩溃报告实证）。
        for track in composition.tracks where track.mediaType == .video {
            let size = track.naturalSize
            if size.width > 0, size.height > 0 {
                return size
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

/// 一次性 resume 门：`requestMediaDataWhenReady` 的回调会按 ready 状态多轮
/// 触发，而 `CheckedContinuation` 只能 resume 一次——重复 resume 直接崩。
private nonisolated final class TextClipResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire(_ body: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { body() }
    }
}
