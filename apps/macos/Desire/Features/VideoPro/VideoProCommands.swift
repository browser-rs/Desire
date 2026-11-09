import AppKit
import AVFoundation
import Foundation
import os

/// VideoPro 命令 API（对齐 ImageEditorCommands）：UI、桥（POST /video/edit）、
/// Agent 共用同一套动作。时间值一律**秒**（时间线位置），与缩放无关。
/// 会话目标 = `VideoEditorStore.active`（当前打开的多轨编辑器）；
/// `editTimeline`（Agent 批式合成）不走这里——它离线构工程直接导出。
@MainActor
enum VideoProCommands {

    /// 命令入口。`store` 仅在 UI 内部直调时显式给；桥/Agent 省略它，由
    /// `session`/`file` 参数路由到对应编辑器会话（缺省 = 当前活动编辑器）。
    static func apply(_ body: [String: Any],
                      store explicitStore: VideoEditorStore? = nil) async -> [String: Any] {
        guard let store = explicitStore ?? VideoEditorStore.resolve(body) else {
            return ["error": VideoEditorStore.hasExplicitTarget(body)
                    ? "No video editor session matches the given session/file. GET /video/state lists sessions."
                    : "No video editor is open. Open VideoPro (desire://tools/videoEditor) first."]
        }
        guard let action = (body["action"] as? String)?.lowercased(), !action.isEmpty else {
            return ["error": "Missing action"]
        }
        do {
            switch action {
            case "state":
                return state(store)
            case "new":
                store.commit(TimelineCore.Project())
                store.setPlayhead(0)
                store.noteProjectFile(nil)
                // 明确开新工程 = 不恢复旧草稿：关掉提示但**不删**草稿文件
                //（用户以后打开那个工程时还能恢复）。不关的话新工程的编辑
                // 会一直被"待决策草稿"挡住不落盘。
                store.pendingDraftNotice = false
                return ["ok": true]
            case "addmedia":
                let paths = (body["paths"] as? [String]) ?? []
                guard !paths.isEmpty else { return ["error": "addmedia needs paths"] }
                let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                store.addSourceFiles(urls)
                return ["ok": true, "count": store.sources.count]
            case "addclip":
                return try await addClip(body, store: store)
            case "addtext":
                guard let text = body["text"] as? String, !text.isEmpty else {
                    return ["error": "addtext needs text"]
                }
                let at = Self.number(body["at"]) ?? store.playhead
                let duration = Self.number(body["duration"]) ?? 3
                let trackID = store.project.tracks.first(where: { $0.kind == .text })?.id
                    ?? store.project.tracks.first!.id
                let clip = TimelineCore.Clip(start: max(0, at), duration: max(0.5, duration),
                                             sourceURL: nil,
                                             label: String(text.prefix(12)), text: text)
                guard let next = TimelineCore.upsertClip(store.project, trackID: trackID, clip: clip) else {
                    return ["error": "addtext rejected (overlap or too short)"]
                }
                store.commit(next)
                return ["ok": true]
            case "split":
                // at 缺省 = 播放头；拆所有轨道（时间线位置的编辑语义）
                let at = Self.number(body["at"]) ?? store.playhead
                store.setPlayhead(at)
                store.splitAllTracks()
                return ["ok": true]
            case "trim":
                guard let id = Self.uuid(body["id"]) else { return ["error": "trim needs id"] }
                return try trimClip(id, body, store: store)
            case "move":
                guard let id = Self.uuid(body["id"]) else { return ["error": "move needs id"] }
                guard let (originTrack, _) = clipPair(in: store.project, id: id) else {
                    return ["error": "clip not found"]
                }
                let trackID = Self.uuid(body["track"]) ?? originTrack
                guard let at = Self.number(body["at"]) ?? (body["at"] == nil ? nil : 0) else {
                    return ["error": "move needs at"]
                }
                guard let next = TimelineCore.moveClip(store.project, clipID: id,
                                                       toTrack: trackID, start: at) else {
                    return ["error": "move rejected (overlap or track-kind mismatch)"]
                }
                store.commit(next)
                return ["ok": true]
            case "delete":
                let ids = (body["ids"] as? [String])?.compactMap(UUID.init) ?? []
                if !ids.isEmpty {
                    store.deleteClips(ids)
                } else {
                    store.deleteSelectedClips()
                }
                return ["ok": true]
            case "select":
                if let id = Self.uuid(body["id"]) {
                    store.select(clipID: id)
                    return ["ok": true, "selected": id.uuidString]
                }
                store.clearSelection()
                return ["ok": true, "selected": ""]
            case "setclip":
                guard let id = Self.uuid(body["id"]) else { return ["error": "setclip needs id"] }
                return try setClip(id, body, store: store)
            case "envelope":
                guard let id = Self.uuid(body["id"]) else { return ["error": "envelope needs id"] }
                let rawPoints = (body["points"] as? [[String: Any]]) ?? []
                var points: [TimelineCore.VolumePoint] = []
                for point in rawPoints {
                    guard let at = point["at"] as? NSNumber,
                          let volume = point["volume"] as? NSNumber else { continue }
                    points.append(TimelineCore.VolumePoint(
                        offset: at.doubleValue,
                        volume: min(2, max(0, volume.doubleValue))))
                }
                guard let next = TimelineCore.setVolumeEnvelope(store.project, clipID: id,
                                                                points: points) else {
                    return ["error": "envelope rejected (clip not found)"]
                }
                store.commit(next)
                return ["ok": true, "points": points.count]
            case "transition":
                guard let left = Self.uuid(body["left"]),
                      let right = Self.uuid(body["right"]) else {
                    return ["error": "transition needs left/right clip ids"]
                }
                let overlap = Self.number(body["overlap"]) ?? 0.5
                guard let next = TimelineCore.setCrossDissolve(store.project, leftID: left,
                                                                rightID: right, overlap: overlap) else {
                    return ["error": "transition rejected (adjacent clips required)"]
                }
                store.commit(next)
                return ["ok": true]
            case "track":
                return try trackOp(body, store: store)
            case "play":
                if let seek = Self.number(body["seek"]) {
                    store.setPlayhead(max(0, seek))
                }
                if (body["toggle"] as? Bool) == true {
                    store.togglePlay()
                }
                return ["ok": true, "playing": store.isPlaying, "playhead": store.playhead]
            case "zoom":
                guard let pps = Self.number(body["pps"]), pps >= 8, pps <= 600 else {
                    return ["error": "zoom needs pps (8...600)"]
                }
                store.pixelsPerSecond = pps
                return ["ok": true, "pps": pps]
            case "undo":
                store.undo()
                return ["ok": true, "canUndo": store.canUndo]
            case "export":
                return try await export(body, store: store)
            case "draft":
                switch (body["op"] as? String) ?? "status" {
                case "save":
                    return ["ok": VideoEditorDraft.save(store.project, for: store.draftSourceKey),
                            "key": store.draftSourceKey]
                case "restore":
                    return ["ok": store.restoreDraft()]
                case "discard":
                    store.discardDraft()
                    return ["ok": true]
                default:
                    return ["ok": true,
                            "key": store.draftSourceKey,
                            "exists": VideoEditorDraft.exists(for: store.draftSourceKey),
                            "pending": store.pendingDraftNotice,
                            "modified": VideoEditorDraft.modified(for: store.draftSourceKey)
                                .map { ISO8601DateFormatter().string(from: $0) } ?? ""]
                }
            case "save":
                guard let path = body["path"] as? String, !path.isEmpty else {
                    return ["error": "save needs path (.dtl)"]
                }
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let data = try JSONEncoder().encode(store.project)
                try data.write(to: url)
                let previousKey = store.draftSourceKey
                store.noteProjectFile(url)   // 先换键，再清草稿
                VideoEditorDraft.remove(for: store.draftSourceKey)
                if previousKey != store.draftSourceKey {
                    // 未命名工程另存为文件：旧 untitled 草稿已落盘为正式工程，
                    // 留着会让下次新开编辑器弹假"未保存修改"。
                    VideoEditorDraft.remove(for: previousKey)
                }
                store.pendingDraftNotice = false
                return ["ok": true, "path": url.path]
            case "load":
                guard let path = body["path"] as? String, !path.isEmpty else {
                    return ["error": "load needs path (.dtl)"]
                }
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let project = try JSONDecoder().decode(TimelineCore.Project.self, from: Data(contentsOf: url))
                store.commit(project)
                store.setPlayhead(0)
                store.noteProjectFile(url)
                return ["ok": true, "duration": TimelineCore.projectDuration(project)]
            default:
                return ["error": "Unknown action: \(action)"]
            }
        } catch let error as VideoProError {
            return ["error": error.message]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - 动作实现

    private struct VideoProError: Error {
        let message: String
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }

    /// (trackID, clip) 查找。
    private static func clipPair(in project: TimelineCore.Project,
                                 id: UUID) -> (UUID, TimelineCore.Clip)? {
        for track in project.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return (track.id, clip)
            }
        }
        return nil
    }

