import Foundation

/// PPTX 解包读取（v0.8.26 办公增强）：按 `ppt/presentation.xml` 的 sldId 顺序
/// 取幻灯片，逐页解析标题/要点，并顺着 slide rels 找备注页。
/// 只用系统自带 `/usr/bin/unzip`（与 ArchiveKit 同源），零第三方依赖。
nonisolated struct PresentationReadError: Error, Equatable, Sendable {
    var message: String
}

nonisolated struct PresentationDocument: Sendable {
    var title: String
    var slides: [PresentationSlide]
}

nonisolated enum PresentationReader {

    static func read(url: URL, maxSlides: Int = 200,
                     includeNotes: Bool = true) -> Result<PresentationDocument, PresentationReadError> {
        let ext = url.pathExtension.lowercased()
        guard ext == "pptx" else {
            if ext == "ppt" {
                return .failure(PresentationReadError(message: "Legacy .ppt (binary) is not supported — save it as .pptx and try again."))
            }
            return .failure(PresentationReadError(message: "Not a PowerPoint presentation (.pptx expected)."))
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(PresentationReadError(message: "File not found."))
        }

        let presentationXML = unzipEntry(url, "ppt/presentation.xml") ?? Data()
        let presentationText = String(data: presentationXML, encoding: .utf8) ?? ""
        let order = slideOrder(presentationText)
        guard !order.isEmpty else {
            return .failure(PresentationReadError(message: "No slides found (not a valid .pptx?)."))
        }
        let rels = relationshipTargets(
            String(data: unzipEntry(url, "ppt/_rels/presentation.xml.rels") ?? Data(),
                   encoding: .utf8) ?? "")

        var slides: [PresentationSlide] = []
        let limit = min(order.count, max(1, maxSlides))
        for (offset, rID) in order.prefix(limit).enumerated() {
            let target = rels[rID] ?? "slides/slide\(offset + 1).xml"
            let entry = "ppt/" + normalize(target)
            guard let slideData = unzipEntry(url, entry),
                  let slideXML = String(data: slideData, encoding: .utf8) else { continue }
            var slide = PresentationReaderCore.slide(fromXML: slideXML, index: offset + 1)
            if includeNotes, let notesEntry = notesEntry(forSlideEntry: entry, archive: url),
               let notesData = unzipEntry(url, notesEntry),
               let notesXML = String(data: notesData, encoding: .utf8) {
                slide.notes = PresentationReaderCore.notes(fromXML: notesXML)
            }
            slides.append(slide)
        }
        guard !slides.isEmpty else { return .failure(PresentationReadError(message: "Slides could not be parsed.")) }

        let core = String(data: unzipEntry(url, "docProps/core.xml") ?? Data(),
                          encoding: .utf8) ?? ""
        let title = firstMatch(core, pattern: "<dc:title>([^<]*)</dc:title>")
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        return .success(PresentationDocument(title: title, slides: slides))
    }

    // MARK: - 内部

    /// sldId 顺序（r:id 列表）。
    static func slideOrder(_ presentationXML: String) -> [String] {
        matches(presentationXML, pattern: "<p:sldId[^>]*r:id=\"([^\"]+)\"")
    }

    /// rels 的 Id → Target。
    static func relationshipTargets(_ relsXML: String) -> [String: String] {
        var out: [String: String] = [:]
        for tag in matches(relsXML, pattern: "<Relationship[^>]*>") {
            guard let id = firstMatch(tag, pattern: "Id=\"([^\"]+)\""),
                  let target = firstMatch(tag, pattern: "Target=\"([^\"]+)\"") else { continue }
            out[id] = target
        }
        return out
    }

    private static func notesEntry(forSlideEntry slideEntry: String,
                                   archive: URL) -> String? {
        // ppt/slides/slide3.xml → ppt/slides/_rels/slide3.xml.rels
        guard let slash = slideEntry.lastIndex(of: "/") else { return nil }
        let dir = String(slideEntry[..<slash])
        let file = String(slideEntry[slideEntry.index(after: slash)...])
        let relsEntry = "\(dir)/_rels/\(file).rels"
        guard let data = unzipEntry(archive, relsEntry),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        guard let target = firstMatch(xml, pattern: "Target=\"([^\"]*notesSlide[^\"]*)\"") else {
            return nil
        }
        return "ppt/" + normalize(target)
    }

    private static func normalize(_ target: String) -> String {
        var path = target
        while path.hasPrefix("../") { path.removeFirst(3) }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    private static func unzipEntry(_ archive: URL, _ entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let full = Range(match.range, in: text) else { return nil }
            return String(text[full])
        }
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
