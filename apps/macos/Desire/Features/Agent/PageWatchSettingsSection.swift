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
    @State private var newNumericSelector = ""
    @State private var newAlertBelow = ""
    @State private var newAlertAbove = ""
    @State private var addError: String?
    @State private var checkingName: String?
    @State private var showsCenter = false

    var body: some View {
        // SettingsContainer：720pt 限宽居中 + 内边距（其他设置子页同款——
        // 此前缺失导致卡片全宽贴边，与全页风格不符）。
        SettingsContainer {
            section
        }
        .sheet(isPresented: $showsCenter) {
            PageWatchCenterSheet()
        }
    }

    private var section: some View {
        SettingsSection(
            title: String(localized: "Page Watch"),
            subtitle: String(localized: "Watch a page (or a CSS selector on it) for changes on a schedule. With AI analysis, each change is summarized by the agent — the result arrives as a notification and is kept under the watch."),
            icon: "eye"
        ) {
            VStack(spacing: 0) {
                SettingsRow("Watch Center", subtitle: String(localized: "All watches, latest changes and a copyable 24h digest.")) {
                    SettingsCapsuleButton("Open", style: .secondary) {
                        showsCenter = true
                    }
                }
                SettingsRowDivider(leading: 14)
                SettingsRow(String(localized: "Daily digest"),
                            subtitle: String(localized: "Once a day, notify one 24h summary of changes, alerts and errors. Timestamps, relative times and view counters are ignored when diffing (noise filter).")) {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(
                            get: { store.digestHour },
                            set: { store.setDigest(enabled: store.digestEnabled, hour: $0) })) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(String(format: "%02d:00", hour)).tag(hour)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 78)
                        .disabled(!store.digestEnabled)
                        Toggle("", isOn: Binding(
                            get: { store.digestEnabled },
                            set: { store.setDigest(enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
                SettingsRowDivider(leading: 14)
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
        if watch.watchesNumbers {
            SettingsRowDivider(leading: 14)
            SettingsRow(
                String(localized: "Number Tracking"),
                subtitle: numericMetaText(watch)
            ) {
                if let points = watch.valueHistory, points.count >= 2 {
                    Sparkline(values: points.map(\.value))
                        .frame(width: 56, height: 16)
                }
            }
        }
        if let alert = watch.lastAlert, !alert.isEmpty {
            SettingsRowDivider(leading: 14)
            SettingsFieldRow(String(localized: "Last Alert")) {
                Text(alert)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    /// 数值行副标题：最新值 · 笔数 · 阈值。
    private func numericMetaText(_ watch: PageWatch) -> String {
        var parts: [String] = []
        if let latest = watch.latestValue {
            parts.append(String(format: String(localized: "latest %@"), String(format: "%.2f", latest)))
        } else {
            parts.append(String(localized: "no readings yet"))
        }
        parts.append(String(localized: "\(watch.valueHistory?.count ?? 0) readings"))
        if let below = watch.alertBelow {
            parts.append(String(format: String(localized: "alert below %@"), String(format: "%.2f", below)))
        }
        if let above = watch.alertAbove {
            parts.append(String(format: String(localized: "alert above %@"), String(format: "%.2f", above)))
        }
        if let selector = watch.numericSelector {
            parts.append(selector)
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
            SettingsFieldRow(String(localized: "Number selector (optional)")) {
                TextField(".price", text: $newNumericSelector)
                    .textFieldStyle(.roundedBorder)
            }
            SettingsRowDivider(leading: SettingsMetrics.fieldLabelWidth)
            SettingsFieldRow(String(localized: "Alert thresholds")) {
                HStack(spacing: 8) {
                    Text(String(localized: "below"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    TextField("1200", text: $newAlertBelow)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text(String(localized: "above"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    TextField("—", text: $newAlertAbove)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
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
        let trimmedNumeric = newNumericSelector.trimmingCharacters(in: .whitespaces)
        if store.add(name: newName, url: newURL,
                     selector: trimmedSelector.isEmpty ? nil : trimmedSelector,
                     minutes: newMinutes, aiAnalysis: newAI,
                     numericSelector: trimmedNumeric.isEmpty ? nil : trimmedNumeric,
                     alertAbove: Double(newAlertAbove.trimmingCharacters(in: .whitespaces)),
                     alertBelow: Double(newAlertBelow.trimmingCharacters(in: .whitespaces))) == nil {
            addError = String(localized: "Invalid name or URL")
            return
        }
        newName = ""; newURL = ""; newSelector = ""; newMinutes = 30; newAI = false
        newNumericSelector = ""; newAlertBelow = ""; newAlertAbove = ""
        addError = nil
    }
}

/// 数值历史迷你走势（56×16 固定小图；两点以上才画）。
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let span = max(maxV - minV, 0.000_001)
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = geo.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = geo.size.height * (1 - CGFloat((value - minV) / span))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.orange.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}
