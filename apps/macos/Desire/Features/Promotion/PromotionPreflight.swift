import Foundation

/// 发布前预检（纯逻辑，Foundation-only）：把"发出去才发现"的低级问题挡在
/// 用户确认之前——标题过长的截断、没清干净的占位符、过度承诺词、正文版本号
/// 与应用版本不一致、与已发帖撞车、裸帖没链接。只报可核验的问题，
/// 不猜各平台的细则（规则会变，宁缺毋编）。
nonisolated enum PromotionPreflight {

    struct Input {
        var title: String
        var body: String
        var platform: String = ""
        var url: String?
        /// 近期已发帖标题（撞车检测）。
        var recentTitles: [String] = []
        /// 当前应用版本（推广 Desire 时传入；正文提到别的版本号会报不一致）。
        var appVersion: String?
    }

    static func check(_ input: Input) -> [String] {
        var warnings: [String] = []
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = input.body.trimmingCharacters(in: .whitespacesAndNewlines)

        if title.isEmpty {
            warnings.append("标题为空")
        } else if title.count > 40 {
            warnings.append("标题 \(title.count) 字偏长——多数平台列表页会截断，建议压到 40 字内")
        }

        if body.isEmpty {
            warnings.append("正文为空")
        } else if body.count < 60 {
            warnings.append("正文只有 \(body.count) 字——社区帖太短很难有人点开，建议先讲清「为什么值得看」")
        }

        let placeholders = ["TODO", "待补", "待填", "XXX", "占位", "{{", "【】"]
        if let hit = placeholders.first(where: { title.contains($0) || body.contains($0) }) {
            warnings.append("还有占位符「\(hit)」没清理")
        }

        let promises = ["绝对", "保证", "史上最", "最强", "第一", "永久免费", "100%", "秒杀一切"]
        let hitPromises = promises.filter { title.contains($0) || body.contains($0) }
        if !hitPromises.isEmpty {
            warnings.append("疑似过度承诺（\(hitPromises.joined(separator: "、"))）——换成可验证的说法更稳，也免得被平台当营销内容降权")
        }

        if let version = input.appVersion, !version.isEmpty {
            let stray = mentionedVersions(in: title + "\n" + body)
                .filter { $0 != version }
                .sorted()
            if !stray.isEmpty {
                warnings.append("提到了 v\(stray.joined(separator: "、v"))，与应用当前版本 v\(version) 不一致——发布前核对")
            }
        }

        if !body.contains("http"), input.url?.isEmpty ?? true {
            warnings.append("正文没有任何链接——推广帖建议带上产品页 / 发行页链接")
        }

        for recent in input.recentTitles where MemoryModels.areNearDuplicates(recent, title) {
            warnings.append("与已发《\(recent)》标题几乎相同——换个角度或标题，别重复发")
            break
        }

        return warnings
    }

    /// 文本里出现的 vX.Y[.Z] 版本号（去重）。NSRange 现算现用（文本不变）。
    static func mentionedVersions(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "[vV](\\d+\\.\\d+(?:\\.\\d+)?)") else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out = Set<String>()
        for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
            out.insert(ns.substring(with: match.range(at: 1)))
        }
        return out
    }
}
