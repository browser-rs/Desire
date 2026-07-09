import AppKit
import SwiftUI

struct DeviceFrameOverlay: View {
    let config: ResponsiveConfig
    let viewportSize: CGSize

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let id = config.selectedPresetID,
               let preset = devicePresets.first(where: { $0.id == id }) {
                switch preset.category {
                case .phone:
                    PhoneBezel()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                case .watch:
                    RoundedRectangle(cornerRadius: viewportSize.width / 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                default:
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        .frame(width: viewportSize.width, height: viewportSize.height)
                }
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    .frame(width: viewportSize.width, height: viewportSize.height)
            }

            Text("\(Int(config.effectiveSize.width))×\(Int(config.effectiveSize.height))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, -18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct PhoneBezel: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.08)
    }
}
