import Foundation

/// 站点级字体的**纯逻辑**（解析/夹取/档位表；注入在 SiteFontApplier，
/// 持久化在 SiteSettingsStore）。两块设置：
/// - `minFontSize`：最小字号（px）。0 = 关闭，9–24 为有效区间。
/// - `fontFamily`：字体族。空串 = 关闭；注入时**不加 !important**，只作
///   html/body 的默认族——网页自身指定的字体优先（与浏览器"标准字体"
///   设置的语义一致，也不会破坏图标字体）。
/// 站点值为 nil = 跟随全局默认（`defaultMinFontSize` / `defaultFontFamily`）。
struct SiteFont: Equatable {
    var minFontSize: Int
    var fontFamily: String

    static let minRange = 9...24
    /// 设置页与站点弹层共用的字号档位（0 = 关闭）。
    static let sizeChoices: [Int] = [0, 12, 13, 14, 16, 18]
    /// 站点弹层提供的字体族（空串 = 不覆盖）。
    static let familyChoices: [String] = [
        "", "PingFang SC", "Songti SC", "Kaiti SC", "Heiti SC",
        "Hiragino Sans GB", "Georgia", "Times New Roman",
    ]

    static func clampMin(_ value: Int) -> Int {
        value == 0 ? 0 : min(max(value, minRange.lowerBound), minRange.upperBound)
    }

    /// 设置值来自用户/云同步，都会进 CSS 声明——分号/花括号/换行能逃出
    /// `font-family: X` 这条声明（往样式表里塞新声明），一律剥掉。
    static func clampFamily(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.filter { !";{}\n\r".contains($0) }
    }

    /// 解析生效值：站点显式值优先，nil 跟随全局默认。
    static func resolve(siteMin: Int?, siteFamily: String?, defaultMin: Int, defaultFamily: String) -> SiteFont {
        SiteFont(
            minFontSize: clampMin(siteMin ?? defaultMin),
            fontFamily: clampFamily(siteFamily ?? defaultFamily)
        )
    }

    /// 是否需要向页面注入（两项都关 = 零开销）。
    var isActive: Bool { minFontSize > 0 || !fontFamily.isEmpty }
}
