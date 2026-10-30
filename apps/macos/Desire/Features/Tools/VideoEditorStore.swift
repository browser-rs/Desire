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
    @Published var pixelsPerSecond: Double = 60
    @Published private(set) var isPlaying = false
    @Published private(set) var sources: [SourceMedia] = []
    @Published private(set) var exportState: ExportState = .idle

    let player = AVPlayer()

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var rebuildTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    /// 播放头由观察者推进时不再回写 seek（防回环）。
    private var isScrubbingProgrammatically = false

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

    /// 播放头是否压在某个片段上（决定"分割"是否可用）。
    var playheadOverlapsClip: Bool {
        project.tracks.contains { track in
            track.clips.contains { playhead > $0.start + 0.1 && playhead < $0.end - 0.1 }
        }
    }

    var selectedClip: (TimelineCore.Track, TimelineCore.Clip)? {
        guard let selectedClipID else { return nil }
        return TimelineCore.clip(project, withID: selectedClipID)
    }

    // MARK: - 编辑提交（失败 = 保持原状 + 合成不重构）

    func commit(_ newProject: TimelineCore.Project?) {
        guard let newProject else { return }
        project = newProject
        selectedClipID = selectedClipID.flatMap { id in
            TimelineCore.clip(project, withID: id) != nil ? id : nil
        }
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
            let composition = await Self.buildComposition(project: snapshot)
            guard let self, !Task.isCancelled else { return }
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
            await self.player.seek(to: CMTime(seconds: atPlayhead, preferredTimescale: 600))
        }
    }

    /// 工程的合成：视频轨/音频轨各建一条 composition track，片段按时间线落位
    /// （空隙天然留白）；源轨道加载失败即跳过该片段。
    private nonisolated static func buildComposition(project: TimelineCore.Project) async -> AVComposition {
        let composition = AVMutableComposition()
        for track in project.tracks where !track.clips.isEmpty {
            let mediaType: AVMediaType = track.kind == .audio ? .audio : .video
            guard track.kind != .text,
                  let compositionTrack = composition.addMutableTrack(
                      withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                guard let url = clip.sourceURL else { continue }
                let asset = AVURLAsset(url: url)
                if let source = try? await asset.loadTracks(withMediaType: mediaType).first {
                    let range = CMTimeRange(
                        start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                        duration: CMTime(seconds: clip.duration, preferredTimescale: 600))
                    try? compositionTrack.insertTimeRange(
                        range, of: source, at: CMTime(seconds: clip.start, preferredTimescale: 600))
                }
            }
        }
        return composition
    }

    // MARK: - 导出

    func export() {
        guard !isExporting else { return }
        let snapshot = project
        exportState = .running(0)
        // 捕获强引用局部量（不是 var）——Sendable 闭包里捕获 var self 是 Swift 6 错误。
        let store = self
        exportTask = Task { [weak self] in
            do {
                let url = try await Self.export(project: snapshot) { fraction in
                    Task { @MainActor in
                        store.exportState = .running(min(0.99, fraction))
                    }
                }
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

    private nonisolated static func export(project: TimelineCore.Project,
                                           progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let composition = await buildComposition(project: project)
        let hasVideo = project.tracks.contains { $0.kind == .video && !$0.clips.isEmpty }
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
            // 新 API = Configuration + 不可变 AVVideoComposition）。
            var config = AVVideoComposition.Configuration()
            config.renderSize = await compositionNaturalSize(composition)
            config.frameDuration = CMTime(value: 1, timescale: 30)
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
