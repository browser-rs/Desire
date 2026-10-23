import SwiftUI

/// 增长实验编辑器（v0.8.3）：假设 + 变体 + 主指标 + 计划样本。
/// 帖子仍用 variantLabel 标记；这里只定义"跑够多少篇才允许下结论"。
struct PromotionExperimentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var store = PromotionStore.shared
    let experiment: PromotionExperiment?

    @State private var title: String
    @State private var hypothesis: String
    @State private var campaignID: UUID?
    @State private var metric: PromotionExperiment.Metric
    @State private var variantsText: String
    @State private var plannedSamples: Int
    @State private var error: String?

    init(experiment: PromotionExperiment? = nil) {
        self.experiment = experiment
        _title = State(initialValue: experiment?.title ?? "")
        _hypothesis = State(initialValue: experiment?.hypothesis ?? "")
        _campaignID = State(initialValue: experiment?.campaignID)
        _metric = State(initialValue: experiment?.metric ?? .views)
        _variantsText = State(initialValue: (experiment?.variants ?? ["A", "B"]).joined(separator: ", "))
        _plannedSamples = State(initialValue: experiment?.plannedSamples ?? 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "flask")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(appAccent)
                Text(experiment == nil ? String(localized: "New Experiment") : String(localized: "Edit Experiment"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            formRow(String(localized: "Title")) {
                TextField("", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
            }
            formRow(String(localized: "Hypothesis")) {
                TextField("", text: $hypothesis)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
            }
            formRow(String(localized: "Campaign")) {
                Picker("", selection: $campaignID) {
                    Text(String(localized: "Any campaign")).tag(UUID?.none)
                    ForEach(store.campaigns) { campaign in
                        Text(campaign.title).tag(UUID?.some(campaign.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
            }
            HStack(spacing: 14) {
                formRow(String(localized: "Metric")) {
                    Picker("", selection: $metric) {
                        ForEach(PromotionExperiment.Metric.allCases, id: \.self) { metric in
                            Text(metric.label).tag(metric)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
                formRow(String(localized: "Samples per variant")) {
                    Stepper(value: $plannedSamples, in: 1...50) {
                        Text("\(plannedSamples)")
                            .font(.system(size: 11.5, design: .monospaced))
                    }
                    .controlSize(.small)
                }
            }
            formRow(String(localized: "Variants")) {
                TextField("A, B", text: $variantsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
            }
            Text(String(localized: "Posts are matched by variant label and published status. A conclusion is only allowed when every variant reaches the planned sample size."))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(String(localized: "Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 560, height: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            content()
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            error = String(localized: "Title is required.")
            return
        }
        let variants = PromotionExperiment.cleanVariants(
            variantsText.split(separator: ",").map(String.init))
        guard variants.count >= 2 else {
            error = String(localized: "At least two variants are required.")
            return
        }
        var value = experiment ?? PromotionExperiment(
            title: cleanTitle,
            hypothesis: hypothesis,
            campaignID: campaignID,
            metric: metric,
            variants: variants,
            plannedSamples: plannedSamples)
        value.title = cleanTitle
        value.hypothesis = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        value.campaignID = campaignID
        value.metric = metric
        value.variants = variants
        value.plannedSamples = max(1, plannedSamples)
        _ = store.saveExperiment(value)
        dismiss()
    }
}
