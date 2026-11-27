import AppKit
import Foundation

/// Remote 控制帧扩展（v0.8.80 批 4）：产物、实时标签、体检/同步、批量下载与下载记录。
///
/// 这些请求与既有 `downloads` / `backgroundJobs` 走同一条控制帧通道
/// （手机内层帧 → 本机分发 → 加密回帧），不再直连中继的 HTTP 路由
/// （产物屏此前就是走错通道的 P0）。
@MainActor
extension RemoteControlStore {

    // MARK: - 产物（P0：改走控制帧）

    func sendArtifactsFrame() {
        var items = ArtifactIndex.derive(from: JobStore.shared.allJobs)
        items = Array(items.prefix(300))
        let sized = ArtifactIndex.withSizes(items)
        sendInner([
            "t": "artifacts",
            "ok": true,
            "count": sized.count,
            "artifacts": sized.map { item -> [String: Any] in
                var row: [String: Any] = [
                    "path": item.path,
                    "kind": item.kind.rawValue,
                    "jobId": item.jobID.uuidString,
                    "jobTitle": item.jobTitle,
                    "conversationId": item.conversationID?.uuidString ?? "",
                    "at": item.at.ISO8601Format(),
                ]
                row["sizeBytes"] = item.sizeBytes ?? NSNull()
                return row
            },
        ])
    }

    func sendArtifactContent(path: String) {
        guard !path.isEmpty else {
            sendInner(["t": "artifactContent", "path": "", "ok": false,
                       "error": "missing path"])
            return
        }
        var payload = AutomationServer.readArtifact(path: path)
        payload["t"] = "artifactContent"
        payload["path"] = path
        sendInner(payload)
    }

    // MARK: - 实时标签页

    func sendTabsFrame() {
        let managers = TabSessionCoordinator.shared.liveManagers().filter {
            WindowRoleRegistry.shared.role(for: $0.sessionKey) == .user
        }
        let active = TabSessionCoordinator.shared.activeTabManager
        let groups = AppState.live?.tabGroupStore.groups ?? []
        var groupByTab: [UUID: TabGroup] = [:]
        for group in groups {
            for tabID in group.tabIds { groupByTab[tabID] = group }
        }

        let windows: [[String: Any]] = managers.map { manager in
            var row: [String: Any] = [
                "id": TabWindowMove.identifier(manager),
                "title": TabWindowMove.displayTitle(manager),
                "tabs": manager.tabs.count,
                "active": manager === active,
            ]
            row["key"] = manager.sessionKey ?? NSNull()
            return row
        }

        let tabs: [[String: Any]] = (active?.tabs ?? []).enumerated().map { index, tab in
            var row: [String: Any] = [
                "id": tab.id.uuidString,
                "title": tab.displayTitle,
                "url": tab.urlString,
                "selected": index == active?.selectedIndex,
                "loading": tab.isLoading,
                "muted": tab.audioMuted,
                "playing": tab.isPlayingAudio,
                "incognito": tab.isIncognito,
                "suspended": tab.isSuspended,
            ]
            if let group = groupByTab[tab.id] {
                row["group"] = group.name
                row["groupID"] = group.id.uuidString
                row["groupColor"] = group.colorIndex
                row["groupCollapsed"] = group.isCollapsed
            }
            return row
        }

        sendInner([
            "t": "tabs",
            "activeWindow": active.map { TabWindowMove.identifier($0) } ?? "",
            "windows": windows,
            "groups": groups.map { group -> [String: Any] in
                ["id": group.id.uuidString,
                 "name": group.name, "colorIndex": group.colorIndex,
                 "collapsed": group.isCollapsed, "count": group.tabIds.count]
            },
            "tabs": tabs,
        ])
    }

