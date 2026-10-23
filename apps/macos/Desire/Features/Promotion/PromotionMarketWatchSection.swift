import Foundation
import SwiftUI

/// 竞品/市场监测（v0.8.3）：来源列表 + 后台只读检查 + 变化摘要。
/// 没有变化时保持安静；变化可直接交给 Agent 转成选题。
struct PromotionMarketWatchSection: View {
    @ObservedObject private var store = PromotionStore.shared
    @Environment(\.appAccent) private var appAccent
    let onSendToAgent: ((String) -> Void)?

    @State private var adding = false
    @State private var editing: PromotionCompetitorSource?
    @State private var checking: Set<UUID> = []
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "binoculars")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appAccent)
                Text(String(localized: "Market Watch"))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(store.competitorSources.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(String(localized: "Add Source")) { adding = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(appAccent)
            }
            if store.competitorSources.isEmpty {
                Text(String(localized: "Watch competitor pricing/feature/changelog pages. Checks run in a background tab and only report changed lines."))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(store.competitorSources) { source in
                    sourceRow(source)
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $adding) { PromotionCompetitorEditorSheet() }
        .sheet(item: $editing) { source in
            PromotionCompetitorEditorSheet(source: source)
        }
    }

    private func sourceRow(_ source: PromotionCompetitorSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(source.lastChangeAt == nil ? Color.secondary.opacity(0.35) : Color.orange)
                    .frame(width: 6, height: 6)
                Text(source.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(host(source.url))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !source.isEnabled {
                    Text(String(localized: "disabled"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                if let checked = source.lastCheckedAt {
                    Text(Self.relative(checked))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    check(source)
                } label: {
                    if checking.contains(source.id) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(String(localized: "Check"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!source.isEnabled || checking.contains(source.id))
                Button(String(localized: "Edit")) { editing = source }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    store.removeCompetitorSource(source.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let summary = source.lastChangeSummary, !summary.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text(summary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    if let onSendToAgent {
                        Button(String(localized: "Make topic")) {
                            onSendToAgent("市场监测「\(source.name)」有变化：\(summary)。把这变化转成一条选题（promotionSave status=idea，附来源 \(source.url)），说明为什么值得写；不要发布。")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(appAccent)
                    }
                }
            } else if !source.note.isEmpty {
                Text(source.note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }

    private func check(_ source: PromotionCompetitorSource) {
        checking.insert(source.id)
        message = nil
        Task { @MainActor in
            let result = await PromotionCompetitorChecker.check(source: source)
            checking.remove(source.id)
            guard let result else {
                message = String(localized: "Could not check \(source.name).")
                return
            }
            if result.changed {
                message = String(localized: "\(source.name): \(result.summary)")
            } else {
                message = String(localized: "\(source.name): no changes (\(result.lines) lines).")
            }
        }
    }

    private func host(_ raw: String) -> String {
        URL(string: raw)?.host ?? raw
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
