import Foundation

/// 工具分类（v0.8.27）：页面左栏分组与首页卡片网格都用它排序。
enum ToolCategory: String, CaseIterable, Identifiable {
    case calc
    case time
    case codec
    case dev
    case text
    case generate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calc: return String(localized: "Calculators")
        case .time: return String(localized: "Time & Units")
        case .codec: return String(localized: "Encoding")
        case .dev: return String(localized: "Developer")
        case .text: return String(localized: "Text")
        case .generate: return String(localized: "Generate & Graphics")
        }
    }

    var icon: String {
        switch self {
        case .calc: return "function"
        case .time: return "clock"
        case .codec: return "arrow.left.arrow.right"
        case .dev: return "hammer"
        case .text: return "textformat"
        case .generate: return "wand.and.stars"
        }
    }
}

/// 工具注册表（v0.8.27）：id 稳定、可深链（desire://tools/<id>）。
/// 新增工具 = 这里加一个 case + ToolsPageView 的 switch 加一行。
enum ToolID: String, CaseIterable, Identifiable {
    // 计算
    case mortgage, savings, percent, scientific, bmi
    // 时间与换算
    case timestamp, date, units, number, color
    // 编码
    case base64, url, html, unicode, hex
    // 开发
    case hash, json, regex, jwt, uuid
    // 文本
    case text
    // 生成与图形
    case qr, password

    var id: String { rawValue }

    var category: ToolCategory {
        switch self {
        case .mortgage, .savings, .percent, .scientific, .bmi: return .calc
        case .timestamp, .date, .units, .number, .color: return .time
        case .base64, .url, .html, .unicode, .hex: return .codec
        case .hash, .json, .regex, .jwt, .uuid: return .dev
        case .text: return .text
        case .qr, .password: return .generate
        }
    }

    var title: String {
        switch self {
        case .hash: return String(localized: "Hash")
        case .timestamp: return String(localized: "Timestamp")
        case .base64: return String(localized: "Base64")
        case .url: return String(localized: "URL Encode")
        case .json: return String(localized: "JSON")
        case .text: return String(localized: "Text")
        case .number: return String(localized: "Numbers")
        case .uuid: return String(localized: "UUID")
        case .color: return String(localized: "Color")
        case .qr: return String(localized: "QR Code")
        case .password: return String(localized: "Password")
        case .jwt: return String(localized: "JWT")
        case .mortgage: return String(localized: "Mortgage")
        case .savings: return String(localized: "Savings")
        case .percent: return String(localized: "Percentages")
        case .scientific: return String(localized: "Scientific Calculator")
        case .bmi: return String(localized: "BMI")
        case .date: return String(localized: "Date")
        case .units: return String(localized: "Unit Converter")
        case .html: return String(localized: "HTML Entities")
        case .unicode: return String(localized: "Unicode Escape")
        case .hex: return String(localized: "Hex Codec")
        case .regex: return String(localized: "Regex Test")
        }
    }

