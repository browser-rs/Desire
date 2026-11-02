import AppKit
import SwiftUI

/// 工具箱流水线（v0.8.38 A5）：把纯文本工具串起来，保存后可反复运行。
/// 每一步可用上一步输出作为输入；失败即停并保留中间结果。
struct ToolboxPipelineToolView: View {
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var store = ToolboxPipelineStore.shared
    @State private var draft: ToolboxPipeline?
    @State private var initialText = ""
    @State private var result: ToolboxPipelineCore.RunResult?
    @State private var message: String?
    @State private var confirmDelete: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let draft {
                editor(draft)
            } else {
                list
            }
        }
    }

    // MARK: - 列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    draft = ToolboxPipeline(name: String(localized: "New Pipeline"))
                    initialText = ""
                    result = nil
                    message = nil
                } label: {
                    Label(String(localized: "New Pipeline"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer()
            }
            if store.pipelines.isEmpty {
                EmptyState(
                    title: String(localized: "No pipelines yet"),
                    systemImage: "point.topleft.down.to.point.right.top",
                    description: String(localized: "Chain text tools (JSON → text → hash, and so on) and save the flow for one-click reruns."))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.pipelines) { pipeline in
                        row(pipeline)
                    }
                }
            }
        }
    }

    private func row(_ pipeline: ToolboxPipeline) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "point.topleft.down.to.point.right.top")
                .font(.system(size: 12))
                .foregroundStyle(appAccent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(pipeline.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(String(localized: "\(pipeline.steps.count) step(s)"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(String(localized: "Run")) {
                draft = pipeline
                result = ToolboxPipelineCore.run(pipeline, initialText: initialText)
                message = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(String(localized: "Edit")) {
                draft = pipeline
                result = nil
                message = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(role: .destructive) {
                confirmDelete = pipeline.id
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Delete"))
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            String(localized: "Delete this pipeline?"),
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } })
        ) {
            if let id = confirmDelete {
                Button(String(localized: "Delete"), role: .destructive) {
                    store.delete(id)
                    confirmDelete = nil
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { confirmDelete = nil }
        }
    }

    // MARK: - 编辑器

    private func editor(_ pipeline: ToolboxPipeline) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(String(localized: "Pipeline name"), text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button(String(localized: "Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(String(localized: "Done")) { draft = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text(String(localized: "Arguments: key=value; key2=value2. Steps with “Use previous output” receive the prior step's text."))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(index: index, step: step, count: pipeline.steps.count)
                }
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(ToolboxRuntimeCore.specs, id: \.name) { spec in
                        Button(spec.name) { addStep(spec.name) }
                    }
                } label: {
                    Label(String(localized: "Add Step"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 11))
                .frame(maxWidth: 150)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Initial input"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $initialText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            HStack(spacing: 8) {
                Button(String(localized: "Run Pipeline")) { run(pipeline) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(pipeline.steps.isEmpty)
                if let message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            if let result {
                resultView(result)
            }
        }
    }

    private func stepRow(index: Int, step: ToolboxPipelineStep, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(index + 1).")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Picker("", selection: toolBinding(index)) {
                    ForEach(ToolboxRuntimeCore.specs, id: \.name) { spec in
                        Text(spec.name).tag(spec.name)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                Toggle(String(localized: "Use previous output"), isOn: inputBinding(index))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == count - 1)
                Button { removeStep(index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
            TextField(String(localized: "key=value; key2=value2"),
                      text: argsBinding(index))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5, design: .monospaced))
                .disabled(step.inputKey != nil && step.arguments.isEmpty)
            if let spec = ToolboxRuntimeCore.specs.first(where: { $0.name == step.tool }) {
                Text(spec.arguments)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder
    private func resultView(_ result: ToolboxPipelineCore.RunResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .orange)
                Text(result.ok ? String(localized: "Pipeline finished")
                     : String(localized: "Stopped at step \(String((result.failedIndex ?? 0) + 1))"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.finalText, forType: .string)
                } label: {
                    Label(String(localized: "Copy Output"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10.5))
            }
            ForEach(result.steps, id: \.index) { step in
                HStack(spacing: 6) {
                    Image(systemName: step.ok ? "checkmark" : "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(step.ok ? .green : .red)
                    Text("\(step.index + 1). \(step.tool)")
                        .font(.system(size: 10, design: .monospaced))
                    Text(String(step.text.prefix(80)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ScrollView {
                Text(result.finalText.isEmpty ? String(localized: "（空结果）") : result.finalText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor)))
        }
    }

    // MARK: - 绑定

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft?.name ?? "" },
            set: { draft?.name = $0 })
    }

    private func toolBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft?.steps[index].tool ?? "" },
            set: { newValue in
                guard var current = draft, current.steps.indices.contains(index) else { return }
                let previous = current.steps[index]
                current.steps[index] = ToolboxPipelineStep(
                    id: previous.id, tool: newValue,
                    arguments: previous.arguments, inputKey: previous.inputKey)
                draft = current
            })
    }

    private func inputBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let draft, draft.steps.indices.contains(index) else { return true }
                return draft.steps[index].inputKey != nil
            },
            set: { enabled in
                guard var current = draft, current.steps.indices.contains(index) else { return }
                current.steps[index].inputKey = enabled ? "text" : nil
                draft = current
            })
    }

    private func argsBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let draft, draft.steps.indices.contains(index) else { return "" }
                return ToolboxPipelineCore.encodeArguments(draft.steps[index].arguments)
            },
            set: { raw in
                guard var current = draft, current.steps.indices.contains(index) else { return }
                current.steps[index].arguments = ToolboxPipelineCore.decodeArguments(raw)
                draft = current
            })
    }

    // MARK: - 动作

    private func addStep(_ tool: String) {
        guard var current = draft else { return }
        current.steps.append(ToolboxPipelineStep(tool: tool))
        draft = current
    }

    private func removeStep(_ index: Int) {
        guard var current = draft, current.steps.indices.contains(index) else { return }
        current.steps.remove(at: index)
        draft = current
    }

    private func move(_ index: Int, by offset: Int) {
        guard var current = draft, current.steps.indices.contains(index) else { return }
        let target = index + offset
        guard current.steps.indices.contains(target) else { return }
        current.steps.swapAt(index, target)
        draft = current
    }

    private func save() {
        guard let current = draft else { return }
        if let failure = ToolboxPipelineCore.validationError(for: current) {
            message = failure
            return
        }
        _ = store.save(current)
        if let saved = store.pipeline(current.id) { draft = saved }
        message = String(localized: "Saved")
    }

    private func run(_ pipeline: ToolboxPipeline) {
        message = nil
        result = ToolboxPipelineCore.run(pipeline, initialText: initialText)
    }
}
