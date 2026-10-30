import Foundation

/// 单位换算（长度/重量/温度/面积/体积/速度/数据/时间）——纯逻辑。
nonisolated enum UnitConvertCore {
    enum Category: String, CaseIterable, Sendable {
        case length
        case weight
        case temperature
        case area
        case volume
        case speed
        case data
        case time
    }

    struct Unit: Identifiable, Sendable {
        var id: String
        var name: String
        var symbol: String
        /// 线性单位到基准单位的倍率；温度单独处理。
        var factor: Double
    }

    static func units(for category: Category) -> [Unit] {
        switch category {
        case .length:
            return [
                .init(id: "m", name: "Meter", symbol: "m", factor: 1),
                .init(id: "km", name: "Kilometer", symbol: "km", factor: 1000),
                .init(id: "cm", name: "Centimeter", symbol: "cm", factor: 0.01),
                .init(id: "mm", name: "Millimeter", symbol: "mm", factor: 0.001),
                .init(id: "mile", name: "Mile", symbol: "mi", factor: 1609.344),
                .init(id: "yard", name: "Yard", symbol: "yd", factor: 0.9144),
                .init(id: "foot", name: "Foot", symbol: "ft", factor: 0.3048),
                .init(id: "inch", name: "Inch", symbol: "in", factor: 0.0254),
                .init(id: "nautical", name: "Nautical Mile", symbol: "nmi", factor: 1852),
            ]
        case .weight:
            return [
                .init(id: "kg", name: "Kilogram", symbol: "kg", factor: 1),
                .init(id: "g", name: "Gram", symbol: "g", factor: 0.001),
                .init(id: "t", name: "Tonne", symbol: "t", factor: 1000),
                .init(id: "lb", name: "Pound", symbol: "lb", factor: 0.45359237),
                .init(id: "oz", name: "Ounce", symbol: "oz", factor: 0.028349523125),
                .init(id: "jin", name: "Jin", symbol: "斤", factor: 0.5),
            ]
        case .temperature:
            return [
                .init(id: "c", name: "Celsius", symbol: "°C", factor: 1),
                .init(id: "f", name: "Fahrenheit", symbol: "°F", factor: 1),
                .init(id: "k", name: "Kelvin", symbol: "K", factor: 1),
            ]
        case .area:
            return [
                .init(id: "m2", name: "Square Meter", symbol: "m²", factor: 1),
                .init(id: "km2", name: "Square Kilometer", symbol: "km²", factor: 1_000_000),
                .init(id: "hectare", name: "Hectare", symbol: "ha", factor: 10_000),
                .init(id: "mu", name: "Mu", symbol: "亩", factor: 666.666_666_7),
                .init(id: "acre", name: "Acre", symbol: "ac", factor: 4046.856_422_4),
                .init(id: "ft2", name: "Square Foot", symbol: "ft²", factor: 0.092_903_04),
            ]
        case .volume:
            return [
                .init(id: "l", name: "Liter", symbol: "L", factor: 1),
                .init(id: "ml", name: "Milliliter", symbol: "mL", factor: 0.001),
                .init(id: "m3", name: "Cubic Meter", symbol: "m³", factor: 1000),
                .init(id: "gallon", name: "Gallon (US)", symbol: "gal", factor: 3.785_411_784),
                .init(id: "pint", name: "Pint (US)", symbol: "pt", factor: 0.473_176_473),
                .init(id: "cup", name: "Cup (US)", symbol: "cup", factor: 0.236_588_236_5),
            ]
        case .speed:
            return [
                .init(id: "mps", name: "Meter/second", symbol: "m/s", factor: 1),
                .init(id: "kph", name: "Kilometer/hour", symbol: "km/h", factor: 0.277_777_778),
                .init(id: "mph", name: "Mile/hour", symbol: "mph", factor: 0.447_04),
                .init(id: "knot", name: "Knot", symbol: "kn", factor: 0.514_444_444),
            ]
        case .data:
            return [
                .init(id: "byte", name: "Byte", symbol: "B", factor: 1),
                .init(id: "bit", name: "Bit", symbol: "bit", factor: 0.125),
                .init(id: "kb", name: "Kilobyte", symbol: "KB", factor: 1024),
                .init(id: "mb", name: "Megabyte", symbol: "MB", factor: 1_048_576),
                .init(id: "gb", name: "Gigabyte", symbol: "GB", factor: 1_073_741_824),
                .init(id: "tb", name: "Terabyte", symbol: "TB", factor: 1_099_511_627_776),
            ]
        case .time:
            return [
                .init(id: "s", name: "Second", symbol: "s", factor: 1),
                .init(id: "min", name: "Minute", symbol: "min", factor: 60),
                .init(id: "hour", name: "Hour", symbol: "h", factor: 3600),
                .init(id: "day", name: "Day", symbol: "d", factor: 86_400),
                .init(id: "week", name: "Week", symbol: "wk", factor: 604_800),
                .init(id: "month", name: "Month (30 days)", symbol: "mo", factor: 2_592_000),
                .init(id: "year", name: "Year (365 days)", symbol: "yr", factor: 31_536_000),
            ]
        }
    }

    static func convert(_ value: Double, from: String, to: String,
                        category: Category) -> Double? {
        let units = units(for: category)
        guard let source = units.first(where: { $0.id == from }),
              let target = units.first(where: { $0.id == to }) else { return nil }
        if category == .temperature {
            let celsius: Double
            switch source.id {
            case "f": celsius = (value - 32) * 5 / 9
            case "k": celsius = value - 273.15
            default: celsius = value
            }
            switch target.id {
            case "f": return celsius * 9 / 5 + 32
            case "k": return celsius + 273.15
            default: return celsius
            }
        }
        guard source.factor != 0 else { return nil }
        return value * source.factor / target.factor
    }
}