    var subtitle: String {
        switch self {
        case .hash: return String(localized: "MD5 / SHA-1 / SHA-256 / SHA-512 digests of text")
        case .timestamp: return String(localized: "Convert between Unix time (seconds/milliseconds) and dates")
        case .base64: return String(localized: "Encode or decode Base64, optionally URL-safe")
        case .url: return String(localized: "Percent-encode or decode URLs and query values")
        case .json: return String(localized: "Format, minify, sort keys, validate or tabulate JSON")
        case .text: return String(localized: "Case conversion, line sorting/deduping and text stats")
        case .number: return String(localized: "Convert between decimal, hex, binary and octal")
        case .uuid: return String(localized: "Generate one or more random UUID v4 values")
        case .color: return String(localized: "Convert between HEX and RGB colors")
        case .qr: return String(localized: "Turn text or a URL into a QR code image")
        case .password: return String(localized: "Generate strong random passwords")
        case .jwt: return String(localized: "Decode a JWT header and payload (no signature check)")
        case .mortgage: return String(localized: "Monthly payment, total interest and a full amortization schedule (equal payment / equal principal)")
        case .savings: return String(localized: "Compound or simple interest, with optional monthly contributions")
        case .percent: return String(localized: "Percent of a value, ratio, and percentage change")
        case .scientific: return String(localized: "Evaluate arithmetic expressions with functions and constants")
        case .bmi: return String(localized: "Body mass index from height and weight")
        case .date: return String(localized: "Days between dates, business days and date arithmetic")
        case .units: return String(localized: "Length, weight, temperature, area, volume, speed, data and time")
        case .html: return String(localized: "Escape or unescape HTML entities")
        case .unicode: return String(localized: "Convert text to \\uXXXX escapes and back (surrogate pairs supported)")
        case .hex: return String(localized: "Convert text to hex bytes and back")
        case .regex: return String(localized: "Test a regular expression against text")
        }
    }

    var icon: String {
        switch self {
        case .hash: return "number"
        case .timestamp: return "clock"
        case .base64: return "arrow.left.arrow.right"
        case .url: return "link"
        case .json: return "curlybraces"
        case .text: return "textformat"
        case .number: return "function"
        case .uuid: return "square.grid.2x2"
        case .color: return "paintpalette"
        case .qr: return "qrcode"
        case .password: return "key"
        case .jwt: return "ticket"
        case .mortgage: return "house"
        case .savings: return "banknote"
        case .percent: return "percent"
        case .scientific: return "plus.forwardslash.minus"
        case .bmi: return "heart.text.square"
        case .date: return "calendar"
        case .units: return "ruler"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .unicode: return "globe.asia.australia"
        case .hex: return "number.square"
        case .regex: return "magnifyingglass.circle"
        }
    }

    /// 搜索命中：英文 id/标题/副标题 + 常用中文关键词。
    var searchText: String {
        let keywords: [String]
        switch self {
        case .mortgage: keywords = ["房贷", "贷款", "按揭", "利息", "还款", "等额本息", "等额本金"]
        case .savings: keywords = ["存款", "储蓄", "复利", "利息", "定投"]
        case .percent: keywords = ["百分比", "占比", "增长率", "折扣"]
        case .scientific: keywords = ["计算器", "表达式", "算术", "科学计算"]
        case .bmi: keywords = ["体重", "身高", "健康", "肥胖"]
        case .date: keywords = ["日期", "天数", "工作日", "相差"]
        case .units: keywords = ["单位", "换算", "长度", "重量", "温度", "面积", "体积", "速度", "存储"]
        case .html: keywords = ["实体", "转义", "html", "&amp;"]
        case .unicode: keywords = ["转义", "编码", "unicode", "emoji"]
        case .hex: keywords = ["十六进制", "hex", "字节"]
        case .regex: keywords = ["正则", "匹配", "regex"]
        case .timestamp: keywords = ["时间戳", "unix", "日期", "毫秒"]
        case .base64: keywords = ["编码", "解码", "base64"]
        case .url: keywords = ["编码", "解码", "url", "百分号"]
        case .json: keywords = ["格式化", "校验", "压缩", "json"]
        case .hash: keywords = ["摘要", "哈希", "md5", "sha"]
        case .jwt: keywords = ["令牌", "token", "jwt"]
        case .uuid: keywords = ["唯一", "uuid"]
        case .color: keywords = ["颜色", "色值", "rgb", "hex"]
        case .qr: keywords = ["二维码", "qr", "生成"]
        case .password: keywords = ["密码", "随机", "生成"]
        case .text: keywords = ["文本", "大小写", "排序", "去重", "统计"]
        case .number: keywords = ["进制", "二进制", "十六进制", "八进制"]
        }
        return ([rawValue, title, subtitle] + keywords).joined(separator: " ")
    }
}
