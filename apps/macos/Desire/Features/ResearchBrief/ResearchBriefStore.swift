import Combine
import Foundation

/// 研究简报的落盘（v0.8.50）：`Application Support/Desire/ResearchBriefs/<id>/`，
/// 每条三个文件：`meta.json`（整份文档，含来源与分节）、`brief.md`（渲染结果，
/// 用户可直接打开）、`sources.json`（来源速查，便于外部脚本消费）。
@MainActor
final class ResearchBriefStore: ObservableObject {
    static let shared = ResearchBriefStore()

    @Published private(set) var briefs: [ResearchBriefDocument] = []

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Desire/ResearchBriefs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    init() {
        reload()
    }

    func reload() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: Self.directory,
                                                        includingPropertiesForKeys: nil) else {
            briefs = []
            return
        }
        var loaded: [ResearchBriefDocument] = []
        for entry in entries where entry.hasDirectoryPath {
            let meta = entry.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta),
                  let document = try? JSONDecoder().decode(ResearchBriefDocument.self, from: data) else {
                continue
            }
            loaded.append(document)
        }
        briefs = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func document(id: UUID) -> ResearchBriefDocument? {
        briefs.first { $0.id == id }
    }

    /// 写三件套（meta/brief.md/sources.json）。失败静默（磁盘满等极端情况不炸 UI）。
    func save(_ document: ResearchBriefDocument) {
        let folder = Self.folder(document.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(document) {
            try? data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        }
        let markdown = ResearchBriefCore.render(document)
        try? markdown.write(to: folder.appendingPathComponent("brief.md"),
                            atomically: true, encoding: .utf8)
        if let sources = try? JSONEncoder().encode(document.sources) {
            try? sources.write(to: folder.appendingPathComponent("sources.json"), options: .atomic)
        }
        if let index = briefs.firstIndex(where: { $0.id == document.id }) {
            briefs[index] = document
        } else {
            briefs.insert(document, at: 0)
        }
        briefs.sort { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        try? FileManager.default.removeItem(at: Self.folder(id))
        briefs.removeAll { $0.id == id }
        return true
    }

    func markdownURL(id: UUID) -> URL {
        Self.folder(id).appendingPathComponent("brief.md")
    }

    /// 交付：复制渲染结果到 `~/Downloads/Research/<slug>.md`（冲突顺延）。
    @discardableResult
    func exportToDownloads(_ document: ResearchBriefDocument) -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Research", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let markdown = ResearchBriefCore.render(document)
        var base = document.topic
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "research" }
        var destination = folder.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base)-\(counter).md")
            counter += 1
        }
        guard (try? markdown.write(to: destination, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return destination
    }
}
