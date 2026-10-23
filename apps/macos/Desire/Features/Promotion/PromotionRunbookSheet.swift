import SwiftUI

/// 发布日 Runbook 生成/勾选（v0.8.3）。模板只生成相对时间线；具体发布/回复
/// 动作仍走 Agent + 审批，这里不自动执行任何公开动作。
struct PromotionRunbookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var store = PromotionStore.shared
    let campaign: PromotionCampaign

    @State private var template: PromotionRunbook.Template = .release
    @State private var startDate: Date
    @State private var showTemplate = false

    init(campaign: PromotionCampaign) {
        self.campaign = campaign
        _startDate = State(initialValue: campaign.startsAt ?? Date())
    }

    private var liveCampaign: PromotionCampaign? {
        store.campaigns.first { $0.id == campaign.id } ?? campaign
    }

    private var steps: [PromotionRunbookStep] {
        liveCampaign?.runbook ?? []
    }

    private var preview: [PromotionRunbookStep] {
        PromotionRunbook.steps(template: template, version: campaign.version,
                               platforms: campaign.platforms, start: startDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if steps.isEmpty || showTemplate {
                generator
            } else {
                existingSteps
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: 580, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(appAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Launch Runbook"))
                    .font(.system(size: 13, weight: .semibold))
                Text(campaign.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !steps.isEmpty && !showTemplate {
                Button(String(localized: "Regenerate…")) { showTemplate = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var generator: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker(String(localized: "Template"), selection: $template) {
                    ForEach(PromotionRunbook.Template.allCases) { template in
                        Text(template.label).tag(template)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
                DatePicker(String(localized: "Start date"), selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
            }
            Text(template.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if campaign.platforms.isEmpty {
                Text(String(localized: "This campaign has no platforms yet — add channels before generating a release runbook."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(preview) { step in
                        HStack(spacing: 6) {
                            Image(systemName: step.kind.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(appAccent)
                                .frame(width: 14)
                            Text(step.title)
                                .font(.system(size: 11))
                            if !step.platform.isEmpty {
                                Text(step.platform)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(Self.dayString(PromotionRunbook.date(for: step, start: startDate)))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let capability = step.capability {
                                Text(capability)
                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 280)
            if !steps.isEmpty {
                Text(String(localized: "Regenerating replaces the current steps and clears their manual checkmarks."))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var existingSteps: some View {
        let campaignID = campaign.id
        let posts = store.posts
        let progress = PromotionRunbook.progress(steps: steps, campaignID: campaignID, posts: posts)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: String(localized: "%lld of %lld done"), progress.done, progress.total))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let start = liveCampaign?.startsAt {
                    Text(Self.dayString(start))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(steps) { step in
                        stepRow(step, campaignID: campaignID, posts: posts)
                    }
                }
            }
        }
    }

    private func stepRow(_ step: PromotionRunbookStep,
                         campaignID: UUID, posts: [PromotionPost]) -> some View {
        let auto = PromotionRunbook.isSatisfied(step, campaignID: campaignID, posts: posts)
        let complete = PromotionRunbook.isComplete(step, campaignID: campaignID, posts: posts)
        let date = liveCampaign?.startsAt.map {
            PromotionRunbook.date(for: step, start: $0)
        }
        return HStack(alignment: .top, spacing: 7) {
            Toggle("", isOn: Binding(
                get: { complete },
                set: { store.markRunbookStep(campaignID, stepID: step.id, done: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(auto)
            Image(systemName: step.kind.icon)
                .font(.system(size: 10))
                .foregroundStyle(appAccent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(step.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .strikethrough(complete, color: .secondary)
                    if auto {
                        Text(String(localized: "auto"))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
                HStack(spacing: 6) {
                    if !step.platform.isEmpty {
                        Text(step.platform)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    if let date {
                        Text(Self.dayString(date))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let capability = step.capability {
                        Text(capability)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45)))
    }

    private var footer: some View {
        HStack {
            if showTemplate {
                Button(String(localized: "Cancel")) { showTemplate = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Spacer()
            if !preview.isEmpty && (steps.isEmpty || showTemplate) {
                Button(String(localized: "Generate Runbook")) {
                    _ = store.updateCampaign(campaign.id, startsAt: .some(startDate))
                    _ = store.setRunbook(campaign.id, steps: preview)
                    showTemplate = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Button(String(localized: "Close")) { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter.string(from: date)
    }
}
