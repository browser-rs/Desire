import SwiftUI

/// 应用强调色（设置 ▸ 外观 ▸ 强调色）。
///
/// 为什么需要它：`Color.accentColor` 既不跟随 macOS 系统强调色、也不跟随
/// Desire 设置里的强调色——实测在 `.tint(purple)` 环境里它仍返回 SwiftUI 默认
/// 蓝 `#009DFF`。`.tint` 只对系统控件生效，所以自绘的胶囊/描边/图标/渐变都会
/// 一直是默认蓝（用户报的"主题色在标签栏没应用"就是这个）。
///
/// 约定：
/// - 需要 ShapeStyle 的地方直接写 `.tint` / `.tint.opacity(x)`（不需要本环境值）。
/// - **需要 `Color` 值**的地方（渐变颜色数组、`Color` 类型属性/返回值、
///   `.shadow(color:)`、`Color.clear` 混用的三目）读本环境值 `\.appAccent`。
/// - **每个独立 scene / 独立 `NSHostingView` 根视图都要挂一次 `appAccent(_:)`**：
///   tint 与环境值都不跨窗口（设置窗、Agent 浮窗、截图层、插件窗、引导页）。
/// - 禁止再写 `Color.accentColor`。
/// 全局镜像：给**拿不到 `Settings`**的窗口用（插件窗单例、截图工具条等）。
/// 主窗口与设置改变时由 `Settings.accentColor.didSet` 更新；这些窗口在构建
/// 根视图时读一次即可（瞬态窗口，不要求跟随热更新）。
@MainActor
enum AppAccent {
    static var current: Color = .blue
}

extension EnvironmentValues {
    @Entry var appAccent: Color = .accentColor
}

extension View {
    /// 把一个窗口/面板的根视图接到应用强调色上：`.tint` 服务系统控件与 `.tint`
    /// 样式，`\.appAccent` 服务需要 `Color` 的场合。
    func appAccent(_ color: Color) -> some View {
        self.tint(color).environment(\.appAccent, color)
    }
}
