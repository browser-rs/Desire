import SwiftUI

/// 命令模板（v0.8.40）：保存常用的后台命令，一键运行。
struct JobTemplatesPanel: View {
    @ObservedObject private var store = JobTemplateStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color

    @State private var name = ""
    @State private var tool = ""
    @State private var argsText = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Command Templates"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.borderless)
            }
            Text(String(localized: "Templates are allowlisted tools with argv only — no shell. Run them from here or ask the Agent."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if store.templates.isEmpty {
                        Text(String(localized: "No templates yet."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 16)
                    }
                    ForEach(store.templates) { template in
                        row(template)
                    }
                }
            }
            .frame(maxHeight: 240)

            Divider()
            Text(String(localized: "New Template"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(String(localized: "Name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "Tool (e.g. xcodebuild)"), text: $tool)
                    .textFieldStyle(.roundedBorder)
            }
            TextField(String(localized: "Arguments (space separated)"), text: $argsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            HStack {
                if let message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Save Template")) { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || tool.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 560, height: 500)
    }

    private func row(_ template: JobTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(appAccent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(template.name)
                    .font(.system(size: 11.5, weight: .medium))
                Text(([template.tool] + template.args).joined(separator: " "))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button(String(localized: "Run")) { run(template) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button {
                store.delete(template.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }

    private func save() {
        let parts = argsText.split(separator: " ").map(String.init)
        let existing = store.template(named: name)
        let template = JobTemplate(
            id: existing?.id ?? UUID(),
            name: name, tool: tool, args: parts,
            createdAt: existing?.createdAt ?? Date())
        if store.save(template) {
            message = String(localized: "Saved.")
            argsText = ""
        } else {
            message = String(localized: "Check the name and tool.")
        }
    }

    private func run(_ template: JobTemplate) {
        message = String(localized: "Starting…")
        Task { @MainActor in
            let result = await BackgroundCommandStore.shared.start(
                tool: template.tool, args: template.args,
                title: template.name, cwd: template.cwd,
                timeoutMinutes: template.timeoutMinutes,
                conversationID: nil, report: .notify,
                maxAttempts: template.maxAttempts,
                retryOn: template.retryOn,
                priority: template.priority)
            switch result {
            case .success(let id):
                message = String(localized: "Started job \(id.uuidString).")
            case .failure(let error):
                message = error.message
            }
        }
    }
}
