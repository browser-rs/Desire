import Foundation

/// 首载健康判定（纯逻辑，进 tests/run.sh）：把"站点的风控局域页/空壳文档"
/// 与"本来就轻的页面"分开。
///
/// 实机依据（2026-10-15）：掘金首载会 `complete` 但只有 3 个节点、0 文字
/// （标题却是正常的），navigate 直接放行会让模型对着空页瞎猜；重载一次即
/// 完整渲染。阈值取保守值——只有"几乎没有内容"才算可疑，宁可漏报。
nonisolated enum PageLoadHealth {

    struct Metrics: Equatable {
        var contentType: String
        var textChars: Int
        var elementCount: Int
    }

    /// 解析页面探针返回的 `contentType:textChars:elementCount`。
    /// textChars 用 `-1` 表示 body 还不存在。
    static func parseMetrics(_ raw: String) -> Metrics? {
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let textChars = Int(parts[1]),
              let elementCount = Int(parts[2]) else { return nil }
        return Metrics(contentType: String(parts[0]),
                       textChars: textChars,
                       elementCount: elementCount)
    }

    /// 疑似风控局域页/空壳：HTML 文档且文字 < 20 且元素 < 60。
    /// 非 HTML（JSON/图片/纯文本端点）一律不算——它们的"空"是本色。
    static func suspectEmptyDocument(_ metrics: Metrics) -> Bool {
        let type = metrics.contentType.lowercased()
        guard type.contains("html") else { return false }
        let textChars = metrics.textChars < 0 ? 0 : metrics.textChars
        return textChars < 20 && metrics.elementCount < 60
    }
}
