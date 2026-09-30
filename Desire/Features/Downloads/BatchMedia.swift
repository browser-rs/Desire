import Foundation

/// 批量视频下载的 Model 层 + 纯规划逻辑（去重 / 过滤 / 命名）。
///
/// **刻意只 import Foundation**：规划函数要在 `tests/run.sh` 的纯逻辑
/// harness 里验证（见 AGENTS 的纯逻辑单测约定），WebKit/AppKit 依赖
/// 全部留在 `HeadlessMediaResolver` / `BatchMediaExportStore`。
///
/// 两种批量模式（与引擎一一对应）：
/// - **page（喂食流）**：列表页本身就是播放器，嗅探结果里已有全部真实
///   地址——规划 = 去重 + 过滤，直接进下载队列。
/// - **list（逐页解析）**：列表页只有详情页链接，引擎用隐藏 WebView
///   逐页解析出真实地址——规划 = 校验 + 去重，产出解析队列。

/// 一条批量下载任务。
struct BatchMediaItem: Identifiable {
    let id: UUID
    /// page 模式：媒体地址本身；list 模式：详情页地址（解析出 `mediaURL`）。
    let sourceURL: URL
    /// page 模式在规划期就填好；list 模式由解析器回填。
    var mediaURL: URL?
    var referer: URL?
    var title: String
    /// 批内序号（"01"）——重试重新命名时以它为底，**不能**拿 `title` 叠加
    ///（实测：retry 后标题变成 "01-Retry Episode-Retry Episode"）。
    let numberPrefix: String
    var state: State = .pending
    var summary: String?
    /// 对应 `MediaExportStore` 的单文件任务（进度与取消的中转）。
    var jobID: UUID?
    /// 已下完整的 .ts 中间产物路径（下载开始时登记；合成失败/中断后重试
    /// 直接复用它进 remux，不再重新下载整片——01 号 6.4GB 实测重复下载）。
    /// 最终 .mp4 产出成功后清空。
    var tsFileURL: String?
    /// 引擎跑过几次（签名 URL 过期等失败要换新地址自动重试；
    /// 达到上限才算终局失败——真实站点 12 部批量实测：403 过期
    /// 靠模型手动开重试批次，文件因此散落三个目录）。
    var attempts: Int = 0

    enum State: String {
        case pending, resolving, needsHuman, downloading
        case finished, failed, skipped
    }
}

/// 一批下载任务。
struct BatchMediaBatch: Identifiable {
    enum Mode: String { case page, list }
    enum BatchState: String { case running, finished, cancelled }

    let id: UUID
    let mode: Mode
    /// 保存根目录（绝对路径）。nil = 用户全局偏好（默认 ~/Downloads）。
    /// 用户在对话里显式指定的目录存这里——每批独立，不改全局偏好。
    var saveRoot: String?
    /// 分卷规则：目标目录下每 N 个文件滚动一个 archivedNNN 子文件夹
    /// （用户指定 "/Volumes/sd/missav.ws 每 120 个文件新建一个文件夹"）。
    var splitEvery: Int?
    let folderName: String
    var items: [BatchMediaItem]
    var state: BatchState = .running
    let createdAt: Date

    var finishedCount: Int { items.filter { $0.state == .finished }.count }
    var settledCount: Int {
        items.filter { [.finished, .failed, .skipped].contains($0.state) }.count
    }
}

/// 规划：把原始候选整理成队列。全部纯函数，tests/run.sh 直测。
enum BatchMediaPlan {
    struct SkippedEntry {
        let url: String
        let reason: String
    }

    struct PagePlan {
        var items: [(url: URL, title: String)]
        var skipped: [SkippedEntry]
    }

