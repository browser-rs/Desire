import Foundation

/// XML 格式化/校验（Foundation XMLDocument）——纯逻辑。
nonisolated enum XMLCore {
    static func validate(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else { return "Not valid UTF-8" }
        do {
            _ = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func format(_ text: String, compact: Bool = false) -> Result<String, ToolboxError> {
        guard let data = text.data(using: .utf8) else { return .failure(ToolboxError(message: "Not valid UTF-8")) }
        do {
            let document = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
            var options: XMLNode.Options = []
            if compact {
                options.insert(.nodeCompactEmptyElement)
            } else {
                options.insert(.nodePrettyPrint)
            }
            let output = document.xmlData(options: options)
            guard let string = String(data: output, encoding: .utf8) else {
                return .failure(ToolboxError(message: "Could not encode XML output"))
            }
            if compact {
                // XMLDocument 不提供压缩输出；去掉元素间纯空白（文本节点保留）。
                return .success(string.replacingOccurrences(of: ">\\s*<", with: "><",
                                                             options: .regularExpression))
            }
            return .success(string)
        } catch {
            return .failure(ToolboxError(message: error.localizedDescription))
        }
    }

    static func minify(_ text: String) -> Result<String, ToolboxError> {
        format(text, compact: true)
    }
}
