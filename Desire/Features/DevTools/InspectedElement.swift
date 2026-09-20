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

    struct CSSProperty: Codable {
        let name: String
        let value: String
        let important: Bool
        let source: String?
    }

    struct BoundingBox: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    init(tagName: String, attributes: [String: String], innerHTML: String, outerHTML: String, cssProperties: [CSSProperty], computedStyle: [String: String], boundingBox: BoundingBox?, selector: String, cssPath: String? = nil, xpath: String?) {
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