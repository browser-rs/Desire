import SwiftUI

/// Playbook 编辑器（v0.8.2）：名称/说明/指令/参数/技能/输出方式。
/// 参数用列表编辑；保存前做最小校验（名称/指令非空、参数 key 唯一）。
struct PlaybookEditorSheet: View {
    let initial: Playbook
    let onSave: (Playbook) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var summary: String
    @State private var instructions: String
    @State private var skillName: String
    @State private var output: Playbook.Output
    @State private var parameters: [Playbook.Parameter]
    @State private var error: String?

    init(playbook: Playbook, onSave: @escaping (Playbook) -> Void) {
        self.initial = playbook
        self.onSave = onSave
        _name = State(initialValue: playbook.name)
        _summary = State(initialValue: playbook.summary)
        _instructions = State(initialValue: playbook.instructions)
        _skillName = State(initialValue: playbook.skillName ?? "")
        _output = State(initialValue: playbook.output)
        _parameters = State(initialValue: playbook.parameters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initial.name.isEmpty ? "New Playbook" : "Edit Playbook")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("Weekly competitor scan", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Summary").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("One line shown in the list", text: $summary)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Skill").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("Optional skill name (useSkill)", text: $skillName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Output").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Picker("", selection: $output) {
                        ForEach(Playbook.Output.allCases, id: \.self) { output in
                            Text(output.label).tag(output)
                        }
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextEditor(text: $instructions)
                    .font(.system(size: 12))
                    .frame(height: 110)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor)))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Parameters")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Add Parameter")) {
                        parameters.append(.init(key: "", label: ""))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
                ForEach($parameters) { parameter in
                    HStack(spacing: 6) {
                        TextField("key", text: parameter.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 92)
                        TextField("Label", text: parameter.label)
                            .textFieldStyle(.roundedBorder)
                        TextField("default", text: parameter.defaultValue)
                            .textFieldStyle(.roundedBorder)
                        TextField("choices, comma separated", text: choicesBinding(parameter))
                            .textFieldStyle(.roundedBorder)
                        Toggle("req", isOn: parameter.required)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                        Button {
                            parameters.removeAll { $0.id == parameter.wrappedValue.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Save")) { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 680)
    }

    private func choicesBinding(_ parameter: Binding<Playbook.Parameter>) -> Binding<String> {
        Binding(
            get: { parameter.wrappedValue.choices.joined(separator: ", ") },
            set: { text in
                parameter.wrappedValue.choices = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { error = "Name is required."; return }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Instructions are required."
            return
        }
        var seen = Set<String>()
        for parameter in parameters {
            let key = parameter.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { error = "Parameter keys cannot be empty."; return }
            guard seen.insert(key).inserted else { error = "Duplicate parameter key: \(key)"; return }
        }
        var cleaned = parameters
        for i in cleaned.indices {
            cleaned[i].key = cleaned[i].key.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned[i].label = cleaned[i].label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var playbook = initial
        playbook.name = trimmedName
        playbook.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        playbook.instructions = instructions
        playbook.skillName = skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : skillName.trimmingCharacters(in: .whitespacesAndNewlines)
        playbook.output = output
        playbook.parameters = cleaned
        onSave(playbook)
        dismiss()
    }
}
