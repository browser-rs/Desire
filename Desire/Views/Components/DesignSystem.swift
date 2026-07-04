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
}
