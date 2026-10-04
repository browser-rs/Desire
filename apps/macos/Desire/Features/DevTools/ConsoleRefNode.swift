import Foundation

/// 控制台对象句柄展开出来的一层（`window.__desireConsole.describe(ref)` 的结果）。
///
/// 值是活的、留在页面里，原生侧只拿预览与属性名；属性值本身还是对象时会给
/// 一个新的句柄（`Prop.ref`），面板可以继续往下点。
struct ConsoleRefNode: Codable {
    let ctor: String?
    let preview: String?
    let props: [Prop]?
    /// 句柄过期（页面侧 FIFO 淘汰了它）。
    let error: String?

    struct Prop: Codable, Identifiable {
        let name: String
        let preview: String
        let ref: String?

        var id: String { name }
    }
}
