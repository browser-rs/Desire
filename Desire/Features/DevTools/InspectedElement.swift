import Foundation

struct InspectedElement: Codable {
    let tagName: String
    let attributes: [String: String]
    let innerHTML: String
    let outerHTML: String
    let cssProperties: [CSSProperty]
    let computedStyle: [String: String]
    let boundingBox: BoundingBox?
    let selector: String
    /// 到根的完整 CSS 路径（`html>body>div:nth-child(2)`），比 tag+class 更能唯一定位。
    let cssPath: String?
    let xpath: String?
    /// 命中的作者样式规则（级联排查用；跨域样式表读不到，见 `crossOriginSheets`）。
    let matchingRules: [MatchedRule]?
    /// 未能读取的跨域样式表数量——不说明的话会让人以为"规则没匹配上"。
    let crossOriginSheets: Int?

    struct CSSProperty: Codable {
        let name: String
        let value: String
        let important: Bool
        let source: String?
    }

    struct MatchedRule: Codable, Identifiable {
        let selector: String
        let css: String

        var id: String { selector + "\u{1}" + css }
    }

    struct BoundingBox: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    init(tagName: String, attributes: [String: String], innerHTML: String, outerHTML: String, cssProperties: [CSSProperty], computedStyle: [String: String], boundingBox: BoundingBox?, selector: String, cssPath: String? = nil, xpath: String?, matchingRules: [MatchedRule]? = nil, crossOriginSheets: Int? = nil) {
        self.matchingRules = matchingRules
        self.crossOriginSheets = crossOriginSheets
        self.tagName = tagName
        self.attributes = attributes
        self.innerHTML = innerHTML
        self.outerHTML = outerHTML
        self.cssProperties = cssProperties
        self.computedStyle = computedStyle
        self.boundingBox = boundingBox
        self.selector = selector
        self.cssPath = cssPath
        self.xpath = xpath
    }
}