    /// page 模式规划：嗅探 + DOM 扫描的合并候选 → 下载队列。
    ///
    /// 规则：按 URL 字符串去重；跳过 blob:（离开页面即失效）、DASH
    /// （MediaExporter 只认 HLS 与直链）、纯音频（批量场景以视频为主）；
    /// 最后做**变体族去重**——master 与它目录下的画质变体同时被嗅探到时
    /// 只留 master，否则同一视频会按两个画质各下一份。
    static func planPageBatch(
        candidates: [(url: String, kind: String, mime: String, isBlob: Bool)]
    ) -> PagePlan {
        var seen = Set<String>()
        var entries: [(url: URL, kind: String, title: String)] = []
        var skipped: [SkippedEntry] = []
        for candidate in candidates {
            let raw = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" else {
                if !raw.isEmpty { skipped.append(SkippedEntry(url: raw, reason: "invalid url")) }
                continue
            }
            guard !candidate.isBlob, !raw.hasPrefix("blob:") else {
                skipped.append(SkippedEntry(url: raw, reason: "blob: URL only works inside the page"))
                continue
            }
            guard !isDASH(url: url, mime: candidate.mime) else {
                skipped.append(SkippedEntry(url: raw, reason: "DASH (.mpd) is not supported — HLS/direct files only"))
                continue
            }
            guard candidate.kind != "audio" else {
                skipped.append(SkippedEntry(url: raw, reason: "audio-only resource"))
                continue
            }
            guard !seen.contains(raw) else { continue }
            seen.insert(raw)
            entries.append((url, candidate.kind, sanitizedFileName(from: url.lastPathComponent)))
        }

        // 变体族去重：只对 stream 类候选（master/变体都是 m3u8）。
        let streamURLs = entries.filter { $0.kind == "stream" }.map(\.url)
        let (_, droppedStreams) = dedupeVariantFamilies(streamURLs)
        let droppedSet = Set(droppedStreams.map { $0.url.absoluteString })
        for dropped in droppedStreams {
            skipped.append(SkippedEntry(
                url: dropped.url.absoluteString,
                reason: "variant of \(dropped.master.lastPathComponent) — the master playlist covers the highest quality"
            ))
        }

