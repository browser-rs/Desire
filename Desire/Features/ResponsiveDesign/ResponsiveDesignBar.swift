import SwiftUI

/// 响应式模式顶部工具条 — Chrome DevTools 单行范式。
/// 左起：完成（退出）│ 设备选择菜单 │ 方向 │ 尺寸输入 │
/// 右侧：元信息（断点 · DPR · UA）│ 触摸 │ 标尺 │ 媒体查询 │ 截屏。
struct ResponsiveDesignBar: View {
    @Binding var config: ResponsiveConfig
    let responsiveStore: ResponsiveDesignStore
    var onScreenshot: (() -> Void)?
    var mediaQueries: [MediaQueryItem]

    @State private var selectedCategory: DeviceCategory = .phone

    var body: some View {
        HStack(spacing: 12) {
            // ── 完成（退出）──
            Button {
                config.isEnabled = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text("完成")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .help("退出响应式模式")

            .div

            // ── 设备选择菜单 ──
            Menu {
                ForEach(DeviceCategory.allCases, id: \.self) { cat in
                    Section(cat.label) {
                        ForEach(responsiveStore.presets(for: cat)) { preset in
                            Button {
                                config.selectedPresetID = preset.id
                                config.customWidth = preset.width
                                config.customHeight = preset.height
                                config.orientation = .portrait
                            } label: {
                                if config.selectedPresetID == preset.id {
                                    Label("\(preset.name)  \(preset.displaySize)", systemImage: "checkmark")
                                } else {
                                    Text(preset.name)
                                }
                            }
                        }
                    }
                }
                Section("自定义") {
                    Picker("自定义尺寸", selection: Binding(
                        get: { "\(config.customWidth)×\(config.customHeight)" },
                        set: { _ in config.selectedPresetID = nil }
                    )) {
                        Text("\(config.customWidth)×\(config.customHeight)").tag("\(config.customWidth)×\(config.customHeight)")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(deviceLabel)
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .fixedSize()

            .div

            // ── 方向 ──
            Button {
                config.orientation = config.orientation == .portrait ? .landscape : .portrait
            } label: {
                Image(systemName: config.orientation == .portrait
                      ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("旋转方向")

            .div

            // ── 尺寸 ──
            HStack(spacing: 6) {
                TextField("W", value: Binding(
                    get: { config.customWidth },
                    set: {
                        config.selectedPresetID = nil
                        config.customWidth = max(200, $0)
                    }
                ), format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 44)

                Text("×").foregroundStyle(.tertiary).font(.system(size: 11))

                TextField("H", value: Binding(
                    get: { config.customHeight },
                    set: {
                        config.selectedPresetID = nil
                        config.customHeight = max(200, $0)
                    }
                ), format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 44)
            }
            .help("自定义视口尺寸")

            .div

            // ── 元信息：断点 · DPR · UA ──
            HStack(spacing: 5) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 9))
                Text("断点 \(activeBreakpointName) · @\(Int(config.pixelRatio))x · \(uaClass)")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)

            Spacer()

            // ── 右侧：模拟开关 ──
            barToggle("触摸", icon: "hand.point.up", isOn: Binding(
                get: { config.touchSimulationEnabled },
                set: { config.touchSimulationEnabled = $0 }
            ))
            barToggle("标尺", icon: "ruler", isOn: Binding(
                get: { config.showRulers },
                set: { config.showRulers = $0 }
            ))
            barToggle("媒体查询", icon: "list.bullet.rectangle", isOn: Binding(
                get: { config.showMediaQueryInspector },
                set: { config.showMediaQueryInspector = $0 }
            ))

            barIconButton("camera.viewfinder", "截取设备屏幕") {
                onScreenshot?()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 小组件

    private func barToggle(_ label: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var deviceLabel: String {
        if let id = config.selectedPresetID,
           let preset = responsiveStore.allPresets.first(where: { $0.id == id }) {
            return preset.name
        }
        return "自定义 \(config.customWidth)×\(config.customHeight)"
    }

    /// 当前视口宽度命中的断点名。
    private var activeBreakpointName: String {
        let w = config.effectiveSize.width
        switch w {
        case ..<576: return "base"
        case ..<768: return "sm"
        case ..<1024: return "md"
        case ..<1400: return "lg"
        default: return "xl"
        }
    }

    private var uaClass: String {
        let short = min(config.effectiveSize.width, config.effectiveSize.height)
        if short < 500 { return "mobile UA" }
        if short < 1200 { return "tablet UA" }
        return "desktop UA"
    }
}

private extension View {
    var div: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
    }

    func barIconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
