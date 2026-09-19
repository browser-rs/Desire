import SwiftUI

/// 密码生成器面板：实时预览 + 长度滑块 + 符号开关 + 复制。
struct PasswordGeneratorSheet: View {
    @Binding var generatedPassword: String
    @Binding var generatorLength: Int
    @Binding var generatorSymbols: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Text("Password Generator").font(.headline)
            Text(generatedPassword)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal)
                .textSelection(.enabled)
                .lineLimit(3)

            HStack {
                Text("Length: \(generatorLength)").font(.caption)
                Slider(value: Binding(
                    get: { Double(generatorLength) },
                    set: { newValue in
                        generatorLength = Int(newValue)
                        regenerate()
                    }
                ), in: 8...64)
            }
            .padding(.horizontal)

            Toggle("Include symbols", isOn: Binding(
                get: { generatorSymbols },
                set: { newValue in
                    generatorSymbols = newValue
                    regenerate()
                }
            )).padding(.horizontal)

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(generatedPassword, forType: .string)
                }
                Button("Regenerate") { regenerate() }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .frame(width: 360)
    }

    private func regenerate() {
        generatedPassword = PasswordStore.generatePassword(
            length: generatorLength, includeSymbols: generatorSymbols)
    }
}
