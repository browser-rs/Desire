import AVFoundation
import SwiftUI

/// 朗读声音/语速设置（v0.8.36）。
struct ReaderSpeechSettingsView: View {
    let onClose: () -> Void

    @State private var settings = ReaderSpeechSettings.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "Voice & Speed"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) {
                    settings.save()
                    onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(String(localized: "Speed"))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Text(verbatim: String(format: "%.2f×", settings.rate))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(settings.rate) },
                    set: { settings.rate = Float($0) }
                ), in: 0.3...0.85)
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Voice"))
                    .font(.system(size: 11.5, weight: .medium))
                Picker("", selection: Binding(
                    get: { settings.voiceIdentifier ?? "" },
                    set: { settings.voiceIdentifier = $0.isEmpty ? nil : $0 }
                )) {
                    Text(String(localized: "Automatic")).tag("")
                    ForEach(ReaderSpeechSettings.availableVoices, id: \.identifier) { voice in
                        Text(verbatim: "\(voice.language) · \(voice.name)")
                            .tag(voice.identifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text(String(localized: "Changes apply to the next read."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "Preview")) {
                    settings.save()
                    ReaderSpeechService.shared.speak(
                        String(localized: "This is how the reading voice sounds."))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
