import AppKit
import SwiftUI

/// 运行 Playbook（v0.8.2）：收集参数 → 组合 prompt → 交给 Agent 回合。
/// 发布/回复等动作仍由 Agent 的审批链拦住，Playbook 不绕过审批。
struct PlaybookRunSheet: View {
    let playbook: Playbook
    /// 由上层把 prompt 送进 Agent（Agent 窗口/面板环境）；nil = 只能复制。
    let onRun: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: String] = [:]

    private var missing: [Playbook.Parameter] {
        PlaybookRun.missingRequired(playbook, values: values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playbook.name)
                    .font(.system(size: 15, weight: .semibold))
                if !playbook.summary.isEmpty {
                    Text(playbook.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if playbook.parameters.isEmpty {
                Text("This playbook takes no parameters.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(playbook.parameters) { parameter in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(parameter.label)
                                .font(.system(size: 11.5, weight: .medium))
                            if parameter.required {
                                Text("*").foregroundStyle(.red)
                            }
                            Spacer()
                            Text(parameter.key)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if parameter.choices.isEmpty {
                            TextField(parameter.placeholder, text: binding(parameter))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: binding(parameter)) {
                                ForEach(parameter.choices, id: \.self) { choice in
                                    Text(choice).tag(choice)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
            }

            if !missing.isEmpty {
                Text(String(localized: "Fill required: ") + missing.map(\.label).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(String(localized: "Copy Prompt")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        PlaybookRun.compose(playbook, values: effectiveValues),
                        forType: .string)
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Run")) {
                    guard let onRun else { return }
                    onRun(PlaybookRun.compose(playbook, values: effectiveValues))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!missing.isEmpty || onRun == nil)
            }
            if onRun == nil {
                Text(String(localized: "Open this from the Agent window to run it."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            for parameter in playbook.parameters where values[parameter.key] == nil {
                values[parameter.key] = parameter.defaultValue
            }
        }
    }

    private var effectiveValues: [String: String] {
        var out = values
        for parameter in playbook.parameters where out[parameter.key] == nil {
            out[parameter.key] = parameter.defaultValue
        }
        return out
    }

    private func binding(_ parameter: Playbook.Parameter) -> Binding<String> {
        Binding(get: { values[parameter.key] ?? parameter.defaultValue },
                set: { values[parameter.key] = $0 })
    }
}
