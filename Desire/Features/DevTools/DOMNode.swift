import Foundation

/// DOM 树的一个节点（Element 页签）。
///
/// 来自 `UserScripts/dom-tree.js`：一次取一层（`children` 只在该层被展开时才有
/// 值），`path` 是 nth-child 链（"" = `<html>`），`selector` 是可直接交给
/// `element-inspect.js` 采集的 nth-child 选择器。
///
/// 身份用 `path`（`Identifiable.id`）而不是元素的 id 属性：绝大多数节点没有
/// id 属性，用它当身份会让 `ForEach` 收到一堆重复 id。
struct DOMNode: Codable, Identifiable {
    let path: String
    let tag: String
    /// 元素的 `id` 属性（JS 里的 `id` 字段）。
    let elementID: String?
    let classes: [String]
    let childCount: Int
    let text: String?
    let selector: String
    /// 子元素超过一次能取的上限（该层被截断）。
    let truncated: Bool?
    /// 展开时才有值。
    let children: [DOMNode]?
    /// 取不到节点时的原因（`not found`）。
    let error: String?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, tag, classes, childCount, text, selector, truncated, children, error
        case elementID = "id"
    }

    /// 行上显示的一行摘要：`tag#id.class`。
    var display: String {
        var text = tag
        if let elementID, !elementID.isEmpty { text += "#\(elementID)" }
        if !classes.isEmpty { text += "." + classes.joined(separator: ".") }
        return text
    }
}
