import Foundation

/// 渠道素材变体规格（v0.8.4）：每个渠道的推荐图片尺寸。
/// 纯逻辑，进 harness。
nonisolated enum ChannelAssetSpec {
    struct Spec: Equatable {
        let channelSlug: String
        let label: String
        let width: CGFloat
        let height: CGFloat

        var ratio: String {
            let w = Int(width), h = Int(height)
            func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
            let g = gcd(max(w, 1), max(h, 1))
            return "\(w / g):\(h / g)"
        }
    }

    static let specs: [Spec] = [
        Spec(channelSlug: "x", label: "X / Twitter", width: 1200, height: 675),
        Spec(channelSlug: "xiaohongshu", label: "小红书", width: 1080, height: 1440),
        Spec(channelSlug: "og", label: "OG / Share", width: 1200, height: 630),
        Spec(channelSlug: "juejin", label: "掘金", width: 1200, height: 600),
        Spec(channelSlug: "v2ex", label: "V2EX", width: 1200, height: 675),
    ]

    static func spec(for slug: String) -> Spec? {
        specs.first { $0.channelSlug == slug.lowercased() }
    }
}

/// 素材库纯逻辑：给定源图路径 + 渠道规格列表 → 需要生成的变体路径。
/// 实际的图片缩放由 Agent 工具层用 CoreGraphics 执行。
nonisolated enum CampaignAssetPlan {
    static func assetDirectory(campaignID: UUID) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Desire", isDirectory: true)
            .appendingPathComponent("CampaignAssets", isDirectory: true)
            .appendingPathComponent(campaignID.uuidString, isDirectory: true)
            .path
    }

    static func variantPath(sourcePath: String, spec: ChannelAssetSpec.Spec,
                            campaignID: UUID) -> String {
        let dir = assetDirectory(campaignID: campaignID)
        let base = (sourcePath as NSString).deletingPathExtension
        let name = (base as NSString).lastPathComponent
        let ext = (sourcePath as NSString).pathExtension
        return "\(dir)/\(name)_\(spec.channelSlug)_\(Int(spec.width))x\(Int(spec.height)).\(ext)"
    }

    static func variants(sourcePath: String, campaignID: UUID,
                         channelSlugs: [String]) -> [(spec: ChannelAssetSpec.Spec, path: String)] {
        channelSlugs.compactMap { slug in
            guard let spec = ChannelAssetSpec.spec(for: slug) else { return nil }
            return (spec, variantPath(sourcePath: sourcePath, spec: spec, campaignID: campaignID))
        }
    }
}
