import SwiftUI

/// 标签组配色（v0.8.80）：创建、重色与显示共用同一份调色板——此前创建面板
/// 自带一份、TabBar 只按 colorIndex 取色，两边各写各的。
enum TabGroupPalette {
    static let colors: [Color] = [
        .blue, .purple, .pink, .red, .orange, .yellow,
        .green, .mint, .teal, .cyan, .indigo, .brown,
    ]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// 无障碍名称（菜单项的音/色区分：颜色名 + 序号）。
    static let names: [String] = [
        String(localized: "Blue"), String(localized: "Purple"), String(localized: "Pink"),
        String(localized: "Red"), String(localized: "Orange"), String(localized: "Yellow"),
        String(localized: "Green"), String(localized: "Mint"), String(localized: "Teal"),
        String(localized: "Cyan"), String(localized: "Indigo"), String(localized: "Brown"),
    ]
}