    func handleTabAction(_ inner: RemoteInnerFrame) {
        guard let manager = TabSessionCoordinator.shared.activeTabManager else {
            sendTabsFrame()
            return
        }
        // 新建/复制标签与组折叠不带标签 id（v0.8.81 批 4）。
        switch inner.action {
        case "new":
            let raw = (inner.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            manager.addTab(url: raw.isEmpty ? nil : raw)
            sendTabsFrame()
            pushSnapshot(force: true)
            return
        case "duplicate":
            let url = manager.tabs.indices.contains(manager.selectedIndex)
                ? manager.tabs[manager.selectedIndex].urlString : ""
            manager.addTab(url: url.isEmpty ? nil : url)
            sendTabsFrame()
            pushSnapshot(force: true)
            return
        case "toggleGroup":
            let raw = (inner.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let store = AppState.live?.tabGroupStore else { break }
            if let id = UUID(uuidString: raw) {
                store.toggleCollapsed(id)
            } else if let group = store.groups.first(where: { $0.name == raw }) {
                store.toggleCollapsed(group.id)
            }
            sendTabsFrame()
            return
        default:
            break
        }
        guard let raw = inner.id, let tabID = UUID(uuidString: raw),
              let index = manager.tabs.firstIndex(where: { $0.id == tabID }) else {
            sendTabsFrame()
            return
        }
        switch inner.action {
        case "select":
            manager.selectTab(at: index)
        case "close":
            manager.closeTab(at: index)
        case "move":
            guard let target = TabWindowMove.resolve(inner.window),
                  target !== manager else { break }
            TabWindowMove.move(manager.tabs[index], from: manager, to: target)
        default:
            break
        }
        sendTabsFrame()
        pushSnapshot(force: true)
    }

    // MARK: - 体检 / 同步 / 适配器

    func sendDoctorFrame() async {
        let report = await AgentDoctor.run()
        sendInner([
            "t": "doctor",
            "ok": report.ok,
            "passed": report.passed,
            "total": report.checks.count,
            "checks": report.checks.map { check -> [String: Any] in
                ["name": check.name, "ok": check.ok, "detail": check.detail]
            },
        ])
    }

    /// 同步安全动作（v0.8.81 批 4）：只做"重试"与"清冲突记录"——
    /// 逐条采用本地/远端需要冲突条目的完整载荷与域级写回，当前记录里没有，
    /// 不做看起来能点但语义不成立的开关。
    func handleSyncAction(_ inner: RemoteInnerFrame) {
        guard let store = AppState.live?.syncStore else { return }
        switch inner.text {
        case "retry":
            Task { @MainActor [weak self] in
                await store.syncNow()
                self?.sendSyncHealthFrame()
            }
        case "clearConflicts":
            store.clearConflictNotes()
            sendSyncHealthFrame()
        default:
            break
        }
    }

    func sendSyncHealthFrame() {
        guard let store = AppState.live?.syncStore else {
            sendInner(["t": "syncHealth", "signedIn": false])
            return
        }
        let signedIn: Bool
        var username = ""
        if case .signedIn(let name) = store.authState {
            signedIn = true
            username = name
        } else {
            signedIn = false
        }
        let domains: [[String: Any]] = SyncDomain.allCases.compactMap { domain in
            guard let status = store.domainStatus[domain] else { return nil }
            switch status {
            case .ok(let at):
                return ["domain": domain.rawValue, "ok": true,
                        "at": at.timeIntervalSince1970]
            case .failed(let message):
                return ["domain": domain.rawValue, "ok": false,
                        "error": String(message.prefix(300))]
            }
        }
        let conflicts: [[String: Any]] = store.recentConflicts.prefix(20).map { note in
            ["domain": note.domain, "label": note.label,
             "at": note.at.timeIntervalSince1970]
        }
        let devices: [[String: Any]] = store.devices.map { device in
            var row: [String: Any] = [
                "id": device.deviceID,
                "name": device.name,
                "platform": device.platform,
                "revoked": device.revoked,
            ]
            row["lastSeenAt"] = device.lastSeenAt?.timeIntervalSince1970 ?? NSNull()
            return row
        }
        var payload: [String: Any] = [
            "t": "syncHealth",
            "signedIn": signedIn,
            "syncing": store.isSyncing,
            "domains": domains,
            "conflicts": conflicts,
            "devices": devices,
            "server": store.serverBaseURL,
        ]
        payload["username"] = signedIn ? username : NSNull()
        payload["lastSyncAt"] = store.lastSyncAt?.timeIntervalSince1970 ?? NSNull()
        payload["lastError"] = store.lastError ?? NSNull()
        payload["devicesError"] = store.devicesError ?? NSNull()
        sendInner(payload)
    }

    func sendAdaptersFrame() {
        let store = DPPAdapterStore.shared
        let rows: [[String: Any]] = store.adapters.map { adapter -> [String: Any] in
            let health = store.health[adapter.name]
            var row: [String: Any] = [
                "name": adapter.name,
                "hosts": adapter.hosts,
                "enabled": store.isEnabled(adapter),
                "autoDisabled": store.autoDisabled.contains(adapter.name),
                "successCount": health?.successCount ?? 0,
                "failureCount": health?.failureCount ?? 0,
            ]
            row["notes"] = adapter.notes.isEmpty ? NSNull() : String(adapter.notes.prefix(300))
            row["lastError"] = health?.lastError.map { String($0.prefix(200)) } ?? NSNull()
            row["lastSuccessAt"] = health?.lastSuccessAt?.timeIntervalSince1970 ?? NSNull()
            row["lastFailureAt"] = health?.lastFailureAt?.timeIntervalSince1970 ?? NSNull()
            return row
        }
        sendInner([
            "t": "adapters",
            "adapters": rows,
            "loadErrors": store.loadErrors,
        ])
    }

    // MARK: - 批量下载 / 下载记录

    func sendBatchDownloadsFrame() {
        let store = BatchMediaExportStore.shared
        let batches = store.batches.sorted { $0.createdAt > $1.createdAt }.prefix(8)
        let rows: [[String: Any]] = batches.map { batch -> [String: Any] in
            let items: [[String: Any]] = batch.items.enumerated().map { _, item in
                var row: [String: Any] = [
                    "id": item.id.uuidString,
                    "title": item.title,
                    "state": item.state.rawValue,
                    "attempts": item.attempts,
                ]
                if let progress = store.progress(for: item.id), progress.total > 0 {
                    row["progress"] = Double(progress.done) / Double(progress.total)
                    row["progressDone"] = progress.done
                    row["progressTotal"] = progress.total
                    row["unit"] = progress.unit.rawValue
                }
                row["rate"] = store.itemRates[item.id].map { $0 as Any } ?? NSNull()
                row["bytes"] = item.bytes.map { $0 as Any } ?? NSNull()
                row["seconds"] = item.seconds.map { $0 as Any } ?? NSNull()
                row["summary"] = item.summary.map { String($0.prefix(300)) } ?? NSNull()
                row["failureReason"] = item.failureReason.map { String($0.prefix(300)) } ?? NSNull()
                return row
            }
            let log = BatchMediaLogStore.entries(batch.id).suffix(40).map { entry in
                "\(Self.logClock.string(from: entry.at)) \(entry.line)"
            }
            var row: [String: Any] = [
                "id": batch.id.uuidString,
                "mode": batch.mode.rawValue,
                "state": batch.state.rawValue,
                "folder": batch.folderName,
                "createdAt": batch.createdAt.timeIntervalSince1970,
                "paused": store.isPaused(batch.id),
                "finished": batch.finishedCount,
                "total": batch.items.count,
                "items": items,
                "logTail": log,
            ]
            row["suspendedReason"] = store.suspensionReason(batch.id) ?? NSNull()
            row["saveRoot"] = batch.saveRoot ?? NSNull()
            if let window = batch.window {
                row["window"] = ["start": window.startText, "end": window.endText,
                                 "maxMinutes": window.maxDurationMinutes,
                                 "maxConcurrent": window.maxConcurrent,
                                 "summary": window.summary,
                                 "open": window.isOpen(at: Date())]
            }
            return row
        }
        sendInner(["t": "batchDownloads", "batches": rows])
    }

    func handleBatchAction(_ inner: RemoteInnerFrame) {
        let store = BatchMediaExportStore.shared
        // 手机发起新批次（v0.8.81 批 4）：body 是 JSON（urls/folder/
        // connections/windowStart/windowEnd/maxMinutes/maxConcurrent）。
        if inner.action == "start" {
            startBatchFromRemote(inner.body)
            return
        }
        guard let raw = inner.id, let batchID = UUID(uuidString: raw) else {
            sendBatchDownloadsFrame()
            return
        }
        switch inner.action {
        case "pause":
            store.pause(batchID: batchID)
        case "resume":
            store.resume(batchID: batchID)
        case "retryFailed":
            store.retryFailed(batchID)
        case "cancel":
            store.cancel(batchID: batchID)
        case "skip":
            if let itemRaw = inner.itemID, let itemID = UUID(uuidString: itemRaw) {
                store.skip(batchID: batchID, itemID: itemID)
            }
        case "retry":
            if let itemRaw = inner.itemID, let itemID = UUID(uuidString: itemRaw) {
                store.retryItem(batchID: batchID, itemID: itemID)
            }
        case "window":
            applyRemoteWindow(body: inner.body, batchID: batchID)
        default:
            break
        }
        sendBatchDownloadsFrame()
    }

    /// 手机提交 URL 列表 → 本机起 list 批次；窗口/并发与 Mac 端同一套判定。
    private func startBatchFromRemote(_ body: String?) {
        guard let body, let data = body.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendInner(["t": "error", "message": "batch start: invalid body"])
            return
        }
        let urls = (spec["urls"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else {
            sendInner(["t": "error", "message": "batch start: missing urls"])
            return
        }
        guard urls.count <= BatchMediaExportStore.maxItemsPerBatch else {
            sendInner(["t": "error",
                       "message": "batch start: too many urls (cap \(BatchMediaExportStore.maxItemsPerBatch))"])
            return
        }
        let folder = (spec["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let batch = BatchMediaExportStore.shared.startListBatch(
            pageURLs: urls,
            userAgent: nil,
            folderName: folder?.isEmpty == false ? folder : URL(string: urls[0])?.host,
            connections: spec["connections"] as? Int)
        applyRemoteWindow(body: body, batchID: batch.id)
        sendBatchDownloadsFrame()
        pushSnapshot(force: true)
    }

    private func applyRemoteWindow(body: String?, batchID: UUID) {
        guard let body, let data = body.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let start = spec["windowStart"] as? String,
              let end = spec["windowEnd"] as? String,
              let window = BatchDownloadWindow(
                start: start, end: end,
                maxDurationMinutes: spec["maxMinutes"] as? Int ?? 0,
                maxConcurrent: spec["maxConcurrent"] as? Int ?? 0) else { return }
        BatchMediaExportStore.shared.setWindow(batchID: batchID, window: window)
    }

    func sendDownloadHistoryFrame() {
        let history = DownloadHistory.derive(from: BatchMediaExportStore.shared.batches)
        let sites: [[String: Any]] = history.sites.map { site -> [String: Any] in
            var row: [String: Any] = [
                "host": site.host,
                "batches": site.batches,
                "items": site.items,
                "finished": site.finished,
                "failed": site.failed,
                "skipped": site.skipped,
                "bytes": site.bytes,
                "engines": site.engines,
            ]
            row["averageBytesPerSecond"] = site.averageBytesPerSecond ?? NSNull()
            row["averageSeconds"] = site.averageSeconds ?? NSNull()
            row["connections"] = site.connections ?? NSNull()
            row["lastAt"] = site.lastAt?.timeIntervalSince1970 ?? NSNull()
            row["hint"] = site.hint ?? NSNull()
            return row
        }
        let batches: [[String: Any]] = history.batches.map { batch -> [String: Any] in
            [
                "id": batch.id.uuidString,
                "createdAt": batch.createdAt.timeIntervalSince1970,
                "state": batch.state,
                "folder": batch.folder,
                "items": batch.items,
                "finished": batch.finished,
                "failed": batch.failed,
                "skipped": batch.skipped,
                "bytes": batch.bytes,
            ]
        }
        sendInner([
            "t": "downloadHistory",
            "sites": sites,
            "batches": batches,
            "totals": ["finished": history.finished, "failed": history.failed,
                       "skipped": history.skipped, "bytes": history.bytes],
        ])
    }

    private static let logClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
