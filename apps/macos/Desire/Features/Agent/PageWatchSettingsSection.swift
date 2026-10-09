import SwiftUI

/// 设置 →「页面监视」：PageWatch 管理 UI（v0.7.5）。
/// 每个 watch 一组规范行（主行 / AI 分析 / 最近分析），添加走 SettingsFieldRow
/// 表单——与全设置页风格一致（此前自绘行被批"与其他设置页面风格不搭"）。
struct PageWatchSettingsSection: View {
    @ObservedObject private var store = PageWatchStore.shared
    @Environment(\.appAccent) private var appAccent: Color
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newSelector = ""
    @State private var newMinutes = 30
    @State private var newAI = false
    @State private var addError: String?
    @State private var checkingName: String?

    var body: some View {
        // SettingsContainer：720pt 限宽居中 + 内边距（其他设置子页同款——
        // 此前缺失导致卡片全宽贴边，与全页风格不符）。
        SettingsContainer {
            section
        }
    }

    private var section: some View {
        SettingsSection(
            title: String(localized: "Page Watch"),
            subtitle: String(localized: "Watch a page (or a CSS selector on it) for changes on a schedule. With AI analysis, each change is summarized by the agent — the result arrives as a notification and is kept under the watch."),
            icon: "eye"
        ) {
            VStack(spacing: 0) {
                if store.watches.isEmpty {
                    Text(String(localized: "No watches yet — add one below."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                } else {
                    ForEach(store.watches, id: \.id) { watch in
                        watchRows(watch)
                    }
                }
                addForm
            }
        }
    }

    // MARK: - 单个 watch（规范行组）

    @ViewBuilder
    private func watchRows(_ watch: PageWatch) -> some View {
        SettingsRow(watch.name, subtitle: watch.url) {
            HStack(spacing: 8) {
                if checkingName == watch.name {
                    ProgressView().controlSize(.small)
                } else {
                    Button(String(localized: "Check Now")) {
                        checkingName = watch.name
                        Task {
                            _ = await store.check(named: watch.name)
                            checkingName = nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Toggle("", isOn: Binding(
                    get: { watch.isEnabled },
                    set: { store.setEnabled($0, for: watch.name) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                Button {
                    _ = store.remove(named: watch.name)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Delete watch"))
            }
        }
        SettingsRowDivider(leading: 14)
        SettingsRow(
            String(localized: "AI Analysis"),
            subtitle: watchMetaText(watch)
        ) {
            Toggle("", isOn: Binding(
                get: { watch.wantsAIAnalysis },
                set: { store.setAIAnalysis($0, for: watch.name) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        if let analysis = watch.lastAnalysis, !analysis.isEmpty {
            SettingsRowDivider(leading: 14)
            SettingsFieldRow(String(localized: "Latest Analysis")) {
                Text(analysis)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
            }
        }
        SettingsRowDivider()
    }

    /// 行副标题：间隔 · 变化次数 · 错误（有则显示）。
    private func watchMetaText(_ watch: PageWatch) -> String {
        var parts: [String] = []
        parts.append(String(localized: "Every \(watch.intervalMinutes) min"))
        if watch.changeCount > 0 {
            parts.append(String(localized: "\(watch.changeCount) changes"))
        }
        if let err = watch.lastError, !err.isEmpty {
            parts.append(err)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 添加表单（SettingsFieldRow 规范）

    private var addForm: some View {
        VStack(spacing: 0) {
            SettingsRowDivider()
            SettingsFieldRow(String(localized: "Name")) {
                TextField(String(localized: "Name"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            SettingsRowDivider(leading: SettingsMetrics.fieldLabelWidth)
            SettingsFieldRow(String(localized: "URL")) {
                TextField("https://example.com", text: $newURL)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRowDivider(leading: SettingsMetrics.fieldLabelWidth)
            SettingsFieldRow(String(localized: "CSS selector (optional)")) {
                TextField(String(localized: "CSS selector (optional)"), text: $newSelector)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRowDivider(leading: SettingsMetrics.fieldLabelWidth)
            SettingsFieldRow(String(localized: "Interval")) {
                HStack(spacing: 12) {
                    Picker(String(localized: "Interval"), selection: $newMinutes) {
                        Text(String(localized: "Every 5 min")).tag(5)
                        Text(String(localized: "Every 15 min")).tag(15)
                        Text(String(localized: "Every 30 min")).tag(30)
                        Text(String(localized: "Every 60 min")).tag(60)
                        Text(String(localized: "Every 360 min")).tag(360)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .pickerStyle(.menu)
                    Toggle(String(localized: "AI Analysis"), isOn: $newAI)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                }
            }
            SettingsRowDivider()
            HStack {
                Spacer()
                if let addError {
                    Text(addError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Button(String(localized: "Add")) { add() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func add() {
        let trimmedSelector = newSelector.trimmingCharacters(in: .whitespaces)
        if store.add(name: newName, url: newURL,
                     selector: trimmedSelector.isEmpty ? nil : trimmedSelector,
                     minutes: newMinutes, aiAnalysis: newAI) == nil {
            addError = String(localized: "Invalid name or URL")
            return
        }
        newName = ""; newURL = ""; newSelector = ""; newMinutes = 30; newAI = false
        addError = nil
    }
}
