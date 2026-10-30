import Foundation

/// Code128-B 条码编码——纯逻辑（每段宽度按条/空交替，首段是条）。
nonisolated enum BarcodeCore {
    /// Code128 规范宽度表（0–106），每段 6 个数字 = 条/空交替宽度；结束符 13 宽。
    static let patterns: [String] = [
        "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312",
        "132212", "221213", "221312", "231212", "112232", "122132", "122231", "113222",
        "123122", "123221", "223211", "221132", "221231", "213212", "223112", "312131",
        "311222", "321122", "321221", "312212", "322112", "322211", "212123", "212321",
        "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
        "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121",
        "313121", "211331", "231131", "213113", "213311", "213131", "311123", "311321",
        "331121", "312113", "312311", "332111", "314111", "221411", "431111", "111224",
        "111422", "121124", "121421", "141122", "141221", "112214", "112412", "122114",
        "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
        "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112",
        "421211", "212141", "214121", "412121", "111143", "111341", "131141", "114113",
        "114311", "411113", "411311", "113141", "114131", "311141", "411131",
        "211412", "211214", "211232", "2331112",
    ]
    private static let startB = 104
    private static let stop = 106

    /// ASCII 32–126 → Code128-B 编码（含起始符、校验符、结束符）。
    static func encode(_ text: String) -> Result<[Int], ToolboxError> {
        let characters = Array(text)
        guard !characters.isEmpty else { return .failure(ToolboxError(message: "Text is empty")) }
        var codes: [Int] = [startB]
        for character in characters {
            let value = character.asciiValue.map(Int.init) ?? 0
            guard (32...126).contains(value) else {
                return .failure(ToolboxError(message: "Unsupported character: \(character)"))
            }
            codes.append(value - 32)
        }
        var checksum = startB
        for (offset, code) in codes.dropFirst().enumerated() {
            checksum += code * (offset + 1)
        }
        codes.append(checksum % 103)
        codes.append(stop)
        return .success(codes)
    }

    /// 条/空宽度序列（1 段 = 1 个模块宽度）。
    static func widths(for text: String) -> Result<String, ToolboxError> {
        switch encode(text) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let codes):
            var out = ""
            for code in codes {
                out += patterns[code]
            }
            return .success(out)
        }
    }

    /// 规范校验：所有模式宽度之和为 11（结束符 13）。
    static func validatePatterns() -> Bool {
        patterns.enumerated().allSatisfy { index, pattern in
            let expected = index == stop ? 13 : 11
            return pattern.reduce(0) { $0 + Int(String($1))! } == expected
        }
    }
}
