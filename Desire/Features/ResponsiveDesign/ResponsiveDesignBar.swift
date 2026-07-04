import SwiftUI

struct ResponsiveDesignBar: View {
    @Binding var isEnabled: Bool
    @Binding var deviceSize: CGSize
    @State private var customW = 375
    @State private var customH = 667

    var body: some View {
        HStack(spacing: 8) {
            Button("Exit Responsive") {
                isEnabled = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)

            Divider().frame(height: 16)

            ForEach(devicePresets) { preset in
                Button {
                    deviceSize = CGSize(width: CGFloat(preset.width), height: CGFloat(preset.height))
                    customW = preset.width
                    customH = preset.height
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 10))
                        Text(preset.name)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusButton)
                            .fill(deviceSize.width == CGFloat(preset.width) ? Color.accentColor.opacity(0.15) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            HStack(spacing: 4) {
                TextField("W", value: $customW, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
                Text("×").font(.caption).foregroundStyle(.tertiary)
                TextField("H", value: $customH, format: .number)
                    .textFieldStyle(.plain)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11))
            }
            .onChange(of: customW) { _, v in deviceSize.width = CGFloat(max(200, v)) }
            .onChange(of: customH) { _, v in deviceSize.height = CGFloat(max(200, v)) }

            Text("\(Int(deviceSize.width))×\(Int(deviceSize.height))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
