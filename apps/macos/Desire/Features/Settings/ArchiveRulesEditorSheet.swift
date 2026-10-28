import SwiftUI

/// 下载自动归档规则编辑器（v0.8.18 替人干活 14）：规则表增删改——
/// 扩展名或来源域命中 → 完成后移入下载根下的子目录。
/// 存储沿用 DownloadStore.loadArchiveRules/saveArchiveRules（桥端点同源）。
struct ArchiveRulesEditorSheet: View {
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [DownloadStore.ArchiveRule] = []
    @State private var newExt = ""
    @State private var newDomain = ""
    @State private var newFolder = ""
    /// 后处理链（v0.8.20）：命中后触发转换的目标格式（可空）。
    @State private var newConvertTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Auto-Archive Rules")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text(String(localized: "First matching rule moves a finished download into the folder (under your download root). Leave either matcher empty to match by the other."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            if rules.isEmpty {
                Text(String(localized: "No rules — downloads stay in the download folder."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                HStack(spacing: 8) {
                    if let ext = rule.ext, !ext.isEmpty {
                        Text(".\(ext)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    if let domain = rule.domain, !domain.isEmpty {
                        Text(domain)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(rule.folder)/")
                        .font(.system(size: 11, design: .monospaced))
                    if let convertTo = rule.convertTo, !convertTo.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(convertTo)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(appAccent)
                    }
                    Spacer()
                    Button {
                        rules.remove(at: index)
                        DownloadStore.saveArchiveRules(rules)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }

            Divider()
            HStack(spacing: 8) {
                TextField(String(localized: "ext (pdf)"), text: $newExt)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 80)
                TextField(String(localized: "source domain (arxiv.org)"), text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 130)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                TextField(String(localized: "subfolder (Papers)"), text: $newFolder)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 100)
                TextField(String(localized: "convert to (md, empty = no)"), text: $newConvertTo)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button(String(localized: "Add Rule")) { addRule() }
                    .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty
                              || (newExt.trimmingCharacters(in: .whitespaces).isEmpty
                                  && newDomain.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { rules = DownloadStore.loadArchiveRules() }
    }

    private func addRule() {
        let ext = newExt.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domain = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        let folder = newFolder.trimmingCharacters(in: .whitespaces)
        let convertTo = newConvertTo.trimmingCharacters(in: .whitespaces).lowercased()
        rules.append(DownloadStore.ArchiveRule(
            ext: ext.isEmpty ? nil : ext,
            domain: domain.isEmpty ? nil : domain,
            folder: folder,
            convertTo: convertTo.isEmpty ? nil : convertTo))
        DownloadStore.saveArchiveRules(rules)
        newExt = ""
        newDomain = ""
        newFolder = ""
    }
}
