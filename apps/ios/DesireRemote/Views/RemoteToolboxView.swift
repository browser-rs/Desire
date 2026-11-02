import SwiftUI
import UIKit

/// 工具箱（v0.8.38 批二）：Mac 端 48 个纯文本工具的手机入口。
/// 目录与 Mac `ToolboxRuntimeCore.specs` 同源；参数表单按 spec 动态生成，
/// 留空即用 Mac 端默认值。
struct RemoteToolboxView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var searchText = ""
    @State private var selectedTool: RemoteToolboxTool?

    private var filtered: [RemoteToolboxTool] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return client.toolboxTools }
        return client.toolboxTools.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            if client.toolboxTools.isEmpty {
                DesireEmptyState(
                    icon: "wrench.and.screwdriver",
                    title: "工具箱正在加载",
                    message: "这些是在 Mac 上运行的纯文本工具，结果不会离开你的设备。")
                    .listRowBackground(Color.clear)
            } else if filtered.isEmpty {
                Text("没有匹配 \(searchText) 的工具")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                Section {
                    ForEach(filtered) { tool in
                        Button {
                            selectedTool = tool
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(tool.name)
                                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(tool.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(tool.arguments)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    DesireSectionHeader(
                        title: "\(client.toolboxTools.count) 个工具",
                        subtitle: "点一个填参数，在 Mac 上执行")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("工具箱")
        .searchable(text: $searchText, prompt: "按名称或用途过滤")
        .onAppear { client.requestToolboxCatalog() }
        .refreshable { client.requestToolboxCatalog() }
        .sheet(item: $selectedTool) { tool in
            RemoteToolRunSheet(tool: tool)
        }
    }
}

/// 工具参数表单：spec 形如 `text, mode=encode|decode, urlSafe=true|false`。
private struct RemoteToolRunSheet: View {
    @EnvironmentObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    let tool: RemoteToolboxTool

    @State private var values: [String: String] = [:]

    private var arguments: [ToolArgument] { ToolArgument.parse(tool.arguments) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(tool.summary)
                        .font(.subheadline)
                    Text(tool.arguments)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text(tool.name)
                        .font(.system(.headline, design: .monospaced))
                        .textCase(nil)
                }

                Section {
                    ForEach(arguments) { argument in
                        field(for: argument)
                    }
                } header: {
                    Text("参数")
                } footer: {
                    Text("留空的参数使用 Mac 端默认值。")
                }

                Section {
                    Button {
                        run()
                    } label: {
                        HStack {
                            Spacer()
                            Label("在 Mac 上运行", systemImage: "play.fill")
                            Spacer()
                        }
                    }
                }

                if let result = client.toolboxResult, result.tool == tool.name {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(result.ok ? .green : .orange)
                            Text(result.ok ? "完成" : "失败")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button {
                                UIPasteboard.general.string = result.text
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                                    .labelStyle(.iconOnly)
                            }
                        }
                        ScrollView {
                            Text(result.text.isEmpty ? "（空结果）" : result.text)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 280)
                    } header: {
                        Text("结果")
                    }
                }
            }
            .navigationTitle("运行工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onDisappear { client.toolboxResult = nil }
        }
    }

    @ViewBuilder
    private func field(for argument: ToolArgument) -> some View {
        switch argument.kind {
        case .choice(let choices):
            Picker(argument.key, selection: binding(argument.key)) {
                Text("默认").tag("")
                ForEach(choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
        case .text:
            if argument.multiline {
                VStack(alignment: .leading, spacing: 6) {
                    Text(argument.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: binding(argument.key))
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 110)
                }
            } else {
                TextField(argument.placeholder.isEmpty ? argument.key : argument.placeholder,
                          text: binding(argument.key))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 14, design: .monospaced))
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 })
    }

    private func run() {
        var args: [String: String] = [:]
        for argument in arguments {
            let value = (values[argument.key] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { args[argument.key] = value }
        }
        client.runToolboxTool(tool.name, args: args)
    }
}

/// spec 解析结果。`text` 类参数在已知是大段文本时用多行编辑器。
private struct ToolArgument: Identifiable, Equatable {
    enum Kind: Equatable {
        case text
        case choice([String])
    }

    var key: String
    var placeholder: String
    var kind: Kind
    var multiline: Bool
    var id: String { key }

    private static let multilineKeys: Set<String> = [
        "text", "old", "new", "json", "xml", "sql", "body",
    ]
    private static let booleanKeys: Set<String> = [
        "digits", "symbols", "uppercase", "avoidAmbiguous", "unique",
        "caseInsensitive", "multiline",
    ]

    static func parse(_ spec: String) -> [ToolArgument] {
        tokens(in: spec).map { token in
            if let equals = token.firstIndex(of: "=") {
                let key = String(token[..<equals]).trimmingCharacters(in: .whitespaces)
                let raw = String(token[token.index(after: equals)...])
                    .trimmingCharacters(in: .whitespaces)
                if raw.contains("|") {
                    let choices = raw.split(separator: "|").map(String.init)
                    return ToolArgument(key: key, placeholder: raw, kind: .choice(choices),
                                        multiline: false)
                }
                return ToolArgument(key: key, placeholder: raw, kind: .text,
                                    multiline: multilineKeys.contains(key))
            }
            if booleanKeys.contains(token) {
                return ToolArgument(key: token, placeholder: "", kind: .choice(["true", "false"]),
                                    multiline: false)
            }
            // spec 里的人类可读说明（`value (seconds… or date)`、`code or query`）
            // 取第一个词作参数名，整句留作占位提示。
            let key = token.split(separator: " ").first.map(String.init) ?? token
            return ToolArgument(key: key, placeholder: token,
                                kind: .text, multiline: multilineKeys.contains(key))
        }
    }

    /// 按逗号切分，但 `delimiter=,` 这种"值本身是逗号"的片段要并回去。
    private static func tokens(in spec: String) -> [String] {
        var result: [String] = []
        var current = ""
        for piece in spec.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            current = current.isEmpty ? trimmed : current + "," + trimmed
            if !current.hasSuffix("=") && !trimmed.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
