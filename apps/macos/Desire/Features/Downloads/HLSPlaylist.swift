import Foundation

/// **HLS 媒体播放列表的解析与本地化**（v0.8.77 批 3，Foundation-only 进 tests/run.sh）。
///
/// 分片并发的做法（2026-11-25 真实使用里智能体的脚本验证过、快 14 倍）：先把分片
/// **并发**抓到本地，再写一份"本地播放列表"——分片、密钥、初始化段都指向本地文件，
/// 其余标签原样保留——交给 ffmpeg 解密合成，或由内置下载器按序解密拼接。
///
/// 这个类型只做两件纯逻辑的事：
/// - 解析媒体播放列表（分片顺序、AES-128 密钥、初始化段、是否点播、有没有按字节范围切片）；
/// - 把原播放列表**逐行**改写成等价的本地版本（密钥轮转、不连续标记等都保留）。
nonisolated struct HLSMediaPlaylist: Equatable {

    enum Line: Equatable {
        /// `#` 开头的标签行（原样，含 `#EXTINF`）。
        case tag(String)
        /// 分片地址（已补成绝对地址）。
        case segment(URL)
    }

    enum ParseError: Error, Equatable {
        /// 文本不是播放列表（没有 `#EXTM3U`）或是 master（只有变体清单、没有分片）。
        case notAMediaPlaylist
        /// SAMPLE-AES 等不支持的加密方式。
        case unsupportedEncryption(String)
    }

    struct Segment: Equatable {
        var url: URL
        var index: Int
    }

    var lines: [Line]
    var segments: [Segment]
    /// AES-128 密钥（首个出现的）；nil = 不加密。
    var keyURL: URL?
    var hasEndList: Bool
    /// `#EXT-X-BYTERANGE`：分片是字节切片，并发路径不处理（回退串行）。
    var hasByteRanges: Bool
    /// `#EXT-X-MAP` 的初始化段地址。
    var initSegmentURL: URL?

    /// 解析媒体播放列表。`#EXTM3U` 开头且至少有一个分片才算；master 抛 `notAMediaPlaylist`。
    static func parse(_ text: String, baseURL: URL) throws -> HLSMediaPlaylist {
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = rawLines.first, first.hasPrefix("#EXTM3U") else {
            throw ParseError.notAMediaPlaylist
        }
        // master 只有变体清单：变体地址不是分片，调用方要先挑一个变体再解析。
        guard !rawLines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else {
            throw ParseError.notAMediaPlaylist
        }
        var lines: [Line] = [.tag("#EXTM3U")]
        var segments: [Segment] = []
        var keyURL: URL?
        var hasEndList = false
        var hasByteRanges = false
        var initSegmentURL: URL?
        var mediaSequence = 0
        for line in rawLines.dropFirst() {
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                    mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
                } else if line.hasPrefix("#EXT-X-KEY:") {
                    let method = attribute("METHOD", in: line)
                    if method == "AES-128" {
                        if keyURL == nil, let uri = attribute("URI", in: line) {
                            keyURL = URL(string: uri, relativeTo: baseURL)
                        }
                    } else if let method, method != "NONE" {
                        // SAMPLE-AES / FairPlay：内置与并发路径都不处理。
                        throw ParseError.unsupportedEncryption(method)
                    }
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    if let uri = attribute("URI", in: line) {
                        initSegmentURL = URL(string: uri, relativeTo: baseURL)
                    }
                } else if line.hasPrefix("#EXT-X-ENDLIST") {
                    hasEndList = true
                } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                    hasByteRanges = true
                }
                lines.append(.tag(line))
            } else {
                guard let segment = URL(string: line, relativeTo: baseURL) else { continue }
                segments.append(Segment(url: segment, index: mediaSequence + segments.count))
                lines.append(.segment(segment))
            }
        }
        guard !segments.isEmpty else { throw ParseError.notAMediaPlaylist }
        return HLSMediaPlaylist(lines: lines, segments: segments, keyURL: keyURL,
                                hasEndList: hasEndList, hasByteRanges: hasByteRanges,
                                initSegmentURL: initSegmentURL)
    }

    /// 总时长（`#EXTINF` 之和）；没有 `#EXTINF` = nil。
    var duration: Double? {
        var total = 0.0
        var found = false
        for line in lines {
            guard case .tag(let tag) = line, tag.hasPrefix("#EXTINF:") else { continue }
            let value = tag.dropFirst("#EXTINF:".count)
                .split(separator: ",", maxSplits: 1).first?
                .split(separator: "@", maxSplits: 1).first ?? ""
            if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) {
                total += seconds
                found = true
            }
        }
        return found ? total : nil
    }

    /// 跨次重试识别"同一个播放列表"的指纹：分片数 + 时长（取整到秒）。签名地址重新
    /// 签过之后每个分片的地址都会变，但顺序和条数不变——据此复用已抓到的分片。
    var fingerprint: String {
        "\(segments.count)|\(Int((duration ?? 0).rounded()))"
    }

    /// 本地播放列表文本：分片行换成 `segmentFile(序号)`，`#EXT-X-KEY` / `#EXT-X-MAP`
    /// 里的 `URI="…"` 换成本地文件；其余标签逐字保留。
    /// - `keyFile`: 播放列表里每个密钥 URI 都改写到它（只支持单一密钥；nil = 不改写）。
    /// - `omitting`: 两轮之后仍抓不到的分片序号——这些分片行连同它前面的 `#EXTINF`
    ///   一起从本地播放列表里去掉（缺文件的行会让 ffmpeg 直接报错）。
    func localText(segmentFile: (Int) -> String, keyFile: String?, initFile: String?,
                   omitting: Set<Int> = []) -> String {
        var out: [String] = []
        for line in lines {
            switch line {
            case .tag(let tag):
                if tag.hasPrefix("#EXT-X-KEY:"), let keyFile {
                    out.append(replacingURI(in: tag, with: keyFile))
                } else if tag.hasPrefix("#EXT-X-MAP:"), let initFile {
                    out.append(replacingURI(in: tag, with: initFile))
                } else {
                    out.append(tag)
                }
            case .segment(let url):
                let index = segments.firstIndex(where: { $0.url == url }) ?? 0
                if omitting.contains(index) {
                    if let last = out.last, last.hasPrefix("#EXTINF:") { out.removeLast() }
                    continue
                }
                out.append(segmentFile(index))
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 内部

    /// 取 `NAME=value` 属性值（去掉两侧引号）。
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=") else { return nil }
        var rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            if let end = rest.firstIndex(of: "\"") { rest = rest[..<end] }
        } else if let comma = rest.firstIndex(of: ",") {
            rest = rest[..<comma]
        }
        let value = String(rest).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func replacingURI(in tag: String, with file: String) -> String {
        guard let range = tag.range(of: "URI=\"") else { return tag }
        guard let end = tag[range.upperBound...].firstIndex(of: "\"") else { return tag }
        return String(tag[..<range.upperBound] + Substring(file) + tag[end...])
    }
}
