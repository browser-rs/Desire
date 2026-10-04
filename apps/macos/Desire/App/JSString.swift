import Foundation

/// Swift 字符串 → **JS 字符串字面量**（含首尾引号）的统一实现。
///
/// 此前五处手写 `.replacingOccurrences` 链（WebView / BrowsingActions /
/// PluginStore…）各自只处理反斜杠、引号的一部分——`\r`、`\n`、U+2028/2029
/// 进 JS 字符串字面量即 SyntaxError（CRLF 覆盖规则文件曾以此击穿全部视频站
/// CSS，P1-12 同源）。全部收口这里，带单测（tests/run.sh）。
///
/// 用法：`"const s = \(jsStringLiteral(userInput));"`——**总是带引号**，
/// 调用点不再自己写引号与定界符。
nonisolated enum JSString {

    static func literal(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            // U+2028/2029 是合法 JS 源码外的行终止符（ES2019 前进字面量即语法错；
            // 旧引擎仍会炸）——转 \u 形式。
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
