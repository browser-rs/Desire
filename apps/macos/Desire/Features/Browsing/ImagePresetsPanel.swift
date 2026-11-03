import SwiftUI

/// 预设面板（v0.8.41）：保存当前调节（含曲线）为命名预设、应用、删除。
struct ImagePresetsPanel: View {
    @ObservedObject private var store = ImageEditPresetStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color
    /// 当前滑杆 + 曲线草稿（由编辑器传入）。
    let currentParams: () -> ImageAdjustParams
    let onApply: (ImageAdjustParams) -> Void

    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Edit Presets"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.borderless)
            }
            HStack {
                TextField(String(localized: "Preset name"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                Button(String(localized: "Save Current")) { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Divider()
            if store.presets.isEmpty {
                Text(String(localized: "No presets yet."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.presets) { preset in
                            row(preset)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460, height: 420)
    }

    private func row(_ preset: ImageEditPreset) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11))
                .foregroundStyle(appAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.system(size: 11.5, weight: .medium))
                Text(presetSummary(preset.params))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(String(localized: "Apply")) {
                onApply(preset.params)
                message = String(localized: "Applied \"\(preset.name)\"")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                store.delete(preset.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func presetSummary(_ params: ImageAdjustParams) -> String {
        var parts: [String] = []
        if params.brightness != 0 { parts.append("B\(Int(params.brightness * 100))") }
        if params.contrast != 1 { parts.append("C\(String(format: "%.2f", params.contrast))") }
        if params.saturation != 1 { parts.append("S\(String(format: "%.2f", params.saturation))") }
        if params.temperature != 0 { parts.append("T\(Int(params.temperature))") }
        if params.tint != 0 { parts.append("Ti\(Int(params.tint))") }
        if params.vibrance != 0 { parts.append("V\(Int(params.vibrance * 100))") }
        if params.clarity > 0 { parts.append("Cl\(Int(params.clarity * 100))") }
        if params.vignette > 0 { parts.append("Vg\(Int(params.vignette * 100))") }
        if params.hasCurve { parts.append("Curve") }
        if params.hasChannelCurves { parts.append("ChCurves") }
        return parts.isEmpty ? String(localized: "Neutral") : parts.joined(separator: " · ")
    }

    private func save() {
        guard store.save(name: newName, params: currentParams()) != nil else {
            message = String(localized: "Enter a preset name.")
            return
        }
        message = String(localized: "Saved.")
        newName = ""
    }
}
