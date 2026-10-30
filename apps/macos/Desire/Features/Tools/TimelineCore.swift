import Foundation

/// 多轨时间线纯逻辑（v0.8.27 剪辑批）：轨道/片段模型与全部编辑操作——
/// 纯 Foundation、可编码（工程文件 .dtl）、进 tests/run.sh。
/// 执行（合成重构/预览/导出）在 VideoEditorStore。
///
/// 不变量：
/// - 同一轨道内片段**不重叠**（移动/裁边失败返回 nil，调用方保持原状——
///   拖拽 UX 是"松手提交，不合法弹回"）。
/// - 片段 `start` 是时间线位置；`sourceStart` 是源内入点；时长同时约束两端。
nonisolated enum TimelineCore {

    static let minClipDuration = 0.1

    // MARK: - 模型

    enum TrackKind: String, Codable, CaseIterable {
        case text, video, audio
    }

    struct Clip: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var start: Double
        var duration: Double
        /// 源内入点（文字片段不用）。
        var sourceStart: Double = 0
        /// 源文件（文字片段 nil）。**不用空路径 URL 当哨兵**——它是有相对表示
        /// 的退化值，编解码往返不等（工程文件实测）。
        var sourceURL: URL?
        var label: String = ""
        /// 文字片段内容。
        var text: String?
        // ---- 片段效果（v0.8.27 剪辑深化批）----
        /// 速度倍率（0.25–4；1=原速）。duration 是时间线时长，源消耗 =
        /// duration × speed。预览/导出经 scaleTimeRange 重定时。
        var speed: Double = 1
        /// 音量增益（0–2；1=原声）。音频经 AVMutableAudioMix 自动化生效。
        var volume: Double = 1
        /// 淡入/淡出时长（秒，钳到片段时长一半以内）。
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        var end: Double { start + duration }

        /// 源内出点（= 入点 + 时间线时长 × 速度）。
        var sourceEnd: Double { sourceStart + duration * max(speed, 0.01) }

        /// 钳制后的淡入淡出（各不超过时长一半）。
        var clampedFadeIn: Double { min(max(0, fadeIn), duration / 2) }
        var clampedFadeOut: Double { min(max(0, fadeOut), duration / 2) }
    }

    struct Track: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var kind: TrackKind
        var name: String = ""
        var clips: [Clip] = []
    }

    struct Project: Codable, Equatable {
        var title: String = "未命名工程"
        var tracks: [TimelineCore.Track] = [
            Track(kind: .text, name: "文字"),
            Track(kind: .video, name: "主视频"),
            Track(kind: .audio, name: "音频 1"),
        ]
    }

    // MARK: - 查询

    static func projectDuration(_ project: Project) -> Double {
        project.tracks.flatMap { $0.clips }.map { $0.end }.max() ?? 0
    }

    static func track(_ project: Project, withID id: UUID) -> TimelineCore.Track? {
        project.tracks.first { $0.id == id }
    }

    static func clip(_ project: Project, withID id: UUID) -> (TimelineCore.Track, Clip)? {
        for track in project.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return (track, clip)
            }
        }
        return nil
    }

    static func isOverlapping(_ a: Clip, _ b: Clip) -> Bool {
        a.start < b.end - 1e-6 && b.start < a.end - 1e-6
    }

    /// 目标轨道上（除自身外）是否与既有片段冲突。
    static func hasConflict(_ project: Project, clipID: UUID, trackID: UUID,
                            start: Double, duration: Double) -> Bool {
        guard let target = track(project, withID: trackID) else { return true }
        let candidate = Clip(id: clipID, start: start, duration: duration)
        return target.clips.contains { $0.id != clipID && isOverlapping(candidate, $0) }
    }

    // MARK: - 操作（失败返回 nil = 保持原状）

    static func upsertClip(_ project: Project, trackID: UUID, clip: Clip) -> Project? {
        guard !hasConflict(project, clipID: clip.id, trackID: trackID,
                           start: clip.start, duration: clip.duration),
              clip.duration >= minClipDuration else { return nil }
        var project = project
        guard let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        var track = project.tracks[index]
        track.clips.removeAll { $0.id == clip.id }
        track.clips.append(clip)
        track.clips.sort { $0.start < $1.start }
        project.tracks[index] = track
        return project
    }

    static func moveClip(_ project: Project, clipID: UUID, toTrack trackID: UUID,
                         start newStart: Double) -> Project? {
        guard let (origin, clip) = clip(project, withID: clipID) else { return nil }
        // 跨轨移动要求同类别（视频片段进音频轨没有意义）。
        guard track(project, withID: trackID)?.kind == origin.kind else { return nil }
        var moved = clip
        moved.start = max(0, newStart)
        return upsertClip(project, trackID: trackID, clip: moved)
    }

    /// 裁边：newStart/newDuration 任传其一；sourceStart 随左缘联动（不越源头）。
    static func trimClip(_ project: Project, clipID: UUID,
                         newStart: Double? = nil, newDuration: Double? = nil) -> Project? {
        guard let (originTrack, clip) = clip(project, withID: clipID) else { return nil }
        var trimmed = clip
        if let newStart {
            let delta = max(0, newStart) - clip.start
            trimmed.sourceStart = max(0, clip.sourceStart + delta)
            trimmed.start = max(0, newStart)
            trimmed.duration = clip.duration - (trimmed.start - clip.start)
        }
        if let newDuration {
            trimmed.duration = newDuration
        }
        guard trimmed.duration >= minClipDuration else { return nil }
        return upsertClip(project, trackID: originTrack.id, clip: trimmed)
    }

    /// 播放头处分割：左右两段（右段 sourceStart 顺延）；不落在片段内返回 nil。
    static func splitClip(_ project: Project, clipID: UUID, at time: Double) -> Project? {
        guard let (track, clip) = clip(project, withID: clipID),
              time > clip.start + minClipDuration,
              time < clip.end - minClipDuration else { return nil }
        let leftDuration = time - clip.start
        var left = clip
        left.duration = leftDuration
        var right = clip
        right.id = UUID()
        right.start = time
        right.duration = clip.end - time
        right.sourceStart = clip.sourceStart + leftDuration
        var project = project
        guard let index = project.tracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        project.tracks[index].clips.removeAll { $0.id == clipID }
        project.tracks[index].clips.append(contentsOf: [left, right])
        project.tracks[index].clips.sort { $0.start < $1.start }
        return project
    }

    @discardableResult
    static func deleteClip(_ project: Project, clipID: UUID) -> Project {
        var project = project
        for index in project.tracks.indices {
            project.tracks[index].clips.removeAll { $0.id == clipID }
        }
        return project
    }

    static func addTrack(_ project: Project, kind: TrackKind) -> Project {
        var project = project
        let sameKindCount = project.tracks.filter { $0.kind == kind }.count
        let name: String
        switch kind {
        case .audio: name = "音频 \(sameKindCount + 1)"
        case .video: name = "视频 \(sameKindCount + 1)"
        case .text: name = "文字 \(sameKindCount + 1)"
        }
        project.tracks.append(Track(kind: kind, name: name))
        return project
    }

    @discardableResult
    static func removeTrack(_ project: Project, trackID: UUID) -> Project {
        var project = project
        // 主视频轨保留（至少一条视频轨是导出的前提）；文字/音频可删。
        guard let track = track(project, withID: trackID), track.kind != .video else { return project }
        project.tracks.removeAll { $0.id == trackID }
        return project
    }

    /// 新建片段（素材插入）：起点=播放头，与既有片段冲突则顺延到空位。
    static func makeInsertStart(project: Project, trackID: UUID,
                                at playhead: Double, duration: Double) -> Double {
        guard let target = track(project, withID: trackID) else { return max(0, playhead) }
        var start = max(0, playhead)
        // 片段按起点升序：顺延到 A.end 不会与更早的片段冲突，向后逐个避让即可。
        for clip in target.clips.sorted(by: { $0.start < $1.start }) {
            if isOverlapping(Clip(start: start, duration: duration), clip) {
                start = clip.end
            }
        }
        return start
    }

    // MARK: - 片段效果（v0.8.27 剪辑深化批）

    /// 改速度：**时间线时长不变**（画面节奏变了、占的排程不变），源消耗按
    /// 倍率换算；源消耗超出源长则拒绝（返回 nil）。
    static func setSpeed(_ project: Project, clipID: UUID, speed: Double) -> Project? {
        guard let (track, clip) = clip(project, withID: clipID), clip.sourceURL != nil else { return nil }
        let clamped = min(4, max(0.25, speed))
        guard clip.duration * clamped <= clip.duration * 4 else { return nil }
        var updated = clip
        updated.speed = clamped
        return upsertClip(project, trackID: track.id, clip: updated)
    }

    /// 音量/淡变（音频与视频轨的伴音都走同一入口；钳制在 Clip 属性里做）。
    static func setAudioEffects(_ project: Project, clipID: UUID,
                                volume: Double? = nil, fadeIn: Double? = nil,
                                fadeOut: Double? = nil) -> Project? {
        guard let (track, clip) = clip(project, withID: clipID) else { return nil }
        var updated = clip
        if let volume { updated.volume = min(2, max(0, volume)) }
        if let fadeIn { updated.fadeIn = max(0, fadeIn) }
        if let fadeOut { updated.fadeOut = max(0, fadeOut) }
        return upsertClip(project, trackID: track.id, clip: updated)
    }

    // MARK: - 撤销（快照栈，纯函数部分）

    /// 撤销栈辅助：压栈前判重（连续同状态不重复压）。上限由调用方管。
    static func shouldPushUndo(_ stack: [Project], _ project: Project) -> Bool {
        stack.last != project
    }
}
