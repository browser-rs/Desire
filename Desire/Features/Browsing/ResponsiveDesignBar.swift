import SwiftUI

struct DevicePreset: Identifiable {
    let id = UUID()
    let name: String
    let width: Int
    let height: Int
    let icon: String
}

let devicePresets: [DevicePreset] = [
    .init(name: "iPhone SE", width: 375, height: 667, icon: "iphone.gen2"),
    .init(name: "iPhone 14 Pro", width: 390, height: 844, icon: "iphone.gen3"),
    .init(name: "iPhone 14 Pro Max", width: 430, height: 932, icon: "iphone.gen3"),
    .init(name: "iPad 10", width: 820, height: 1180, icon: "ipad.gen2"),
    .init(name: "iPad Pro 12.9\"", width: 1024, height: 1366, icon: "ipad.pro.gen2"),
]

struct ResponsiveDesignBar: View {
    @Binding var isEnabled: Bool
    @Binding var deviceSize: CGSize
    @State private var customW = 375
    @State private var customH = 667

    var body: some View {
        HStack(spacing: 8) {
            Button(isEnabled ? "退出" : "响应式") {
                isEnabled.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? Color.accentColor : .secondary)

            if isEnabled {
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
                            RoundedRectangle(cornerRadius: 4)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
