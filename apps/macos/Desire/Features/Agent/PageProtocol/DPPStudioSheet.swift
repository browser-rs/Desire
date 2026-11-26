import AppKit
import SwiftUI
import WebKit

/// 打开 DPP Studio 的请求（运营页/设置页共用）。
struct DPPStudioRequest: Identifiable {
    let id = UUID()
    var host: String?
    var platform: String?
}

/// DPP Studio（v0.8.3）：自定义运营适配包的创作台。
///
/// 流程：模板/已装包 → 编辑协议 JSON → 校验（结构 + `ops/1` 安全契约）→
/// 在当前标签页上**试抽取**（只读）→ 保存为**禁用草稿**（默认）→ 用户显式启用。
///
/// 边界：
/// - 测试只做只读抽取，**不执行任何动作**（compose/publish/reply 都不试跑）；
/// - 保存默认禁用：适配包会真实参与解析与动作，启用必须是用户的显式动作；
/// - 页面原生声明优先——这里做的是"站点没接入时的补空白"。
struct DPPStudioSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var adapters = DPPAdapterStore.shared

    let initialHost: String?
    let initialPlatform: String?

    @State private var name = ""
    @State private var hosts = ""
    @State private var pathPrefixes = ""
    @State private var notes = ""
    @State private var bodyText = ""
    @State private var errors: [String] = []
    @State private var warnings: [String] = []
    @State private var testView = ""
    @State private var testOutput: String?
    @State private var saveNote: String?
    @State private var enableAfterSave = false
    // 下载规则（v0.8.79 批 3）：JSON 是唯一真相，表单是受控字段的投影；
    // 编辑前的规则另存一份——改一个连接数不该清掉站点学到的实测画像。
    @State private var downloadEnabled = false
    @State private var downloadDraft = DPPDownloadRulesDraft()
    @State private var downloadEditingJSON = false
    @State private var downloadJSON = "{}"
    @State private var downloadMeasured: String?
    @State private var loadedDownload: DPPDownloadRules?
    @State private var downloadErrors: [String] = []

    init(initialHost: String? = nil, initialPlatform: String? = nil) {
        self.initialHost = initialHost
        self.initialPlatform = initialPlatform
    }

    /// 快照/预览入口（v0.8.79 批 3）：离屏 `NSHostingView` 不触发 `onAppear`，
    /// prefill 不会跑——把一份适配器直接播种进表单，快照里才看得见下载规则区。
    init(previewAdapter: DPPAdapter, initialHost: String? = nil) {
        self.initialHost = initialHost
        self.initialPlatform = nil
        _name = State(initialValue: previewAdapter.name)
        _hosts = State(initialValue: previewAdapter.hosts.joined(separator: ", "))
        _pathPrefixes = State(initialValue: previewAdapter.pathPrefixes.joined(separator: ", "))
        _notes = State(initialValue: previewAdapter.notes)
        _bodyText = State(initialValue: Self.prettyJSON(previewAdapter.protocolBody))
        _downloadEnabled = State(initialValue: previewAdapter.download != nil)
        _downloadDraft = State(initialValue: DPPDownloadRulesEditing.draft(from: previewAdapter.download))
        _downloadJSON = State(initialValue: previewAdapter.download.map(DPPDownloadRulesEditing.json) ?? "{}")
        _downloadMeasured = State(initialValue: DPPDownloadRulesEditing.measuredSummary(previewAdapter.download?.measured))
        _loadedDownload = State(initialValue: previewAdapter.download)
        _testView = State(initialValue: previewAdapter.protocolBody.views.keys.sorted().first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            form
            HStack(spacing: 8) {
                Button(String(localized: "Load Ops Template")) { loadTemplate() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "Load Installed Adapter")) { loadInstalled() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(adapters.adapters.isEmpty)
                Button(String(localized: "Format JSON")) { formatJSON() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button(String(localized: "Validate")) { validateNow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            TextEditor(text: $bodyText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
            validationBlock
            testBlock
            downloadBlock
            footer
        }
        .padding(16)
        .frame(width: 660, height: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: prefill)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(appAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "DPP Studio"))
                    .font(.system(size: 13, weight: .semibold))
                Text(String(localized: "Author a custom adapter for a site that doesn't declare DPP. Saved disabled — enable it yourself after review."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let host = initialHost, !host.isEmpty {
                Text(host)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                labeledField(String(localized: "Name"), text: $name, width: 170)
                labeledField(String(localized: "Hosts (comma separated)"), text: $hosts, width: 250)
                labeledField(String(localized: "Path prefixes"), text: $pathPrefixes, width: 180)
            }
            labeledField(String(localized: "Notes"), text: $notes, width: 640)
        }
    }

    private func labeledField(_ title: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: width)
        }
    }

    @ViewBuilder
    private var validationBlock: some View {
        if !errors.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(errors, id: \.self) { error in
                    Label(error, systemImage: "xmark.octagon")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                }
                ForEach(warnings.prefix(6), id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var testBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(String(localized: "Test extraction (read-only)"))
                    .font(.system(size: 10.5, weight: .medium))
                if !viewNames.isEmpty {
                    Picker("", selection: $testView) {
                        ForEach(viewNames, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }
                Button(String(localized: "Run on Current Tab")) { runTest() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewNames.isEmpty)
                Spacer()
            }
            if let testOutput {
                ScrollView {
                    Text(testOutput)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(String(localized: "Read-only: the studio never runs compose/publish/reply actions. It only counts items and prints the first few field values."))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 下载规则（v0.8.79 批 3）：字段表单与 JSON 两个入口，JSON 为唯一真相。
    /// 只有"这个适配器管下载"时才展示；实测画像是只读的（引擎回写，不在这里改）。
    @ViewBuilder
    private var downloadBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Toggle(String(localized: "Download rules for this site"), isOn: $downloadEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if downloadEnabled {
                    Toggle(String(localized: "Edit as JSON"), isOn: downloadJSONModeBinding)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10.5))
                }
            }
            if downloadEnabled {
                if downloadEditingJSON {
                    TextEditor(text: $downloadJSON)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(height: 104)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                        )
                } else {
                    downloadFields
                }
                if !downloadErrors.isEmpty {
                    ForEach(downloadErrors, id: \.self) { error in
                        Label(error, systemImage: "xmark.octagon")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
                if let downloadMeasured {
                    Text(downloadMeasured)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var downloadFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                labeledField(String(localized: "Extract (regex or selector)"), text: $downloadDraft.detail, width: 360)
                pickerField(String(localized: "Per page"), selection: $downloadDraft.perPage, width: 92, options: [
                    ("", String(localized: "Automatic")),
                    ("one", String(localized: "One")),
                    ("many", String(localized: "Many")),
                ])
                pickerField(String(localized: "Method"), selection: $downloadDraft.engine, width: 110, options: [
                    ("", String(localized: "Automatic")),
                    ("parallel", String(localized: "Parallel")),
                    ("ffmpeg", "FFmpeg"),
                    ("builtin", String(localized: "Built-in")),
                ])
            }
            HStack(spacing: 8) {
                labeledField(String(localized: "Connections"), text: $downloadDraft.connections, width: 70)
                labeledField(String(localized: "Token minutes"), text: $downloadDraft.tokenMinutes, width: 70)
                Spacer()
                Button(String(localized: "Add exclude")) { downloadDraft.exclude.append("") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            ForEach(Array(downloadDraft.exclude.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 6) {
                    TextField("", text: Binding(
                        get: { index < downloadDraft.exclude.count ? downloadDraft.exclude[index] : "" },
                        set: { if index < downloadDraft.exclude.count { downloadDraft.exclude[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10.5, design: .monospaced))
                    Button {
                        if index < downloadDraft.exclude.count { downloadDraft.exclude.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func pickerField(_ title: String, selection: Binding<String>, width: CGFloat,
                             options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: width)
        }
    }

    /// JSON 模式切换：进 JSON 先由表单渲染（JSON 是它的序列化形态）；回表单要能
    /// 解析——解析失败就留在 JSON 模式并把错误亮出来，不吞掉用户刚写的文本。
    private var downloadJSONModeBinding: Binding<Bool> {
        Binding(
            get: { downloadEditingJSON },
            set: { wantsJSON in
                if wantsJSON {
                    let built = DPPDownloadRulesEditing.rules(from: downloadDraft, preserving: loadedDownload)
                    downloadErrors = built.errors
                    downloadJSON = DPPDownloadRulesEditing.json(built.rules)
                    downloadEditingJSON = true
                } else {
                    let parsed = DPPDownloadRulesEditing.parse(json: downloadJSON)
                    if let rules = parsed.rules {
                        downloadDraft = DPPDownloadRulesEditing.draft(from: rules)
                        downloadErrors = DPPDownloadRulesEditing.validate(rules)
                        downloadEditingJSON = false
                    } else if let error = parsed.error {
                        downloadErrors = [error]
                    } else {
                        downloadDraft = DPPDownloadRulesDraft()
                        downloadErrors = []
                        downloadEditingJSON = false
                    }
                }
            }
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(String(localized: "Enable immediately"), isOn: $enableAfterSave)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            if let saveNote {
                Text(saveNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button(String(localized: "Save Draft")) { saveDraft() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(String(localized: "Close")) { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - State helpers

    private var viewNames: [String] {
        guard let proto = tryDecode(reportErrors: false) else { return [] }
        let ops = proto.views.keys.filter { $0.hasPrefix("ops") }.sorted()
        return ops.isEmpty ? proto.views.keys.sorted() : ops
    }

    private func prefill() {
        guard bodyText.isEmpty else { return }
        let host = (initialHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let installed = adapters.adapters.first(where: { !host.isEmpty && $0.matchesHost(host) }) {
            fill(from: installed)
        } else {
            loadTemplate()
        }
    }

    private func fill(from adapter: DPPAdapter) {
        name = adapter.name
        hosts = adapter.hosts.joined(separator: ", ")
        pathPrefixes = adapter.pathPrefixes.joined(separator: ", ")
        notes = adapter.notes
        bodyText = prettyProtocol(adapter.protocolBody)
        loadDownloadState(from: adapter)
        testView = viewNames.first ?? ""
    }

    private func loadDownloadState(from adapter: DPPAdapter) {
        loadedDownload = adapter.download
        downloadEnabled = adapter.download != nil
        downloadDraft = DPPDownloadRulesEditing.draft(from: adapter.download)
        downloadJSON = adapter.download.map(DPPDownloadRulesEditing.json) ?? "{}"
        downloadMeasured = DPPDownloadRulesEditing.measuredSummary(adapter.download?.measured)
        downloadEditingJSON = false
        downloadErrors = []
    }

    private func resetDownloadState() {
        loadedDownload = nil
        downloadEnabled = false
        downloadDraft = DPPDownloadRulesDraft()
        downloadJSON = "{}"
        downloadMeasured = nil
        downloadEditingJSON = false
        downloadErrors = []
    }

    private func loadTemplate() {
        name = DPPOpsContract.suggestedName(host: initialHost ?? "", platform: initialPlatform ?? "")
        if hosts.isEmpty, let host = initialHost, !host.isEmpty { hosts = host }
        notes = "ops adapter — replace placeholder selectors, test on the page, then enable."
        bodyText = DPPOpsContract.templateProtocolJSON(channelSlug: (initialPlatform ?? "").lowercased())
        errors = []
        warnings = []
        testOutput = nil
        resetDownloadState()
        testView = viewNames.first ?? ""
    }

    private func loadInstalled() {
        guard let adapter = adapters.adapters.first(where: { !hosts.isEmpty && $0.matchesHost(hosts.split(separator: ",").first.map(String.init) ?? "") })
            ?? adapters.adapters.first else { return }
        fill(from: adapter)
        saveNote = nil
    }

    private func formatJSON() {
        guard let proto = tryDecode() else { return }
        bodyText = prettyProtocol(proto)
    }

    private func validateNow() {
        errors = []
        warnings = []
        guard let proto = tryDecode() else { return }
        let structural = DPPAdapterAuthoring.validate(name: name, hosts: hostList, pathPrefixes: pathList)
        let ops = DPPOpsContract.report(for: proto)
        let download = resolveDownloadRules()
        downloadErrors = download.errors
        errors = structural + ops.errors + download.errors
        warnings = ops.warnings
    }

    /// 下载段：开关关 → nil；JSON 模式以 JSON 为真相；表单模式保留实测/修订/未暴露字段。
    private func resolveDownloadRules() -> (rules: DPPDownloadRules?, errors: [String]) {
        guard downloadEnabled else { return (nil, []) }
        if downloadEditingJSON {
            let parsed = DPPDownloadRulesEditing.parse(json: downloadJSON)
            if let error = parsed.error { return (nil, [error]) }
            let rules = parsed.rules ?? DPPDownloadRules()
            return (rules, DPPDownloadRulesEditing.validate(rules))
        }
        let built = DPPDownloadRulesEditing.rules(from: downloadDraft, preserving: loadedDownload)
        return (built.rules, built.errors)
    }

    private func saveDraft() {
        validateNow()
        guard errors.isEmpty, let proto = tryDecode() else { return }
        let downloadRules = resolveDownloadRules().rules
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var adapter = DPPAdapter(
            name: trimmedName,
            hosts: hostList,
            pathPrefixes: pathList,
            protocolBody: proto,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            opsVersion: DPPOpsContract.report(for: proto).isOps ? DPPOpsContract.version : nil,
            verifiedAt: Date(),
            download: downloadRules)
        adapter.protocolBody.warnings.append("adapter: \(trimmedName)")
        do {
            try adapters.saveDraft(adapter)
            loadedDownload = downloadRules
            downloadMeasured = DPPDownloadRulesEditing.measuredSummary(downloadRules?.measured)
            if enableAfterSave {
                adapters.setEnabled(true, for: trimmedName)
                saveNote = String(localized: "Saved and enabled: \(trimmedName)")
            } else {
                saveNote = String(localized: "Saved disabled: \(trimmedName). Enable it in Settings › AI › DPP Protocol › Third-Party Adapters.")
            }
        } catch {
            errors = [error.localizedDescription]
        }
    }

    private func runTest() {
        guard let proto = tryDecode() else { return }
        let viewName = testView.isEmpty ? (viewNames.first ?? "") : testView
        guard let view = proto.views[viewName] else {
            testOutput = String(localized: "No view named \(viewName).")
            return
        }
        guard let webView = TabSessionCoordinator.shared.activeTabManager?.selectedTab?.browser.webView else {
            testOutput = String(localized: "No active browser tab.")
            return
        }
        testOutput = String(localized: "Running…")
        webView.evaluateJavaScript(testScript(view: view)) { value, error in
            Task { @MainActor in
                if let error {
                    testOutput = "JS error: \(error.localizedDescription)"
                } else if let text = value as? String {
                    let native = TabSessionCoordinator.shared.activeTabManager?.selectedTab?.browser.pageProtocol != nil
                    testOutput = (native ? String(localized: "Note: this page already declares DPP — native declarations win over adapters.\n\n") : "")
                        + text
                } else {
                    testOutput = "nil"
                }
            }
        }
    }

    // MARK: - Parsing

    private var hostList: [String] {
        hosts.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var pathList: [String] {
        pathPrefixes.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func tryDecode(reportErrors: Bool = true) -> DesireProtocol? {
        guard let data = bodyText.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(DesireProtocol.self, from: data)
        } catch {
            if reportErrors {
                errors = [String(localized: "Protocol JSON is invalid: \(error.localizedDescription)")]
            }
            return nil
        }
    }

    private func prettyProtocol(_ proto: DesireProtocol) -> String {
        Self.prettyJSON(proto)
    }

    private static func prettyJSON(_ proto: DesireProtocol) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(proto),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 只读抽取脚本（item + 字段文本/属性；不支持 shadow DOM `>>>` 与类型强转——
    /// 完整语义在启用后由 pageExtract 执行）。
    private func testScript(view: DesireProtocol.ProtocolView) -> String {
        var fields: [String: String] = [:]
        for (key, spec) in view.fields { fields[key] = spec.expression }
        let payload: [String: Any] = ["item": view.item, "fields": fields]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function(){
          var v = \(json);
          var items = document.querySelectorAll(v.item);
          var rows = [];
          for (var i = 0; i < items.length && i < 5; i++) {
            var item = items[i];
            var row = {};
            for (var key in v.fields) {
              var expr = v.fields[key] || '';
              var sel = expr, attr = '';
              var at = expr.lastIndexOf('@');
              if (at > 0) { sel = expr.slice(0, at); attr = expr.slice(at + 1); }
              else if (expr.charAt(0) === '@') { sel = ''; attr = expr.slice(1); }
              var val = '';
              try {
                if (!sel) { val = attr ? item.getAttribute(attr) : item.textContent; }
                else { var el = item.querySelector(sel); if (el) { val = attr ? el.getAttribute(attr) : el.textContent; } }
              } catch (e) {}
              row[key] = String(val == null ? '' : val).replace(/\\s+/g, ' ').trim().slice(0, 140);
            }
            rows.push(row);
          }
          return JSON.stringify({ count: items.length, rows: rows }, null, 2);
        })()
        """
    }
}
