import SwiftUI

/// 新建运营战役（v0.8.2）：版本/亮点/平台/起点 → 确定性生成各平台草稿。
/// 草稿只入库待审，绝不自动发布。
struct PromotionCampaignEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PromotionStore.shared

    @State private var version = WhatsNewStore.shared.versionName
    @State private var title = ""
    @State private var objective = ""
    @State private var productURL = "https://desire.mankong.icu/"
    @State private var highlights = ""
    @State private var selectedSlugs: Set<String> = ["x", "v2ex", "xiaohongshu", "juejin"]
    @State private var startDate = Date()
    @State private var generated = false

    private var chosenChannels: [PromotionChannel] {
        PromotionChannel.presets.filter { selectedSlugs.contains($0.slug) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Campaign")
                    .font(.system(size: 15, weight: .semibold))
                Text("Generates per-channel drafts from facts you provide. Nothing is published automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Version").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("0.8.2", text: $version)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Title").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("Desire v0.8.2 发布", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Goal").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("One sentence: what should this campaign achieve?", text: $objective)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Product URL").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    TextField("https://desire.mankong.icu/", text: $productURL)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Start").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    DatePicker("", selection: $startDate, displayedComponents: .date)
                        .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Highlights (one per line, 3–5, facts only)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextEditor(text: $highlights)
                    .font(.system(size: 12))
                    .frame(height: 84)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Channels").font(.system(size: 11.5)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(PromotionChannel.presets) { channel in
                        Toggle(channel.platform, isOn: Binding(
                            get: { selectedSlugs.contains(channel.slug) },
                            set: { on in
                                if on { selectedSlugs.insert(channel.slug) }
                                else { selectedSlugs.remove(channel.slug) }
                            }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    }
                }
            }

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text(String(localized: "\(chosenChannels.count) channel(s) · drafts stay in review"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(generated ? String(localized: "Generated") : String(localized: "Generate Drafts")) {
                    generate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(validationError != nil || generated)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private var validationError: String? {
        if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Version is required."
        }
        if highlights.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty }).isEmpty {
            return "Add at least one factual highlight."
        }
        if chosenChannels.isEmpty { return "Pick at least one channel." }
        let url = productURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(string: url) == nil { return "Product URL is invalid." }
        return nil
    }

    private func generate() {
        let lines = highlights.split(separator: "\n").map(String.init)
        let brief = PromotionCampaignBuilder.Brief(
            version: version,
            title: title,
            objective: objective,
            productURL: productURL,
            highlights: lines,
            startDate: startDate,
            channels: chosenChannels)
        if store.generateCampaign(brief) != nil {
            generated = true
            dismiss()
        }
    }
}
