import SwiftUI

/// 设置 →「页面监视」：PageWatch 管理 UI（v0.7.5）。
/// 列表（开关/立即检查/删除/最近分析）+ 添加表单 + AI 分析开关。
/// PageWatchStore 自带 20s 时钟与通知，这里只做配置与展示。
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
    @State private var expandedName: String?

    var body: some View {
        SettingsSection(
            title: String(localized: "Page Watch"),
            subtitle: String(localized: "Watch a page (or a CSS selector on it) for changes on a schedule. With AI analysis, each change is summarized by the agent — the result arrives as a notification and is kept under the watch."),
            icon: "eye"
        ) {
            VStack(spacing: 0) {
                if store.watches.isEmpty {
                    HStack {
                        Text(String(localized: "No watches yet — add one below."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                } else {
                    ForEach(store.watches, id: \.id) { watch in
                        watchRow(watch)
                        SettingsRowDivider()
                    }
                }
                addForm
            }
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func watchRow(_ watch: PageWatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(watch.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(watch.url)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if watch.wantsAIAnalysis {
                    Text(String(localized: "AI"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(appAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(appAccent.opacity(0.14)))
                }
                Button(String(localized: "Check Now")) {
                    checkingName = watch.name
                    Task {
                        _ = await store.check(named: watch.name)
                        checkingName = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(checkingName == watch.name)
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
            HStack(spacing: 10) {
                Text(String(localized: "Every \(watch.intervalMinutes) min"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if watch.changeCount > 0 {
                    Text(String(localized: "\(watch.changeCount) changes"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if let err = watch.lastError, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
                Toggle(String(localized: "AI Analysis"), isOn: Binding(
                    get: { watch.wantsAIAnalysis },
                    set: { store.setAIAnalysis($0, for: watch.name) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }
            if let analysis = watch.lastAnalysis, !analysis.isEmpty {
                Text(analysis)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(expandedName == watch.name ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
                    .onTapGesture {
                        expandedName = expandedName == watch.name ? nil : watch.name
                    }
            }
            if checkingName == watch.name {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - 添加表单

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRowDivider()
            Text(String(localized: "Add Watch"))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    TextField(String(localized: "Name"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    TextField("https://example.com", text: $newURL)
                        .textFieldStyle(.roundedBorder)
                    TextField(String(localized: "CSS selector (optional)"), text: $newSelector)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                HStack(spacing: 8) {
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
                        .font(.system(size: 11))
                    Spacer()
                    Button(String(localized: "Add")) { add() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addError {
                    Text(addError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
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