    private static func state(_ store: VideoEditorStore) -> [String: Any] {
        let project = store.project
        let tracks: [[String: Any]] = project.tracks.map { track in
            ["id": track.id.uuidString, "kind": track.kind.rawValue,
             "name": track.name, "muted": track.muted,
             "clips": track.clips.count]
        }
        let clips: [[String: Any]] = project.tracks.flatMap { track in
            track.clips.map { clip in
                ["id": clip.id.uuidString, "track": track.id.uuidString,
                 "kind": track.kind.rawValue, "start": clip.start,
                 "duration": clip.duration, "sourceStart": clip.sourceStart,
                 "label": clip.label, "text": clip.text ?? "",
                 "speed": clip.speed, "volume": clip.volume,
                 "fadeIn": clip.fadeIn, "fadeOut": clip.fadeOut,
                 "quarterTurns": clip.quarterTurns,
                 "envelope": clip.volumeEnvelope.count,
                 "selected": store.multiSelection.contains(clip.id) || store.selectedClipID == clip.id]
            }
        }
        let export: [String: Any]
        switch store.exportState {
        case .idle: export = ["state": "idle"]
        case .running(let progress): export = ["state": "running", "progress": progress]
        case .done(let url): export = ["state": "done", "path": url.path]
        case .failed(let message): export = ["state": "failed", "error": message]
        }
        // 多编辑器会话清单：桥/Agent 按 session/file 定向（ImagePro 同款）。
        let sessions: [[String: Any]] = VideoEditorStore.liveSessions.map { session in
            ["session": session.sessionID.uuidString,
             "file": session.projectFileURL?.path ?? "",
             "title": session.project.title,
             "active": session === VideoEditorStore.active,
             "duration": TimelineCore.projectDuration(session.project),
             "clips": session.project.tracks.reduce(0) { $0 + $1.clips.count }]
        }
        return ["ok": true,
                "session": store.sessionID.uuidString,
                "file": store.projectFileURL?.path ?? "",
                "sessions": sessions,
                "duration": TimelineCore.projectDuration(project),
                "playhead": store.playhead,
                "playing": store.isPlaying,
                "tracks": tracks,
                "clips": clips,
                "sources": store.sources.map { $0.url.path },
                "selected": store.multiSelection.map(\.uuidString),
                "canUndo": store.canUndo,
                "pps": store.pixelsPerSecond,
                "export": export]
    }

