import Foundation

/// 远程快照的**白板内容载荷构建**（v0.7.23 跨端可读化；Foundation-only，
/// 进 harness——同一份类型与 JSON 形状就是桌面/iOS 两端的契约，编解码
/// round-trip 在单测里锁死）。
///
/// 在原有 `preview`（200 字符，旧客户端兼容字段）之外按类型补只读内容：
/// - note  → `text`（截 1200 字符，够手机读一段备忘/代码）
/// - table → `rows`（markdown 表格解析，12 行 × 8 列封顶，跳过 `|---|` 行）
/// - image → `imageThumb`（缩略 data URI，由调用方提供；**帧内最多 2 张**）
///
/// 全局字节预算（默认 18K；快照帧总预算 22K、留状态字段余量）：逐块从
/// preview 升级到带内容的版本，**用真实编码后的字节数**判定，装不下退回
/// preview——估算口径漂移过一次就不再估。
nonisolated enum RemoteBoardContent {

    struct BlockPayload: Codable, Equatable {
        var type: String
        var title: String?
        /// 内容前 200 字符（image 块 = data URI 前缀，仅供类型判断）。
        var preview: String
        var contentLength: Int
        /// note 全文（截 1200）。
        var text: String?
        /// table 行（≤12×8）。
        var rows: [[String]]?
        /// image 缩略图 data URI（预算内）。
        var imageThumb: String?
    }

    struct Input {
        var type: String
        var title: String?
        var content: String

        init(type: String, title: String?, content: String) {
            self.type = type
            self.title = title
            self.content = content
        }
    }

    static func build(blocks: [Input],
                      maxBlocks: Int = 12,
                      byteBudget: Int = 18_000,
                      maxThumbs: Int = 2,
                      thumbnail: ((String) -> String?)? = nil) -> (payload: [BlockPayload], bytes: Int) {
        var payload: [BlockPayload] = []
        var thumbs = 0
        for block in blocks.prefix(maxBlocks) {
            let base = BlockPayload(type: block.type, title: block.title,
                                    preview: String(block.content.prefix(200)),
                                    contentLength: block.content.count,
                                    text: nil, rows: nil, imageThumb: nil)
            var enriched = base
            switch block.type {
            case "note":
                enriched.text = String(block.content.prefix(1200))
            case "table":
                enriched.rows = parseTableRows(block.content)
            case "image":
                if thumbs < maxThumbs, let thumbnail, let thumb = thumbnail(block.content) {
                    enriched.imageThumb = thumb
                }
            default:
                break
            }
            var chosen = base
            if encodedSize(payload + [enriched]) <= byteBudget {
                chosen = enriched
                if enriched.imageThumb != nil { thumbs += 1 }
            }
            payload.append(chosen)
        }
        return (payload, encodedSize(payload))
    }

    /// markdown 表格 → 行（跳过 `|---|` 分隔行；保留表头行；12×8 封顶）。
    /// 解析不出任何数据行返回 nil（调用方退回 preview）。
    static func parseTableRows(_ content: String, maxRows: Int = 12, maxCols: Int = 8) -> [[String]]? {
        var rows: [[String]] = []
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { continue }
            var cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            guard !cells.isEmpty else { continue }
            // 分隔行：`---` / `:--:` 形态。
            if cells.allSatisfy({ cell in
                !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
            }) { continue }
            rows.append(Array(cells.prefix(maxCols)))
            if rows.count >= maxRows { break }
        }
        return rows.isEmpty ? nil : rows
    }

    static func encodedSize(_ payload: [BlockPayload]) -> Int {
        (try? JSONEncoder().encode(payload))?.count ?? 0
    }
}
