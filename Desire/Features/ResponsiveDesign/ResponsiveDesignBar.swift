import SwiftUI

/// 响应式模式顶部工具条 — Chrome DevTools 单行范式。
struct ResponsiveDesignBar: View {
    /// 应用强调色（见 AppAccent.swift：Color.accentColor 不可用）。
    @Environment(\.appAccent) private var appAccent: Color
    @Binding var config: ResponsiveConfig
    let responsiveStore: ResponsiveDesignStore
    var onScreenshot: (() -> Void)?
    var mediaQueries: [MediaQueryItem]

    var body: some View {
        HStack(spacing: 12) {
            exitPill
            vdiv
            deviceMenu
            vdiv
            rotateButton
            vdiv
            dims
            vdiv
            metaChip
            Spacer()
            toggleButton("触摸", icon: "hand.point.up",
                         isOn: config.touchSimulationEnabled) {
                config.touchSimulationEnabled.toggle()
            }
            toggleButton("标尺", icon: "ruler",
                         isOn: config.showRulers) {
                config.showRulers.toggle()
            }
            toggleButton("媒体查询", icon: "list.bullet.rectangle",
                         isOn: config.showMediaQueryInspector) {
                config.showMediaQueryInspector.toggle()
            }
            vdiv
            shotButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 竖向分隔线（分组间的视觉边界）。
    private var vdiv: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
    }

    private func toggleButton(_ label: String, icon: String, isOn: Bool,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(isOn ? appAccent : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isOn ? appAccent.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    /// 截取设备屏幕。
    private var shotButton: some View {
        Button {
            onScreenshot?()
        } label: {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help("截取设备屏幕")
    }

    // MARK: - 控件

    /// 退出响应式模式（恢复桌面 UA + 重载）。
    private var exitPill: some View {
        Button {
            config.isEnabled = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                Text("完成")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(appAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(appAccent.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help("退出响应式模式")
    }

    /// 设备/预设选择菜单。
    private var deviceMenu: some View {
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
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(appAccent)
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
    }

    /// 宽高输入（直绑 config，与拖把手/预设同源）。
    private var dims: some View {
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
    }

    /// 元信息：当前断点名 · DPR · UA 类型。
    private var metaChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 9))
            Text("断点 \(activeBreakpointName) · @\(Int(config.pixelRatio))x · \(uaClass)")
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }

    /// 方向按钮（横竖切换）。
    private var rotateButton: some View {
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
    }

    // MARK: - 派生

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

/// 通用开关/图标按钮（工具条内复用）。
private func barToggleLabel(_ label: String, icon: String, isOn: Bool) -> some View {
    HStack(spacing: 5) {
        Image(systemName: icon)
            .font(.system(size: 11))
        Text(label)
            .font(.system(size: 11.5, weight: .medium))
    }
    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(
        RoundedRectangle(cornerRadius: 7)
            .fill(isOn ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color.clear))
    )
}
