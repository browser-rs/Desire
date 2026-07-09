import SwiftUI

struct ResponsiveDesignBar: View {
    @Binding var config: ResponsiveConfig
    let responsiveStore: ResponsiveDesignStore
    var onScreenshot: (() -> Void)?
    @State private var selectedCategory: DeviceCategory = .phone
    @State private var customW = 375
    @State private var customH = 667

    var body: some View {
        HStack(spacing: 8) {
            Button("← Exit") {
                config.isEnabled = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)

            Divider().frame(height: 16)

            ForEach(DeviceCategory.allCases, id: \.self) { cat in
                Button {
                    selectedCategory = cat
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: cat.icon)
                            .font(.system(size: 10))
                        Text(cat.label)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(selectedCategory == cat ? Color.accentColor.opacity(0.15) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            let presets = responsiveStore.presets(for: selectedCategory)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(presets) { preset in
                        Button {
                            config.selectedPresetID = preset.id
                            customW = preset.width
                            customH = preset.height
                        } label: {
                            Text(preset.name)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: .radiusButton)
                                        .fill(config.selectedPresetID == preset.id ? Color.accentColor.opacity(0.15) : .clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 200)

            Divider().frame(height: 16)

            Button {
                config.orientation = config.orientation == .portrait ? .landscape : .portrait
            } label: {
                Image(systemName: config.orientation == .portrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Toggle Orientation")

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
            .onChange(of: customW) { _, v in
                config.selectedPresetID = nil
                config.customWidth = max(200, v)
            }
            .onChange(of: customH) { _, v in
                config.selectedPresetID = nil
                config.customHeight = max(200, v)
            }

            Text("\(Int(config.effectiveSize.width))×\(Int(config.effectiveSize.height))")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                onScreenshot?()
            } label: {
                Label("Screenshot", systemImage: "camera.viewfinder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Button {
                config.showRulers.toggle()
            } label: {
                Label("Rulers", systemImage: "ruler")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(config.showRulers ? Color.accentColor : .secondary)

            Button {
                config.touchSimulationEnabled.toggle()
            } label: {
                Label("Touch", systemImage: "hand.point.up")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(config.touchSimulationEnabled ? Color.accentColor : .secondary)

            Button {
                config.showMediaQueryInspector.toggle()
            } label: {
                Label("Media Q", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(config.showMediaQueryInspector ? Color.accentColor : .secondary)

            Button {
                let all: [ThrottlePreset] = [.none, .slow3G, .fast3G, .offline]
                let idx = all.firstIndex(of: config.networkThrottle) ?? 0
                config.networkThrottle = all[(idx + 1) % all.count]
            } label: {
                HStack(spacing: 3) {
                    Circle()
                        .fill(config.networkThrottle == .none ? Color.gray.opacity(0.3)
                              : config.networkThrottle == .offline ? Color.red : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(config.networkThrottle.label)
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(config.networkThrottle == .none ? Color.clear
                              : config.networkThrottle == .offline ? Color.red.opacity(0.1) : Color.orange.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear {
            let s = config.effectiveSize
            customW = Int(s.width)
            customH = Int(s.height)
        }
    }
}
