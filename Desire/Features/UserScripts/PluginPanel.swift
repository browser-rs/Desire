import SwiftUI
import UniformTypeIdentifiers

struct PluginPanel: View {
    @ObservedObject var store: PluginStore
    var onClose: () -> Void

    @State private var editingPlugin: Plugin?
    @State private var showImportPicker = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("插件").font(.headline)
                Spacer()
                Button("", systemImage: "plus") {
                    let p = Plugin(name: "新插件", jsCode: "// 在此编写你的 JavaScript 代码\nconsole.log('Desire plugin loaded');")
                    store.add(p)
                    editingPlugin = p
                }
                .labelStyle(.iconOnly)
                Button("", systemImage: "square.and.arrow.down") { showImportPicker = true }
                    .labelStyle(.iconOnly)
                Button("关闭", action: onClose)
            }
            .padding()

            if store.plugins.isEmpty {
                EmptyState(message: "暂无插件")
            } else {
                List {
                    ForEach(store.plugins) { plugin in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { plugin.isEnabled },
                                set: { enabled in
                                    var p = plugin
                                    p.isEnabled = enabled
                                    store.update(p)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plugin.name).lineLimit(1).font(.body)
                                    if !plugin.description.isEmpty {
                                        Text(plugin.description).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 4) {
                                        Text("v\(plugin.version)").font(.caption2).foregroundStyle(.tertiary)
                                        if !plugin.author.isEmpty {
                                            Text("by \(plugin.author)").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        Text(plugin.urlPatterns.joined(separator: ", ")).lineLimit(1).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            Spacer()
                            Button("", systemImage: "pencil") { editingPlugin = plugin }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            Button("", systemImage: "square.and.arrow.up") { exportPlugin(plugin) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            Button("", systemImage: "trash") { store.remove(plugin) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 400)
        .sheet(item: $editingPlugin) { plugin in
            PluginEditor(plugin: Binding(
                get: { plugin },
                set: { editingPlugin = $0 }
            ), store: store)
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json, .desirePlugin]) { result in
            switch result {
            case .success(let url):
                if let plugin = store.importPlugin(from: url) {
                    store.add(plugin)
                } else {
                    importError = "无法导入插件：文件格式无效"
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("导入失败", isPresented: .init(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("确定") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func exportPlugin(_ plugin: Plugin) {
        guard let url = store.exportPlugin(plugin) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(plugin.name).desireplugin"
        panel.allowedContentTypes = [.desirePlugin]
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                try? FileManager.default.copyItem(at: url, to: dest)
                try? FileManager.default.removeItem(at: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

private struct PluginEditor: View {
    @Binding var plugin: Plugin
    @ObservedObject var store: PluginStore
    @State private var jsCode: String
    @State private var cssCode: String
    @State private var urlPatternsText: String
    @State private var excludePatternsText: String
    @Environment(\.dismiss) private var dismiss

    init(plugin: Binding<Plugin>, store: PluginStore) {
        _plugin = plugin
        self.store = store
        _jsCode = State(initialValue: plugin.wrappedValue.jsCode)
        _cssCode = State(initialValue: plugin.wrappedValue.cssCode)
        _urlPatternsText = State(initialValue: plugin.wrappedValue.urlPatterns.joined(separator: "\n"))
        _excludePatternsText = State(initialValue: plugin.wrappedValue.excludePatterns.joined(separator: "\n"))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("编辑插件").font(.headline)
                Spacer()
                Button("取消") {
                    store.update(plugin)
                    dismiss()
                }
                Button("保存") {
                    var p = plugin
                    p.jsCode = jsCode
                    p.cssCode = cssCode
                    p.urlPatterns = urlPatternsText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    p.excludePatterns = excludePatternsText.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    store.update(p)
                    plugin = p
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 8) {
                TextField("名称", text: $plugin.name)
                    .frame(width: 180)
                TextField("版本", text: $plugin.version)
                    .frame(width: 60)
                TextField("作者", text: $plugin.author)
                    .frame(width: 120)
            }

            TextField("描述", text: $plugin.description)

            HStack {
                Picker("注入时机", selection: $plugin.runAt) {
                    ForEach(RunAt.allCases, id: \.self) { at in
                        Text(at.rawValue.replacingOccurrences(of: "_", with: " ")).tag(at)
                    }
                }
                .frame(width: 200)
                Spacer()
                Toggle("启用", isOn: $plugin.isEnabled)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL 匹配模式（每行一个）").font(.caption)
                    TextEditor(text: $urlPatternsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .border(Color.secondary.opacity(0.2))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("排除模式（每行一个）").font(.caption)
                    TextEditor(text: $excludePatternsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .border(Color.secondary.opacity(0.2))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("JavaScript 代码").font(.caption)
                TextEditor(text: $jsCode)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.2))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("CSS 代码").font(.caption)
                TextEditor(text: $cssCode)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 80)
                    .border(Color.secondary.opacity(0.2))
            }
        }
        .padding()
        .frame(width: 560, height: 560)
    }
}

extension UTType {
    static let desirePlugin = UTType(exportedAs: "me.siwi.Desire.plugin")
}

#Preview {
    PluginPanel(store: PluginStore(), onClose: {})
}