    /// 插片段：at 缺省 = 该轨道末尾（首尾相接）。
    private static func addClip(_ body: [String: Any], store: VideoEditorStore) async throws -> [String: Any] {
        guard let rawPath = body["path"] as? String, !rawPath.isEmpty else {
            throw VideoProError(message: "addclip needs path")
        }
        let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VideoProError(message: "file not found: \(url.lastPathComponent)")
        }
        // 素材池登记（异步探测，UI 可见）；命令层不等它——自己同步探测。
        store.addSourceFiles([url])
        let asset = AVURLAsset(url: url)
        let probed = await MediaEditProbe.duration(url)
        let hasVideo = ((try? await asset.loadTracks(withMediaType: .video).count) ?? 0) > 0
        guard let probed, probed > 0 else {
            throw VideoProError(message: "cannot probe duration (unsupported container?)")
        }
        let kindName = (body["track"] as? String)?.lowercased() ?? (hasVideo ? "video" : "audio")
        guard let kind: TimelineCore.TrackKind = kindName == "audio" ? .audio : (kindName == "video" ? .video : nil) else {
            throw VideoProError(message: "track must be video or audio")
        }
        guard let track = store.project.tracks.first(where: { $0.kind == kind }) else {
            throw VideoProError(message: "no \(kindName) track")
        }
        let inPoint = max(0, Self.number(body["in"]) ?? 0)
        let speed = min(4, max(0.25, Self.number(body["speed"]) ?? 1))
        let volume = min(2, max(0, Self.number(body["volume"]) ?? 1))
        let duration: Double
        if let requested = Self.number(body["duration"]), requested > 0 {
            duration = requested
        } else {
            guard probed > inPoint else {
                throw VideoProError(message: "in-point beyond source end; pass duration")
            }
            duration = (probed - inPoint) / speed
        }
        let trackEnd = track.clips.map { $0.end }.max() ?? 0
        let at = Self.number(body["at"]) ?? trackEnd
        let clip = TimelineCore.Clip(start: max(0, at), duration: duration,
                                     sourceStart: inPoint, sourceURL: url,
                                     label: url.lastPathComponent,
                                     speed: speed, volume: volume)
        guard let next = TimelineCore.upsertClip(store.project, trackID: track.id, clip: clip) else {
            throw VideoProError(message: "addclip rejected (overlap or too short)")
        }
        store.commit(next)
        return ["ok": true, "start": clip.start, "duration": duration]
    }

    /// 裁边（等效 trim handle）：start（裁头，入点随速度折算平移）/ duration /
    /// sourceStart 任意组合。
    private static func trimClip(_ id: UUID, _ body: [String: Any],
                                 store: VideoEditorStore) throws -> [String: Any] {
        guard let (trackID, original) = clipPair(in: store.project, id: id) else {
            throw VideoProError(message: "clip not found")
        }
        var clip = original
        let minDuration = TimelineCore.minClipDuration
        if let newStart = Self.number(body["start"]), newStart != clip.start {
            let delta = newStart - clip.start
            guard let moved = TimelineCore.moveClip(store.project, clipID: id,
                                                    toTrack: trackID, start: newStart) else {
                throw VideoProError(message: "start rejected (overlap)")
            }
            store.commit(moved)
            clip.sourceStart = max(0, clip.sourceStart + delta * max(clip.speed, 0.01))
            clip.duration = max(minDuration, clip.duration - delta)
        }
        if let newDuration = Self.number(body["duration"]) {
            clip.duration = max(minDuration, newDuration)
        }
        if let newSourceStart = Self.number(body["sourceStart"]) {
            clip.sourceStart = max(0, newSourceStart)
        }
        guard let next = TimelineCore.upsertClip(store.project, trackID: trackID, clip: clip) else {
            throw VideoProError(message: "trim rejected")
        }
        store.commit(next)
        return ["ok": true, "start": clip.start, "duration": clip.duration,
                "sourceStart": clip.sourceStart]
    }

    /// 片段属性：speed/volume/fadeIn/fadeOut/rotate（rotate 作用于选中）。
    private static func setClip(_ id: UUID, _ body: [String: Any],
                                store: VideoEditorStore) throws -> [String: Any] {
        guard store.project.tracks.flatMap({ $0.clips }).contains(where: { $0.id == id }) else {
            throw VideoProError(message: "clip not found")
        }
        store.select(clipID: id)
        if let speed = Self.number(body["speed"]) {
            store.setSpeed(of: id, min(4, max(0.25, speed)))
        }
        let volume = Self.number(body["volume"])
        let fadeIn = Self.number(body["fadeIn"])
        let fadeOut = Self.number(body["fadeOut"])
        if volume != nil || fadeIn != nil || fadeOut != nil {
            store.setAudioEffects(of: id, volume: volume,
                                  fadeIn: fadeIn, fadeOut: fadeOut)
        }
        if let turns = (body["rotate"] as? NSNumber)?.intValue, turns != 0 {
            store.rotateSelected(turns)
        }
        return ["ok": true]
    }

    private static func trackOp(_ body: [String: Any], store: VideoEditorStore) throws -> [String: Any] {
        let op = (body["op"] as? String)?.lowercased() ?? ""
        switch op {
        case "add":
            let kindName = (body["kind"] as? String)?.lowercased() ?? "video"
            guard let kind = TimelineCore.TrackKind(rawValue: kindName) else {
                throw VideoProError(message: "kind must be video|audio|text")
            }
            var project = store.project
            let track = TimelineCore.Track(id: UUID(), kind: kind,
                                           name: body["name"] as? String ?? "")
            project.tracks.append(track)
            store.commit(project)
            return ["ok": true, "id": track.id.uuidString]
        case "mute":
            guard let id = Self.uuid(body["id"]) else {
                throw VideoProError(message: "track mute needs id")
            }
            store.toggleTrackMute(id)
            return ["ok": true]
        case "move":
            guard let id = Self.uuid(body["id"]) else {
                throw VideoProError(message: "track move needs id")
            }
            store.moveTrack(id, up: (body["up"] as? Bool) ?? true)
            return ["ok": true]
        case "remove":
            guard let id = Self.uuid(body["id"]) else {
                throw VideoProError(message: "track remove needs id")
            }
            var project = store.project
            guard project.tracks.count > 1 else {
                throw VideoProError(message: "cannot remove the last track")
            }
            project.tracks.removeAll { $0.id == id }
            store.commit(project)
            return ["ok": true]
        default:
            throw VideoProError(message: "track op must be add|mute|move|remove")
        }
    }

    private static func export(_ body: [String: Any], store: VideoEditorStore) async throws -> [String: Any] {
        let log = Logger(subsystem: "me.siwi.Desire", category: "video")
        log.info("videopro export: enter cancelled=\(Task.isCancelled)")
        guard let path = body["path"] as? String, !path.isEmpty else {
            throw VideoProError(message: "export needs path (.mp4 or .m4a)")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["mp4", "m4a"].contains(ext) else {
            throw VideoProError(message: "export path must end with .mp4 or .m4a")
        }
        if let height = Self.number(body["height"]), height >= 144 {
            store.exportTargetHeight = height
        }
        store.exportAudioOnly = ext == "m4a"
        guard TimelineCore.projectDuration(store.project) > 0 else {
            throw VideoProError(message: "Timeline is empty")
        }
        // 直接 await：static export 是 **nonisolated**（纯后台协作线程执行，
        // 不回主 actor——进度回调由命令层传空），await 它不占主 actor。
        // （曾包 Task.detached——非必要；.value 的 await 反而成了取消传播
        // 通道，导出中途被外围取消传染抛"操作已停止"。2026-11-10 实测。）
        let rendered: URL
        do {
            rendered = try await withTaskCancellationHandler {
                try await VideoEditorStore.export(
                    project: store.project, progress: { fraction in
                        log.info("videopro export: progress \(fraction, format: .fixed(precision: 2))")
                    })
            } onCancel: {
                log.fault("videopro export: CANCELLED while running")
            }
        } catch {
            let ns = error as NSError
            log.fault("videopro export FAILED: domain=\(ns.domain, privacy: .public) code=\(ns.code) desc=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo).prefix(600), privacy: .public)")
            throw error
        }
        let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if rendered.path != destination.path {
            // moveItem 不覆盖已存在文件——不先删会把旧导出留在原地（E2E 里
            // 表现为"导出了但时长还是上一次的"）。
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: rendered, to: destination)
        }
        return ["ok": true, "path": destination.path,
                "duration": TimelineCore.projectDuration(store.project)]
    }
}
