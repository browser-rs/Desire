import Foundation

/// PDF 批量处理纯逻辑（v0.8.44 批 4）：操作枚举、输入扫描、输出命名。
/// Foundation-only，进 tests/run.sh；PDFKit 执行在 `PDFBatchStore`（app 侧）。
nonisolated enum PDFBatchCore {

    enum Operation: String, CaseIterable {
        /// 文件夹内全部 PDF（按名排序）合并成一个
        case merge
        /// 每个 PDF 按页拆成单页文件（Split/<名>/page-NN.pdf）
        case split
        /// 每个 PDF 提取页码范围（Extracted/<名>.pdf）
        case extract
        /// 每个 PDF 全部页旋转（Rotated/<名>.pdf）
        case rotate

        var outputDirectoryName: String {
            switch self {
            case .merge: return "Merged"
            case .split: return "Split"
            case .extract: return "Extracted"
            case .rotate: return "Rotated"
            }
        }
    }

    /// 校验：文件夹在、含 ≥1 个 PDF、extract 必须带页码规格。
    /// 返回错误文案（nil = 通过）。
    static func validationError(folder: URL, operation: Operation,
                                pagesSpec: String?) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return String(localized: "Folder not found: \(folder.path)")
        }
        guard !pdfFiles(in: folder, recursive: false).isEmpty else {
            return String(localized: "No PDF files found in the folder")
        }
        if operation == .extract {
            let trimmed = pagesSpec?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !trimmed.isEmpty else {
                return String(localized: "Missing pages spec (e.g. 1-3,5)")
            }
        }
        return nil
    }

    /// 文件夹（可选递归）下的 PDF 文件，按文件名排序（合并顺序 = 名字顺序）。
    static func pdfFiles(in folder: URL, recursive: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let urls: [URL]
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]) else { return [] }
            urls = enumerator.allObjects.compactMap { $0 as? URL }
        } else {
            urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])) ?? []
        }
        return urls
            .filter {
                $0.pathExtension.lowercased() == "pdf"
                    && ((try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false)
            }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent,
                                                   options: .caseInsensitive,
                                                   range: nil,
                                                   locale: nil) == .orderedAscending }
    }

    /// 输出文件名（不覆盖源文件：统一进输出目录；split 再加一层页子目录）。
    static func outputURL(for file: URL, in outputDir: URL,
                          operation: Operation, pageIndex: Int? = nil) -> URL {
        let name = file.deletingPathExtension().lastPathComponent
        if operation == .split, let pageIndex {
            return outputDir
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(String(format: "page-%03d.pdf", pageIndex + 1))
        }
        return outputDir.appendingPathComponent("\(name).pdf")
    }

    /// merge 的输出名：<文件夹名>.pdf（重名追加序号）。
    static func mergeOutputURL(in folder: URL, outputDir: URL) -> URL {
        let base = folder.lastPathComponent.isEmpty ? "merged" : folder.lastPathComponent
        var candidate = outputDir.appendingPathComponent("\(base).pdf")
        var suffix = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path) {
            candidate = outputDir.appendingPathComponent("\(base)-\(suffix).pdf")
            suffix += 1
        }
        return candidate
    }
}
