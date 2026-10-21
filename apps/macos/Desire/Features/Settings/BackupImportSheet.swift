import SwiftUI

/// 备份导入确认（v0.7.28）：预览版本/日期/各域条数，可按域勾选；
/// Merge（只补缺）/ Replace（覆盖选中域）。替换走二次点击（按钮文案随模式变化）。
struct BackupImportSheet: View {
    let url: URL
    let preview: BackupService.Preview
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: BackupService.Mode = .merge
    @State private var selected: Set<BackupArchive.Domain>
    @State private var passphrase = ""

    init(url: URL, preview: BackupService.Preview, onFinish: @escaping (String) -> Void) {
        self.url = url
        self.preview = preview
        self.onFinish = onFinish
        _selected = State(initialValue: Set(BackupArchive.Domain.allCases.filter {
            preview.counts[$0.rawValue] != nil
        }))
    }

    private var detailLine: String {
        let date = DateFormatter.localizedString(from: preview.exportedAt,
                                                 dateStyle: .medium,
                                                 timeStyle: .short)
        return "Exported \(date) · app \(preview.appVersion) · format \(preview.version)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import backup")
                .font(.headline)
            Text(detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !preview.supported {
                Text("This backup was written by a newer app version and cannot be imported.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("Mode", selection: $mode) {
                Text("Merge").tag(BackupService.Mode.merge)
                Text("Replace").tag(BackupService.Mode.replace)
            }
            .pickerStyle(.segmented)

            Text(mode == .merge
                 ? "Merge adds missing items and leaves current data in place (settings are untouched)."
                 : "Replace overwrites the selected domains with the backup.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if preview.encrypted {
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                Text("Encrypted backup — all domains will be restored with the chosen mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(BackupArchive.Domain.allCases, id: \.self) { domain in
                            if let count = preview.counts[domain.rawValue] {
                                Toggle(isOn: Binding(
                                    get: { selected.contains(domain) },
                                    set: { on in
                                        if on { selected.insert(domain) } else { selected.remove(domain) }
                                    })) {
                                    HStack {
                                        Text(domain.title)
                                        Spacer()
                                        Text("\(count)")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 220)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(mode == .replace ? "Replace…" : "Merge") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!preview.supported
                              || (preview.encrypted ? passphrase.isEmpty : selected.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func apply() {
        do {
            let applied = try BackupService.importArchive(
                from: url, mode: mode,
                domains: preview.encrypted ? nil : selected,
                passphrase: preview.encrypted ? passphrase : nil)
            let total = applied.values.reduce(0, +)
            onFinish(String(format: String(localized: "Imported: %lld item(s)"), total))
            dismiss()
        } catch {
            onFinish(error.localizedDescription)
            dismiss()
        }
    }
}
