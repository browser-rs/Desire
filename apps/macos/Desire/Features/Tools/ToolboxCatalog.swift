import Foundation

/// 工具分类（v0.8.27）：页面左栏分组与首页卡片网格都用它排序。
enum ToolCategory: String, CaseIterable, Identifiable {
    case calc
    case time
    case codec
    case dev
    case text
    case generate
    case security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calc: return String(localized: "Calculators")
        case .time: return String(localized: "Time & Units")
        case .codec: return String(localized: "Encoding")
        case .dev: return String(localized: "Developer")
        case .text: return String(localized: "Text")
        case .generate: return String(localized: "Generate & Graphics")
        case .security: return String(localized: "Security & Checks")
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
        case .security: return "lock.shield"
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
    // 扩展批（2026-10-30）
    case random, imageConvert
    case morse, dataURI, width, csvJSON
    case diff, xml, sql, urlParse, cidr, httpStatus, mime, userAgent, cron
    case aes, hmac, fileHash, idCard, luhn

    var id: String { rawValue }

    var category: ToolCategory {
        switch self {
        case .mortgage, .savings, .percent, .scientific, .bmi: return .calc
        case .timestamp, .date, .units, .number, .color: return .time
        case .base64, .url, .html, .unicode, .hex: return .codec
        case .hash, .json, .regex, .jwt, .uuid: return .dev
        case .text: return .text
        case .qr, .password, .random, .imageConvert: return .generate
        case .morse, .dataURI, .width, .csvJSON: return .codec
        case .diff, .xml, .sql, .urlParse, .cidr, .httpStatus, .mime, .userAgent, .cron: return .dev
        case .aes, .hmac, .fileHash, .idCard, .luhn: return .security
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
        case .number: return String(localized: "Number Bases")
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
        case .random: return String(localized: "Random")
        case .imageConvert: return String(localized: "Image Convert")
        case .morse: return String(localized: "Morse Code")
        case .dataURI: return String(localized: "Data URI")
        case .width: return String(localized: "Full/Half Width")
        case .csvJSON: return String(localized: "CSV ↔ JSON")
        case .diff: return String(localized: "Text Diff")
        case .xml: return String(localized: "XML")
        case .sql: return String(localized: "SQL Formatter")
        case .urlParse: return String(localized: "URL Parser")
        case .cidr: return String(localized: "IP / CIDR")
        case .httpStatus: return String(localized: "HTTP Status")
        case .mime: return String(localized: "MIME Types")
        case .userAgent: return String(localized: "User Agent")
        case .cron: return String(localized: "Cron")
        case .aes: return String(localized: "AES Encrypt")
        case .hmac: return String(localized: "HMAC-SHA256")
        case .fileHash: return String(localized: "File Hash")
        case .idCard: return String(localized: "ID Card Check")
        case .luhn: return String(localized: "Luhn Check")
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
        case .random: return String(localized: "Random strings and numbers")
        case .imageConvert: return String(localized: "Convert an image and/or downscale its longest side")
        case .morse: return String(localized: "Encode text to Morse code and back")
        case .dataURI: return String(localized: "Text or files to data: URIs and back")
        case .width: return String(localized: "Convert between full-width and half-width characters")
        case .csvJSON: return String(localized: "Convert CSV to JSON or JSON to CSV")
        case .diff: return String(localized: "Compare two texts line by line")
        case .xml: return String(localized: "Format, compact or validate XML")
        case .sql: return String(localized: "Uppercase keywords and break SQL into clauses")
        case .urlParse: return String(localized: "Break a URL into scheme, host, path and query")
        case .cidr: return String(localized: "IPv4 network, broadcast, mask and host range")
        case .httpStatus: return String(localized: "Look up common HTTP status codes")
        case .mime: return String(localized: "Extension ↔ MIME type lookup")
        case .userAgent: return String(localized: "Guess browser, OS and engine from a UA string")
        case .cron: return String(localized: "Explain a 5-field cron expression and show next runs")
        case .aes: return String(localized: "AES-GCM encrypt/decrypt with a passphrase (PBKDF2)")
        case .hmac: return String(localized: "HMAC-SHA256 signature of text with a key")
        case .fileHash: return String(localized: "MD5/SHA hashes of a local file")
        case .idCard: return String(localized: "Validate a Chinese 18-digit ID number")
        case .luhn: return String(localized: "Validate a card number or compute its check digit")
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
        case .random: return "dice"
        case .imageConvert: return "photo.on.rectangle.angled"
        case .morse: return "dot.radiowaves.left.and.right"
        case .dataURI: return "doc.badge.gearshape"
        case .width: return "arrow.left.and.right.square"
        case .csvJSON: return "tablecells"
        case .diff: return "plusminus.circle"
        case .xml: return "chevron.left.forwardslash.chevron.right"
        case .sql: return "cylinder"
        case .urlParse: return "link.badge.plus"
        case .cidr: return "network"
        case .httpStatus: return "number.circle"
        case .mime: return "doc.questionmark"
        case .userAgent: return "person.crop.circle.badge.questionmark"
        case .cron: return "calendar.badge.clock"
        case .aes: return "lock"
        case .hmac: return "signature"
        case .fileHash: return "doc.badge.ellipsis"
        case .idCard: return "person.text.rectangle"
        case .luhn: return "creditcard"
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
        case .random: keywords = ["随机", "抽签", "验证码", "random"]
        case .imageConvert: keywords = ["图片", "转换", "压缩", "jpg", "png", "heic"]
        case .morse: keywords = ["摩斯", "电码", "morse"]
        case .dataURI: keywords = ["data uri", "base64", "内联", "图片"]
        case .width: keywords = ["全角", "半角", "width"]
        case .csvJSON: keywords = ["csv", "json", "表格", "转换"]
        case .diff: keywords = ["对比", "差异", "diff", "比较"]
        case .xml: keywords = ["xml", "格式化", "校验"]
        case .sql: keywords = ["sql", "格式化", "数据库"]
        case .urlParse: keywords = ["url", "解析", "参数", "查询"]
        case .cidr: keywords = ["ip", "cidr", "子网", "网段", "掩码"]
        case .httpStatus: keywords = ["状态码", "http", "404", "500"]
        case .mime: keywords = ["mime", "类型", "扩展名"]
        case .userAgent: keywords = ["ua", "浏览器", "user agent"]
        case .cron: keywords = ["cron", "定时", "计划", "表达式"]
        case .aes: keywords = ["加密", "解密", "aes", "对称"]
        case .hmac: keywords = ["签名", "hmac", "密钥"]
        case .fileHash: keywords = ["文件", "摘要", "哈希", "md5", "sha"]
        case .idCard: keywords = ["身份证", "校验", "生日"]
        case .luhn: keywords = ["银行卡", "信用卡", "校验位", "luhn"]
        }
        return ([rawValue, title, subtitle] + keywords).joined(separator: " ")
    }
}