        let items = entries.compactMap { entry -> (url: URL, title: String)? in
            guard entry.kind != "stream" || !droppedSet.contains(entry.url.absoluteString) else { return nil }
            return (entry.url, entry.title)
        }
        return PagePlan(items: items, skipped: skipped)
    }

    /// list 模式规划：详情页地址清单 → 解析队列。
    static func planListBatch(urls: [String]) -> (items: [(url: URL, title: String)], skipped: [SkippedEntry]) {
        var seen = Set<String>()
        var items: [(url: URL, title: String)] = []
        var skipped: [SkippedEntry] = []
        for raw in urls {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
                skipped.append(SkippedEntry(url: trimmed, reason: "invalid url (http/https only)"))
                continue
            }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            items.append((url, ""))
        }
        return (items, skipped)
    }

    /// 解析结果挑选：stream（HLS）> video > audio；stream 之间**优先
    /// master 播放列表**（MediaExporter 会选它内部最高码率 variant），其次
    /// 按画质标记取最高——"按最高清晰度下载"是用户的明确偏好。同 kind 取
    /// 先发现的。返回 nil 表示页面无可下载媒体。
    static func pickBestResource(_ resources: [MediaResource]) -> MediaResource? {
        let downloadable = resources.filter { !$0.isBlob && !isDASH(urlString: $0.url, mime: $0.mime) }
        let priority = ["stream", "video", "audio"]
        for kind in priority {
            let candidates = downloadable.filter { $0.kind.rawValue == kind }
            if kind == "stream", !candidates.isEmpty {
                return bestStream(candidates)
            }
            if let first = candidates.first {
                return first
            }
        }
        return nil
    }

    /// stream 候选排序：master 形态（无画质标记）> 画质标记最高 > 原顺序。
    static func bestStream(_ streams: [MediaResource]) -> MediaResource? {
        streams.max { lhs, rhs in
            scoreStream(lhs.url) < scoreStream(rhs.url)
        } ?? streams.first
    }

    /// 越大越优先：master 形态 1_000_000 底分 + 画质；带画质标记的变体按
    /// 画质数排；都无标记按原顺序（0 平分，max 遇平分取先出现者）。
    static func scoreStream(_ urlString: String) -> Int {
        if let quality = qualityMarker(in: urlString) {
            return quality
        }
        return looksLikeMaster(urlString) ? 1_000_000 : 0
    }

    /// 从 URL 提取画质标记（`720p` / `1080P` / `_2160_` 等），无则 nil。
    static func qualityMarker(in urlString: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[/._-])(\\d{3,4})[pP](?:$|[._/-])") else { return nil }
        let range = NSRange(urlString.startIndex..., in: urlString)
        guard let match = regex.firstMatch(in: urlString, range: range),
              let matchRange = Range(match.range(at: 1), in: urlString),
              let quality = Int(urlString[matchRange]) else { return nil }
        // 240..2160 之外基本是误匹配（时间戳、ID 片段等）。
        guard (240...2160).contains(quality) else { return nil }
        return quality
    }

    /// master 播放列表的常见形态：无画质标记的 playlist/index/master 名。
    /// 嗅探到的 master + 变体并存时，选 master 能拿到全部 variant 里最高
    /// 的那个（选变体就锁死在该画质了）。
    static func looksLikeMaster(_ urlString: String) -> Bool {
        qualityMarker(in: urlString) == nil
    }

    /// **变体族去重**（page 模式）：master 与它目录下的画质变体同时被嗅探
    /// 到时，只保留 master——否则同一视频会按两个画质各下一份。判定：
    /// 变体 URL 在某个 master 形态 URL 的同目录之下。返回被丢弃的变体
    /// （连同归属的 master，写进 skipped 理由）。
    static func dedupeVariantFamilies(_ urls: [URL]) -> (kept: [URL], dropped: [(url: URL, master: URL)]) {
        let masters = urls.filter { looksLikeMaster($0.absoluteString) }
        var dropped: [(url: URL, master: URL)] = []
        var kept: [URL] = []
        for url in urls {
            if let master = masters.first(where: { candidate in
                candidate != url
                    && candidate.host == url.host
                    && url.absoluteString.hasPrefix(candidate.deletingLastPathComponent().absoluteString)
            }) {
                dropped.append((url, master))
            } else {
                kept.append(url)
            }
        }
        return (kept, dropped)
    }

    static func isDASH(url: URL, mime: String) -> Bool {
        isDASH(urlString: url.absoluteString, mime: mime)
    }

    static func isDASH(urlString: String, mime: String) -> Bool {
        urlString.lowercased().contains(".mpd")
            || mime.lowercased().contains("dash")
    }

    /// 文件名消毒：路径分隔符与控制字符替换、限长 80、空则回退。
    static func sanitizedFileName(from raw: String, fallback: String = "video") -> String {
        var base = raw
        if let queryStart = base.firstIndex(of: "?") { base = String(base[..<queryStart]) }
        // 路径噪音（"." / ".." / 纯斜杠）不是名字——回到 fallback。此前 "."
        // 被当成合法文件夹名放行，整批 12 部平铺进 ~/Downloads 根
        //（用户实测"下载错位置"）。
        let probe = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "")
        if probe.isEmpty || probe == "." || probe == ".." {
            return fallback
        }
        base = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: CharacterSet.controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.count > 80 { base = String(base.prefix(80)) }
        return base.isEmpty ? fallback : base
    }

    /// 去掉标题尾部的媒体扩展名：`destinationURL` 会按资源类型追加扩展名，
    /// hint 自带的话会出现 `01-xxx.mp4.mp4`（实测模式 A 首跑即踩）。
    static func stripMediaExtension(_ name: String) -> String {
        let mediaExtensions: Set<String> = ["mp4", "webm", "mkv", "mov", "m4v", "flv",
                                            "avi", "ts", "m3u8", "mpd", "mp3", "m4a",
                                            "aac", "flac", "wav", "ogg", "opus"]
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        let ext = name[name.index(after: dot)...].lowercased()
        guard mediaExtensions.contains(ext) else { return name }
        return String(name[..<dot])
    }

    // MARK: - 命名风格（用户偏好，见 BatchMediaPreferences）

    enum NamingStyle: String {
        /// 页面标题原样（旧行为）。
        case title
        /// 清洗标题：站点标题模板的重复段折叠（某些站的
        /// `<title>` 是"描述-代号"整段重复三遍），截断落在词边界。
        case clean
        /// 番号/代号优先：标题里第一个 "字母-数字" 形态的代号
        /// （MOV-2024001、abc-984…），没有就退回 clean。
        case code
    }

    /// 命名入口：按风格产出文件基础名（不含扩展名）。
    static func displayName(pageTitle: String, mediaURL: URL?, style: NamingStyle) -> String {
        var source = pageTitle.isEmpty ? (mediaURL?.lastPathComponent ?? "") : pageTitle
        source = stripMediaExtension(source)
        switch style {
        case .title:
            return sanitizedFileName(from: source, fallback: "video")
        case .code:
            if let code = codeName(from: source) { return sanitizedFileName(from: code) }
            return cleanPageTitle(source)
        case .clean:
            return cleanPageTitle(source)
        }
    }

    /// 站点标题模板的重复段折叠：某些站的 `<title>` 形如
    /// "描述A-ABC-123 描述A-ABC-123 描述A-ABC-123"，旧行为按 80 字符
    /// 硬截 → 同一句话截三次的文件名。做法：按最小周期找出重复单元，
    /// 保留第一份；再收尾分隔符。
    static func cleanPageTitle(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        base = collapseRepeatedPrefix(base)
        // 模板站的另一形态：标题以代号开头、又以同一代号收尾
        // （"ABC-123 描述-ABC-123"）——尾部那个是模板残留。
        if let code = codeName(from: base), base.hasPrefix(code),
           base.count > code.count, base.hasSuffix(code) {
            var trimmed = String(base.dropLast(code.count))
            while let last = trimmed.last, "-—·| ".contains(last) { trimmed.removeLast() }
            base = trimmed
        }
        // 截断落在词/字边界：超过 60 字符时回退到最近的空白再切。
        if base.count > 60 {
            let cut = base.index(base.startIndex, offsetBy: 60)
            let head = String(base[..<cut])
            if let lastSpace = head.lastIndex(where: { $0 == " " || $0 == "-" }), lastSpace > base.startIndex {
                base = String(head[..<lastSpace])
            } else {
                base = head
            }
        }
        let cleaned = sanitizedFileName(from: base, fallback: "video")
        return cleaned
    }

    /// 重复单元折叠：模板站的 `<title>` 是同一单元重复三遍
    /// （"代号 描述-代号 ×3"）。做法：找**最小周期** p 使
    /// `text[i] == text[i+p]` 对全部 i 成立——文本即同一单元的重复，保留
    /// 第一个单元。词级前缀匹配在这里失效：代号粘在描述词尾部，重复段
    /// 并不从词 0 开始。
    static func collapseRepeatedPrefix(_ text: String) -> String {
        let n = text.count
        guard n >= 16 else { return text }
        let chars = Array(text)
        // 周期从小往大找：最小周期才是基本单元（大周期是它的倍数，
        // 会保留两份单元）。p ≥ 8 防止把普通短词序列误判成周期。
        for p in 8...(n / 2) {
            var periodic = true
            for i in 0..<(n - p) where chars[i] != chars[i + p] {
                periodic = false
                break
            }
            guard periodic else { continue }
            var unit = String(chars[0..<p])
            while let last = unit.last, "-—·| ".contains(last) { unit.removeLast() }
            return unit
        }
        return text
    }

    /// 番号提取：`MOV-2024001` / `abc-984` / `字母+数字-数字(≥3位)` 形态
    /// 的第一个代号。首段必须容数字（"AB2" 这类代号里的数字不在纯字母表
    /// 里，否则整个匹配会退到后半段）。大小写原样保留。
    static func codeName(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9]{1,7}(?:-[A-Za-z0-9]{2,7})?-\\d{3,}") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    /// 批内序号前缀：`01-`、`02-`……总数 > 99 时自动加宽到 3 位。
    static func numberedPrefix(_ index: Int, total: Int) -> String {
        let width = total >= 100 ? 3 : 2
        return String(format: "%0\(width)d", index + 1)
    }
}
