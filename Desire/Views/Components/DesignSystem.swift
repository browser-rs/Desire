import SwiftUI

// MARK: - Corner Radius

extension CGFloat {
    static let radiusButton: CGFloat = 6
    static let radiusCard: CGFloat = 10
    static let radiusPopover: CGFloat = 12
    static let radiusBadge: CGFloat = 4
}

// MARK: - Shadow

extension View {
    func shadowSubtle() -> some View {
        shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    func shadowElevated() -> some View {
        shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    func shadowProminent() -> some View {
        shadow(color: .black.opacity(0.18), radius: 20, y: 4)
    }
}

// MARK: - Animation

extension Animation {
    static let hoverFast = Animation.easeOut(duration: 0.1)
    static let transitionNormal = Animation.easeInOut(duration: 0.2)
    static let transitionSlow = Animation.smooth(duration: 0.3)
    /// 浮层进出场（toast/通知条）：轻微回弹，比 easeInOut 更有生命力。
    static let overlaySpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// 控件状态（开关/高亮/尺寸变化）：小位移快速跟随。
    static let controlSpring = Animation.spring(response: 0.25, dampingFraction: 0.85)
    /// 全窗口级布局变化（概览开关/分屏出现/侧栏）：从容但有落地感。
    static let layoutSpring = Animation.spring(response: 0.38, dampingFraction: 0.88)
}

// MARK: - Standard Transitions

// .transition 只定义"动什么"，动画由触发状态变化的 withAnimation /
// .animation(value:) 提供——过去一半浮层没挂动画，同样写了 transition
// 的条子有的滑入有的瞬跳。这三个包装把曲线与锚定值绑在一起，杜绝漏配。

extension View {
    /// 底部浮起（toast 类）。`visible` 是该浮层的显隐状态。
    @ViewBuilder
    func overlayBottomTransition(visible: Bool) -> some View {
        transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.overlaySpring, value: visible)
    }

    /// 顶部落下的通知条（notice bars / 视频拦截 toast）。
    @ViewBuilder
    func overlayTopTransition(visible: Bool) -> some View {
        transition(.move(edge: .top).combined(with: .opacity))
            .animation(.overlaySpring, value: visible)
    }

    /// 大面板布局（概览/分屏/侧栏）。
    func layoutTransition(value: Bool) -> some View {
        animation(.layoutSpring, value: value)
    }
}
