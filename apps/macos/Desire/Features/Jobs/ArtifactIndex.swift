import Foundation

/// 产物索引（v0.8.57 批 1）：把散在各 Job 的 `artifactURL` 归一成
/// 统一的产物清单——分类、去重、按时间排。**派生的**，不另存一份状态
/// （与轨迹派生同一哲学：JobStore 是唯一事实源）。
/// Foundation-only、进 tests/run.sh。
nonisolated enum ArtifactIndex {

    nonisolated enum Kind: String, CaseIterable, Sendable {
        case folder, image, video, audio, pdf, document, archive, data, other

        var title: String {
            switch self {
            case .folder: return String(localized: "Folder")
            case .image: return String(localized: "Image")
            case .video: return String(localized: "Video")
            case .audio: return String(localized: "Audio")
            case .pdf: return String(localized: "PDF")
            case .document: return String(localized: "Document")
            case .archive: return String(localized: "Archive")
            case .data: return String(localized: "Data")
            case .other: return String(localized: "Other")
            }
        }

        /// 类型过滤 UI 的展示顺序。
        static var displayOrder: [Kind] {
            [.folder, .image, .video, .audio, .pdf, .document, .archive, .data, .other]
        }
    }

    nonisolated struct Item: Identifiable, Equatable, Sendable {
        /// 稳定 id = 路径哈希（同路径多 Job 去重后仍唯一）。
        let id: String
        let kind: Kind
        let path: String
        /// 目录产物给 nil（尺寸没有意义）；文件给字节（未知 = nil）。
        let sizeBytes: Int?
        let jobID: UUID
        let jobTitle: String
        let at: Date
        let conversationID: UUID?
    }

    /// 路径 → 类型的扩展名表（小写比较；目录另判）。
    private static let extensions: [String: Kind] = [
        "png": .image, "jpg": .image, "jpeg": .image, "webp": .image,
        "heic": .image, "gif": .image, "tiff": .image, "bmp": .image,
        "mp4": .video, "mov": .video, "mkv": .video, "webm": .video, "m4v": .video,
        "ts": .video, "mp3": .audio, "m4a": .audio, "wav": .audio, "aac": .audio,
        "flac": .audio, "opus": .audio,
        "pdf": .pdf,
        "doc": .document, "docx": .document, "odt": .document, "rtf": .document,
        "rtfd": .document, "pages": .document,
        "ppt": .document, "pptx": .document, "key": .document,
        "xls": .data, "xlsx": .data, "csv": .data, "tsv": .data, "numbers": .data,
        "json": .data, "md": .data, "txt": .data,
        "zip": .archive, "tar": .archive, "gz": .archive, "7z": .archive,
    ]

    /// 单路径分类。目录（以 `/` 结尾或无扩展名且像目录的产物路径）= .folder。
    static func classify(path: String) -> Kind {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let file = (trimmed as NSString).lastPathComponent
        if path.hasSuffix("/") { return .folder }
        guard let dot = file.lastIndex(of: ".") else {
            return .folder
        }
        // dot 在首位 = 隐藏文件（".hidden"）——没有扩展名语义，不是目录。
        if dot == file.startIndex { return .other }
        let ext = String(file[dot...].dropFirst()).lowercased()
        return extensions[ext] ?? .other
    }

    /// 稳定 id：路径本身已唯一，直接用（跨会话可复现，无需哈希）。
    static func stableID(path: String) -> String {
        path
    }

    /// 从 Job 记录派生产物清单：取带 artifactURL 的 Job → 分类 →
    /// **同路径去重取最新**（重跑/续跑会重复登记同一产物）→ 按时间降序。
    /// 文件尺寸不在 JobRecord 上——面板展示时现查（`enrich`），派生层不碰盘。
    static func derive(from jobs: [JobRecord]) -> [Item] {
        var byPath: [String: Item] = [:]
        for job in jobs {
            guard let raw = job.artifactURL, !raw.isEmpty else { continue }
            let path = raw
            let kind: Kind = classify(path: path)
            let item = Item(
                id: stableID(path: path),
                kind: kind,
                path: path,
                sizeBytes: nil,
                jobID: job.id,
                jobTitle: job.title,
                at: job.updatedAt,
                conversationID: job.conversationID)
            if let existing = byPath[path] {
                // 同路径多 Job：保留更新的（重跑后旧 Job 的引用作废）。
                if item.at >= existing.at {
                    byPath[path] = item
                }
            } else {
                byPath[path] = item
            }
        }
        return byPath.values.sorted { $0.at > $1.at }
    }

    /// 过滤：类型 + 天数（0 = 不限）。
    static func filter(_ items: [Item], kind: Kind?, withinDays days: Int,
                       now: Date = Date()) -> [Item] {
        var out = items
        if let kind {
            out = out.filter { $0.kind == kind }
        }
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            out = out.filter { $0.at >= cutoff }
        }
        return out
    }

    /// 时间分组（面板展示）：今天 / 本周（7 天内）/ 更早。
    /// 返回按组序排列的 (组名键, items)；空组不出现。
    static func groups(_ items: [Item], now: Date = Date()) -> [(key: String, items: [Item])] {
        let calendar = Calendar.current
        var today: [Item] = []
        var week: [Item] = []
        var earlier: [Item] = []
        for item in items {
            if calendar.isDateInToday(item.at) {
                today.append(item)
            } else if let days = calendar.dateComponents([.day],
                        from: calendar.startOfDay(for: item.at),
                        to: calendar.startOfDay(for: now)).day, days < 7 {
                week.append(item)
            } else {
                earlier.append(item)
            }
        }
        var out: [(key: String, items: [Item])] = []
        if !today.isEmpty { out.append(("today", today)) }
        if !week.isEmpty { out.append(("week", week)) }
        if !earlier.isEmpty { out.append(("earlier", earlier)) }
        return out
    }
}
