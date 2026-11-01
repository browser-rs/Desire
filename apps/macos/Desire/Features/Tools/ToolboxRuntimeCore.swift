import Foundation

/// 工具箱的"可编程"注册表（v0.8.33 整合批）：纯文本类工具统一
/// `{tool, args}` 入口，供 Agent 工具 `runToolboxTool` 与桥 `/toolbox/run` 调用。
/// 只暴露不碰文件/网络的纯函数；文件类工具（PDF/OCR/改名/压缩）走 UI。
nonisolated enum ToolboxRuntimeCore {

    struct Spec: Sendable, Equatable {
        var name: String
        var summary: String
        var arguments: String
    }

    struct Output: Sendable, Equatable {
        var ok: Bool
        var text: String
    }

    static let specs: [Spec] = [
        .init(name: "base64", summary: "Base64 encode/decode", arguments: "text, mode=encode|decode, urlSafe=true|false"),
        .init(name: "url", summary: "Percent-encode/decode", arguments: "text, mode=encode|decode"),
        .init(name: "hash", summary: "MD5/SHA-1/SHA-256/SHA-512", arguments: "text, algorithm=md5|sha1|sha256|sha512"),
        .init(name: "hmac", summary: "HMAC-SHA256 signature", arguments: "text, key"),
        .init(name: "json", summary: "Format/minify/sort/validate JSON", arguments: "text, mode=format|minify|sort|validate, indent=2"),
        .init(name: "csvToJSON", summary: "CSV to JSON", arguments: "text, delimiter=,"),
        .init(name: "regex", summary: "Test a regular expression", arguments: "text, pattern, caseInsensitive, multiline"),
        .init(name: "regexReplace", summary: "Regex replace with $1 template", arguments: "text, pattern, template, caseInsensitive, multiline"),
        .init(name: "timestamp", summary: "Unix timestamp <-> date", arguments: "value (seconds/milliseconds or date)"),
        .init(name: "numberBases", summary: "Decimal/hex/binary/octal", arguments: "value"),
        .init(name: "units", summary: "Unit conversion", arguments: "value, from, to, category"),
        .init(name: "color", summary: "HEX color components", arguments: "value=#RRGGBB"),
        .init(name: "cron", summary: "Explain a 5-field cron expression", arguments: "expression, count=5"),
        .init(name: "uuid", summary: "Generate UUIDs", arguments: "count=5, v7=true|false"),
        .init(name: "password", summary: "Generate a strong password", arguments: "length=20, digits, symbols, uppercase, avoidAmbiguous"),
        .init(name: "random", summary: "Random strings or integers", arguments: "mode=string|integer, length, count, alphabet, min, max, unique"),
        .init(name: "base32", summary: "Base32 encode/decode", arguments: "text, mode=encode|decode"),
        .init(name: "totp", summary: "TOTP code from a Base32 secret", arguments: "secret, algorithm, digits, period"),
        .init(name: "jsonPath", summary: "Query JSON with JSONPath", arguments: "json, path"),
        .init(name: "zhConvert", summary: "Simplified/Traditional conversion", arguments: "text, direction=toTraditional|toSimplified"),
        .init(name: "pinyin", summary: "Pinyin with tone marks/plain/initials", arguments: "text, style=toneMarks|plain|initials"),
        .init(name: "zhTypography", summary: "Chinese typography cleanup", arguments: "text"),
        .init(name: "contrast", summary: "WCAG contrast ratio", arguments: "foreground=#RRGGBB, background=#RRGGBB"),
        .init(name: "chmod", summary: "Octal/symbolic permissions", arguments: "value=755|rwxr-xr-x"),
        .init(name: "floatBits", summary: "IEEE 754 bit pattern", arguments: "value, width=32|64"),
        .init(name: "ulid", summary: "Generate ULIDs", arguments: "count=5"),
        .init(name: "text", summary: "Text case/lines/stats", arguments: "text, operation=upper|lower|title|snake|kebab|sort|sortDesc|dedupe|reverse|numbered|stats"),
        .init(name: "diff", summary: "Line diff", arguments: "old, new"),
        .init(name: "xml", summary: "Format/minify/validate XML", arguments: "text, mode=format|minify|validate"),
        .init(name: "sql", summary: "Format SQL", arguments: "text"),
        .init(name: "urlParse", summary: "Parse URL components", arguments: "url"),
        .init(name: "cidr", summary: "IPv4/CIDR info", arguments: "value=192.168.1.0/24"),
        .init(name: "httpStatus", summary: "Look up HTTP status codes", arguments: "code or query"),
        .init(name: "mime", summary: "Extension <-> MIME", arguments: "value"),
        .init(name: "userAgent", summary: "Parse a User-Agent", arguments: "value"),
        .init(name: "base58", summary: "Base58 encode/decode", arguments: "text, mode=encode|decode"),
        .init(name: "crc32", summary: "CRC-32 checksum", arguments: "text"),
        .init(name: "sha3", summary: "SHA3-256/SHA3-512", arguments: "text, variant=sha3_256|sha3_512"),
        .init(name: "markdown", summary: "Markdown to HTML", arguments: "text"),
        .init(name: "lorem", summary: "Placeholder text", arguments: "count=3, chinese=true|false"),
        .init(name: "dataURI", summary: "Text to data: URI", arguments: "text, mime=text/plain"),
        .init(name: "width", summary: "Full-width/half-width conversion", arguments: "text, mode=full|half"),
        .init(name: "aes", summary: "AES-GCM encrypt/decrypt", arguments: "text, password, mode=encrypt|decrypt"),
        .init(name: "luhn", summary: "Card number Luhn check", arguments: "value, mode=validate|checkDigit"),
        .init(name: "idCard", summary: "Chinese 18-digit ID check", arguments: "value"),
        .init(name: "morse", summary: "Morse code encode/decode", arguments: "text, mode=encode|decode"),
        .init(name: "roman", summary: "Roman numerals", arguments: "value, mode=toRoman|fromRoman"),
        .init(name: "excelColumn", summary: "Excel column letters/number", arguments: "value"),
    ]

    static let toolNames: [String] = specs.map(\.name)

    static func run(tool: String, args: [String: String]) -> Output {
        switch tool {
        case "base64":
            return textIO(args, encode: { ToolboxCore.base64Encode($0, urlSafe: bool(args, "urlSafe")) },
                          decode: { ToolboxCore.base64Decode($0) })
        case "url":
            return textIO(args, encode: { ToolboxCore.urlEncode($0) },
                          decode: { ToolboxCore.urlDecode($0) })
        case "hash":
            let algorithm = ToolsCrypto.Algorithm(rawValue: value(args, "algorithm", "sha256")) ?? .sha256
            return ok(ToolsCrypto.hash(value(args, "text"), algorithm: algorithm))
        case "hmac":
            return ok(ToolsCrypto.hmacSHA256(value(args, "text"), key: value(args, "key")))
        case "json":
            let mode = value(args, "mode", "format")
            if mode == "validate" {
                if let failure = JSONFormatterCore.validate(value(args, "text")) {
                    return fail("\(failure.message) (line \(failure.line), column \(failure.column))")
                }
                return ok("Valid JSON")
            }
            let result = JSONFormatterCore.format(
                value(args, "text"),
                indent: int(args, "indent", 2),
                sortKeys: mode == "sort",
                minify: mode == "minify")
            switch result {
            case .success(let output): return ok(output)
            case .failure(let failure): return fail(failure.message)
            }
        case "csvToJSON":
            let delimiter = value(args, "delimiter", ",").first ?? ","
            switch CSVJSONCore.csvToJSON(value(args, "text"), delimiter: delimiter) {
            case .success(let output): return ok(output)
            case .failure(let error): return fail(error.message)
            }
        case "regex":
            let result = RegexToolCore.matches(
                pattern: value(args, "pattern"), in: value(args, "text"),
                caseInsensitive: bool(args, "caseInsensitive"),
                multiline: bool(args, "multiline"))
            switch result {
            case .failure(let error): return fail(error.message)
            case .success(let matches):
                let rows = matches.map { ["text": $0.text, "groups": $0.groups] }
                guard let data = try? JSONSerialization.data(withJSONObject: rows,
                                                             options: [.prettyPrinted]),
                      let output = String(data: data, encoding: .utf8) else {
                    return fail("could not encode matches")
                }
                return ok(output)
            }
        case "regexReplace":
            switch RegexToolCore.replace(
                pattern: value(args, "pattern"), template: value(args, "template"),
                in: value(args, "text"),
                caseInsensitive: bool(args, "caseInsensitive"),
                multiline: bool(args, "multiline")) {
            case .success(let output): return ok(output)
            case .failure(let error): return fail(error.message)
            }
        case "timestamp":
            return timestamp(value(args, "value"))
        case "numberBases":
            guard let number = ToolboxCore.parseInteger(value(args, "value")) else {
                return fail("not a valid integer")
            }
            let bases = ToolboxCore.bases(for: number)
            return ok("decimal: \(bases.decimal)\nhex: \(bases.hexadecimal)\nbinary: \(bases.binary)\noctal: \(bases.octal)")
        case "units":
            guard let category = UnitConvertCore.Category(rawValue: value(args, "category", "length")) else {
                return fail("unknown category")
            }
            guard let number = Double(value(args, "value")) else {
                return fail("not a number")
            }
            guard let output = UnitConvertCore.convert(
                number, from: value(args, "from"), to: value(args, "to"), category: category) else {
                return fail("unknown unit")
            }
            return ok(String(format: "%.10g", output))
        case "color":
            guard let parsed = ToolboxCore.parseHexColor(value(args, "value")) else {
                return fail("not a HEX color")
            }
            return ok("hex: \(ToolboxCore.hexColor(red: parsed.red, green: parsed.green, blue: parsed.blue, alpha: parsed.alpha))\n"
                + "rgb: \(parsed.red), \(parsed.green), \(parsed.blue)\nalpha: \(parsed.alpha)")
        case "cron":
            return cron(value(args, "expression"), count: int(args, "count", 5))
        case "uuid":
            let count = max(1, min(int(args, "count", 5), 100))
            let useV7 = bool(args, "v7", true)
            let values = (0..<count).map { _ in
                useV7 ? UUIDV7Core.generate().uuidString : UUID().uuidString
            }
            return ok(values.joined(separator: "\n"))
        case "password":
            return ok(ToolboxCore.generatePassword(
                length: int(args, "length", 20),
                useDigits: bool(args, "digits", true),
                useSymbols: bool(args, "symbols", true),
                useUppercase: bool(args, "uppercase", true),
                useAvoidAmbiguous: bool(args, "avoidAmbiguous")))
        case "random":
            return random(args)
        case "base32":
            return textIOOptional(args, encode: { Base32Core.encode(Data($0.utf8)) },
                                  decode: { Base32Core.decode($0).map { String(decoding: $0, as: UTF8.self) } })
        case "totp":
            guard let output = TOTPCore.code(
                secret: value(args, "secret"),
                period: int(args, "period", 30),
                digits: int(args, "digits", 6),
                algorithm: TOTPCore.Algorithm(rawValue: value(args, "algorithm", "sha1")) ?? .sha1) else {
                return fail("invalid Base32 secret")
            }
            return ok(output)
        case "jsonPath":
            guard let data = value(args, "json").data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return fail("invalid JSON")
            }
            guard let values = JSONPathCore.query(root, path: value(args, "path", "$")) else {
                return fail("invalid JSONPath expression")
            }
            return ok(JSONPathCore.display(values) ?? "[]")
        case "zhConvert":
            if value(args, "direction", "toTraditional") == "toSimplified" {
                return ok(ZhTextCore.traditionalToSimplified(value(args, "text")))
            }
            return ok(ZhTextCore.simplifiedToTraditional(value(args, "text")))
        case "pinyin":
            let style = ZhTextCore.PinyinStyle(rawValue: value(args, "style", "toneMarks")) ?? .toneMarks
            return ok(ZhTextCore.pinyin(value(args, "text"), style: style))
        case "zhTypography":
            return ok(ZhTextCore.typography(value(args, "text")))
        case "contrast":
            guard let foreground = ContrastCore.parseHex(value(args, "foreground")),
                  let background = ContrastCore.parseHex(value(args, "background")) else {
                return fail("colors must be #RRGGBB")
            }
            let ratio = ContrastCore.ratio(foreground, background)
            let rating = ContrastCore.rating(ratio)
            return ok(String(format: "%.2f : 1", ratio)
                + "\nAA normal: \(rating.aaNormal)\nAA large: \(rating.aaLarge)"
                + "\nAAA normal: \(rating.aaaNormal)\nAAA large: \(rating.aaaLarge)"
                + "\nsuggested text: \(ContrastCore.bestTextColor(on: background))")
        case "chmod":
            guard let permissions = ChmodCore.parseOctal(value(args, "value"))
                ?? ChmodCore.parseSymbolic(value(args, "value")) else {
                return fail("not a valid octal or symbolic permission")
            }
            return ok("octal: \(ChmodCore.octalString(permissions))"
                + "\nsymbolic: \(ChmodCore.symbolicString(permissions))"
                + "\nabsolute: \(ChmodCore.absoluteSymbolic(permissions))")
        case "floatBits":
            return floatBits(args)
        case "ulid":
            let count = max(1, min(int(args, "count", 5), 100))
            var generator = SystemRandomNumberGenerator()
            let values = (0..<count).compactMap { _ -> String? in
                let randomness = (0..<10).map { _ in UInt8.random(in: 0...255, using: &generator) }
                return ULIDCore.generate(randomness: randomness)
            }
            return ok(values.joined(separator: "\n"))
        case "text":
            return textOperation(args)
        case "diff":
            return diff(value(args, "old"), value(args, "new"))
        case "xml":
            return xml(args)
        case "sql":
            return ok(SQLToolCore.format(value(args, "text")))
        case "urlParse":
            guard let info = URLParseCore.parse(value(args, "url")) else {
                return fail("could not parse URL")
            }
            var lines = ["scheme: \(info.scheme)", "host: \(info.host)",
                         "path: \(info.path)"]
            if let port = info.port { lines.append("port: \(port)") }
            if !info.user.isEmpty { lines.append("user: \(info.user)") }
            for item in info.query { lines.append("query.\(item.name): \(item.value)") }
            if !info.fragment.isEmpty { lines.append("fragment: \(info.fragment)") }
            return ok(lines.joined(separator: "\n"))
        case "cidr":
            switch CIDRCore.parse(value(args, "value")) {
            case .failure(let error): return fail(error.message)
            case .success(let info):
                return ok("network: \(info.network)/\(info.prefix)\nbroadcast: \(info.broadcast)"
                    + "\nmask: \(info.mask)\nhosts: \(info.firstHost) – \(info.lastHost)"
                    + "\ncount: \(info.hostCount)\nprivate: \(info.isPrivate)")
            }
        case "httpStatus":
            let query = value(args, "code")
            if let code = Int(query), let entry = HTTPStatusCore.lookup(code) {
                return ok("\(entry.code) \(entry.title)\n\(entry.description)")
            }
            let results = HTTPStatusCore.search(query)
            guard !results.isEmpty else { return fail("no matching status code") }
            return ok(results.map { "\($0.code) \($0.title)" }.joined(separator: "\n"))
        case "mime":
            let raw = value(args, "value")
            if raw.contains("/") {
                let extensions = MIMECore.extensions(forMIME: raw)
                return extensions.isEmpty ? fail("unknown MIME type") : ok(extensions.joined(separator: ", "))
            }
            guard let mime = MIMECore.mime(forExtension: raw) else {
                return fail("unknown extension")
            }
            return ok(mime)
        case "userAgent":
            guard let info = UACore.parse(value(args, "value")) else {
                return fail("could not parse User-Agent")
            }
            return ok("browser: \(info.browser) \(info.browserVersion)\nos: \(info.os)\nengine: \(info.engine)")
        case "base58":
            return textIO(args, encode: { Base58Core.encode($0) },
                          decode: { Base58Core.decode($0) })
        case "crc32":
            return ok(CRC32Core.hex(Data(value(args, "text").utf8)))
        case "sha3":
            let variant: SHA3Core.Variant = value(args, "variant", "sha3_256") == "sha3_512"
                ? .sha3_512 : .sha3_256
            return ok(SHA3Core.hex(Data(value(args, "text").utf8), variant: variant))
        case "markdown":
            return ok(MarkdownHTMLCore.html(value(args, "text")))
        case "lorem":
            let paragraphs = LoremCore.paragraphs(count: int(args, "count", 3),
                                                  chinese: bool(args, "chinese"))
            return ok(paragraphs.joined(separator: "\n\n"))
        case "dataURI":
            return ok(DataURICore.make(text: value(args, "text"),
                                       mime: value(args, "mime", "text/plain")))
        case "width":
            let text = value(args, "text")
            return ok(value(args, "mode", "full") == "half"
                ? WidthCore.toHalfWidth(text) : WidthCore.toFullWidth(text))
        case "aes":
            let text = value(args, "text")
            let password = value(args, "password")
            if value(args, "mode", "encrypt") == "decrypt" {
                switch AESCrypto.decrypt(text, password: password) {
                case .success(let output): return ok(output)
                case .failure(let error): return fail(error.message)
                }
            }
            switch AESCrypto.encrypt(text, password: password) {
            case .success(let output): return ok(output)
            case .failure(let error): return fail(error.message)
            }
        case "luhn":
            if value(args, "mode", "validate") == "checkDigit" {
                switch LuhnCore.checkDigit(for: value(args, "value")) {
                case .success(let digit): return ok("\(digit)")
                case .failure(let error): return fail(error.message)
                }
            }
            switch LuhnCore.validate(value(args, "value")) {
            case .success(let valid): return ok(valid ? "valid" : "invalid")
            case .failure(let error): return fail(error.message)
            }
        case "idCard":
            switch IDCardCore.validate(value(args, "value")) {
            case .success(let info):
                return ok("birth: \(info.birthDate)\ngender: \(info.gender)\ncheck: \(info.checkDigit)")
            case .failure(let error): return fail(error.message)
            }
        case "morse":
            if value(args, "mode", "encode") == "decode" {
                switch MorseCore.decode(value(args, "text")) {
                case .success(let output): return ok(output)
                case .failure(let error): return fail(error.message)
                }
            }
            return ok(MorseCore.encode(value(args, "text")))
        case "roman":
            if value(args, "mode", "toRoman") == "fromRoman" {
                guard let number = RomanCore.fromRoman(value(args, "value")) else {
                    return fail("not a valid Roman numeral")
                }
                return ok("\(number)")
            }
            guard let number = Int(value(args, "value")),
                  let roman = RomanCore.toRoman(number) else {
                return fail("number must be 1–3999")
            }
            return ok(roman)
        case "excelColumn":
            let raw = value(args, "value")
            if let number = Int(raw) {
                guard let letters = ExcelColumnCore.toLetters(number) else {
                    return fail("number out of range")
                }
                return ok(letters)
            }
            guard let number = ExcelColumnCore.fromLetters(raw) else {
                return fail("not valid column letters")
            }
            return ok("\(number)")
        default:
            return fail("unknown tool: \(tool)")
        }
    }

    // MARK: - 分支实现

    private static func textIO(_ args: [String: String],
                               encode: (String) -> String,
                               decode: (String) -> Result<String, ToolboxError>) -> Output {
        let text = value(args, "text")
        if value(args, "mode", "encode") == "decode" {
            switch decode(text) {
            case .success(let output): return ok(output)
            case .failure(let error): return fail(error.message)
            }
        }
        return ok(encode(text))
    }

    private static func textIOOptional(_ args: [String: String],
                                       encode: (String) -> String,
                                       decode: (String) -> String?) -> Output {
        let text = value(args, "text")
        if value(args, "mode", "encode") == "decode" {
            guard let output = decode(text) else { return fail("invalid input") }
            return ok(output)
        }
        return ok(encode(text))
    }

    private static func timestamp(_ raw: String) -> Output {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let date: Date
        let unit: String
        if let parsed = ToolboxCore.parseUnix(trimmed) {
            date = parsed.date
            unit = parsed.unit == .milliseconds ? "milliseconds" : "seconds"
        } else if let parsed = ISO8601DateFormatter().date(from: trimmed) {
            date = parsed
            unit = "date"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard let parsed = formatter.date(from: trimmed) else {
                return fail("not a timestamp or yyyy-MM-dd HH:mm:ss date")
            }
            date = parsed
            unit = "date"
        }
        return ok("input: \(unit)\nISO8601: \(ToolboxCore.iso8601(date))"
            + "\nlocal: \(ToolboxCore.formatted(date))"
            + "\nseconds: \(ToolboxCore.unixSeconds(date))"
            + "\nmilliseconds: \(ToolboxCore.unixMilliseconds(date))")
    }

    private static func cron(_ expression: String, count: Int) -> Output {
        switch CronCore.nextRuns(expression, count: max(1, min(count, 50))) {
        case .failure(let error): return fail(error.message)
        case .success(let dates):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return ok(dates.map { formatter.string(from: $0) }.joined(separator: "\n"))
        }
    }

    private static func random(_ args: [String: String]) -> Output {
        if value(args, "mode", "string") == "integer" {
            let values = RandomCore.integers(
                min: int(args, "min", 0), max: int(args, "max", 100),
                count: int(args, "count", 1), unique: bool(args, "unique"))
            return ok(values.map(String.init).joined(separator: "\n"))
        }
        let values = RandomCore.strings(
            length: int(args, "length", 12),
            alphabet: value(args, "alphabet", "abcdefghijklmnopqrstuvwxyz0123456789"),
            count: int(args, "count", 1))
        return ok(values.joined(separator: "\n"))
    }

    private static func floatBits(_ args: [String: String]) -> Output {
        let width = int(args, "width", 32)
        let raw = value(args, "value")
        if raw.lowercased().hasPrefix("0x") {
            guard let bits = FloatBitsCore.parseHex(raw, width: width) else {
                return fail("invalid hex bits")
            }
            let value = width == 32
                ? FloatBitsCore.float32(fromBits: UInt32(truncatingIfNeeded: bits))
                : FloatBitsCore.float64(fromBits: bits)
            return ok(String(format: "decimal: %.17g\nhex: %@", value,
                             FloatBitsCore.hex(bits, width: width)))
        }
        guard let value = FloatBitsCore.parseDecimal(raw) else {
            return fail("not a number")
        }
        let bits = width == 32
            ? UInt64(FloatBitsCore.float32Bits(value))
            : FloatBitsCore.float64Bits(value)
        let fields = width == 32
            ? FloatBitsCore.decompose32(UInt32(truncatingIfNeeded: bits))
            : FloatBitsCore.decompose64(bits)
        return ok("hex: \(FloatBitsCore.hex(bits, width: width))"
            + "\nlittle-endian: \(FloatBitsCore.hex(FloatBitsCore.littleEndianBits(bits, width: width), width: width))"
            + "\nsign: \(fields.negative ? 1 : 0)\nexponent: \(fields.exponent) (bias \(fields.bias))"
            + "\nmantissa: \(String(fields.mantissa, radix: 16))")
    }

    private static func textOperation(_ args: [String: String]) -> Output {
        let text = value(args, "text")
        switch value(args, "operation", "upper") {
        case "lower": return ok(ToolboxCore.lower(text))
        case "title": return ok(ToolboxCore.titleCase(text))
        case "snake": return ok(ToolboxCore.snakeCase(text))
        case "kebab": return ok(ToolboxCore.kebabCase(text))
        case "sort": return ok(ToolboxCore.processLines(text, mode: .sort))
        case "sortDesc": return ok(ToolboxCore.processLines(text, mode: .sortDescending))
        case "dedupe": return ok(ToolboxCore.processLines(text, mode: .dedupe))
        case "reverse": return ok(ToolboxCore.processLines(text, mode: .reverse))
        case "numbered": return ok(ToolboxCore.processLines(text, mode: .numbered))
        case "stats":
            let stats = ToolboxCore.stats(text)
            return ok("characters: \(stats.characters)\nwords: \(stats.words)\nlines: \(stats.lines)")
        default: return ok(ToolboxCore.upper(text))
        }
    }

    private static func diff(_ old: String, _ new: String) -> Output {
        let rows = DiffCore.diff(old: old, new: new)
        let stats = DiffCore.stats(rows)
        let body = rows.map { row -> String in
            switch row.kind {
            case .equal: return "  " + row.text
            case .insert: return "+ " + row.text
            case .delete: return "- " + row.text
            }
        }.joined(separator: "\n")
        return ok(body + "\n\n+\(stats.inserted) -\(stats.deleted) =\(stats.equal)")
    }

    private static func xml(_ args: [String: String]) -> Output {
        let text = value(args, "text")
        switch value(args, "mode", "format") {
        case "validate":
            if let error = XMLCore.validate(text) { return fail(error) }
            return ok("valid XML")
        case "minify":
            switch XMLCore.minify(text) {
            case .success(let output): return ok(output)
            case .failure(let error): return fail(error.message)
            }
        default:
            switch XMLCore.format(text) {
            case .success(let output): return ok(output)
            case .failure(let error): return fail(error.message)
            }
        }
    }

    // MARK: - 参数

    private static func value(_ args: [String: String], _ key: String,
                              _ defaultValue: String = "") -> String {
        args[key] ?? defaultValue
    }

    private static func int(_ args: [String: String], _ key: String,
                            _ defaultValue: Int) -> Int {
        args[key].flatMap(Int.init) ?? defaultValue
    }

    private static func bool(_ args: [String: String], _ key: String,
                             _ defaultValue: Bool = false) -> Bool {
        guard let raw = args[key]?.lowercased() else { return defaultValue }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    private static func ok(_ text: String) -> Output {
        Output(ok: true, text: text)
    }

    private static func fail(_ message: String) -> Output {
        Output(ok: false, text: "Error: " + message)
    }
}
