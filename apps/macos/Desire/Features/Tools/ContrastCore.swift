import Foundation

/// 颜色对比度与色板（v0.8.33 设计批）：WCAG 相对亮度/比值、AA/AAA 分级、
/// 黑白文字建议、HSL 旋转色板。纯 Foundation、进 tests/run.sh。
nonisolated enum ContrastCore {

    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
    }

    struct Rating: Equatable, Sendable {
        var aaNormal: Bool
        var aaLarge: Bool
        var aaaNormal: Bool
        var aaaLarge: Bool
    }

    static func parseHex(_ text: String) -> RGB? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.allSatisfy(\.isHexDigit) else { return nil }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6 || value.count == 8 else { return nil }
        func component(_ start: Int) -> Double {
            let begin = value.index(value.startIndex, offsetBy: start)
            let end = value.index(begin, offsetBy: 2)
            return Double(Int(value[begin..<end], radix: 16) ?? 0) / 255
        }
        return RGB(red: component(0), green: component(2), blue: component(4))
    }

    static func hex(_ color: RGB) -> String {
        func channel(_ value: Double) -> Int {
            min(255, max(0, Int((value * 255).rounded())))
        }
        return String(format: "#%02X%02X%02X",
                      channel(color.red), channel(color.green), channel(color.blue))
    }

    /// WCAG 相对亮度（sRGB → 线性）。
    static func luminance(_ color: RGB) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    static func ratio(_ first: RGB, _ second: RGB) -> Double {
        let a = luminance(first)
        let b = luminance(second)
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func rating(_ ratio: Double) -> Rating {
        Rating(aaNormal: ratio >= 4.5, aaLarge: ratio >= 3,
               aaaNormal: ratio >= 7, aaaLarge: ratio >= 4.5)
    }

    static func bestTextColor(on background: RGB) -> String {
        let black = RGB(red: 0, green: 0, blue: 0)
        let white = RGB(red: 1, green: 1, blue: 1)
        return ratio(black, background) >= ratio(white, background)
            ? hex(black) : hex(white)
    }

    /// 基色 + 互补 + 类似色（±30°）+ 三分色（+120°/+240°）。
    static func palette(base: RGB) -> [String] {
        [0, 180, -30, 30, 120, 240].map { hex(rotated(base, degrees: $0)) }
    }

    static func rotated(_ color: RGB, degrees: Double) -> RGB {
        var hsl = hsl(from: color)
        hsl.hue = (hsl.hue + degrees).truncatingRemainder(dividingBy: 360)
        if hsl.hue < 0 { hsl.hue += 360 }
        return rgb(from: hsl)
    }

    // MARK: - HSL

    private struct HSL {
        var hue: Double
        var saturation: Double
        var lightness: Double
    }

    private static func hsl(from color: RGB) -> HSL {
        let maximum = max(color.red, max(color.green, color.blue))
        let minimum = min(color.red, min(color.green, color.blue))
        let lightness = (maximum + minimum) / 2
        guard maximum != minimum else { return HSL(hue: 0, saturation: 0, lightness: lightness) }
        let delta = maximum - minimum
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)
        var hue: Double
        if maximum == color.red {
            hue = (color.green - color.blue) / delta + (color.green < color.blue ? 6 : 0)
        } else if maximum == color.green {
            hue = (color.blue - color.red) / delta + 2
        } else {
            hue = (color.red - color.green) / delta + 4
        }
        return HSL(hue: hue * 60, saturation: saturation, lightness: lightness)
    }

    private static func rgb(from hsl: HSL) -> RGB {
        guard hsl.saturation > 0 else {
            return RGB(red: hsl.lightness, green: hsl.lightness, blue: hsl.lightness)
        }
        let q = hsl.lightness < 0.5
            ? hsl.lightness * (1 + hsl.saturation)
            : hsl.lightness + hsl.saturation - hsl.lightness * hsl.saturation
        let p = 2 * hsl.lightness - q
        let h = hsl.hue / 360
        func channel(_ offset: Double) -> Double {
            var t = h + offset
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGB(red: channel(1.0 / 3), green: channel(0), blue: channel(-1.0 / 3))
    }
}
