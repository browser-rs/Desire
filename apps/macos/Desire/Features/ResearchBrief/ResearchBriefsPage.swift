import AppKit
import SwiftUI

/// 研究简报页（v0.8.50 批 4）：`desire://research`。
/// 左列 = 新建 + 历史列表；右列 = 选中简报的正文/来源/操作。
struct ResearchBriefsPage: View {
    @ObservedObject private var store = ResearchBriefStore.shared
    @State private var selectedID: UUID?
    @State private var topic = ""
    @State private var template: ResearchBriefTemplate = .summary
    @State private var depth = 6

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if selectedID == nil { selectedID = store.briefs.first?.id }
        }
    }

    // MARK: 左列

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Research briefs"))
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                TextField(String(localized: "Topic"), text: $topic)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit(start)
                HStack(spacing: 8) {
                    Picker("", selection: $template) {
                        Text(String(localized: "Summary")).tag(ResearchBriefTemplate.summary)
                        Text(String(localized: "Comparison")).tag(ResearchBriefTemplate.compare)
                        Text(String(localized: "Timeline")).tag(ResearchBriefTemplate.timeline)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    Stepper(value: $depth, in: 3...12) {
                        Text("\(depth)")
                            .font(.system(size: 10, design: .monospaced))
                    }
                    .frame(width: 80)
                }
                Button(String(localized: "Start research")) { start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.briefs) { document in
                        Button {
                            selectedID = document.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.topic)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(document.state.rawValue)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(document.state == .failed ? .red : .secondary)
                                    Text("\(document.sources.count)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                    Text(document.createdAt, style: .date)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(selectedID == document.id ? AnyShapeStyle(.tint.opacity(0.14))
                                                                : AnyShapeStyle(Color.clear)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }

    // MARK: 右列

    @ViewBuilder
    private var detail: some View {
        // 未显式选中时展示最新一份（新建完成后自动可见）。
        let document = (selectedID.flatMap { store.document(id: $0) } ?? store.briefs.first)
        if let document {
            briefDetail(document)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "Select a brief or create one."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func briefDetail(_ document: ResearchBriefDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(document.topic)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Spacer()
                if ResearchBriefService.shared.isRunning(document.id) {
                    ProgressView().controlSize(.small)
                    Button(String(localized: "Cancel run")) {
                        ResearchBriefService.shared.cancel(id: document.id)
                    }
                    .controlSize(.small)
                } else {
                    Button(String(localized: "Export to Downloads")) {
                        _ = ResearchBriefStore.shared.exportToDownloads(document)
                    }
                    .controlSize(.small)
                    Button(String(localized: "Reveal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [ResearchBriefStore.shared.markdownURL(id: document.id)])
                    }
                    .controlSize(.small)
                    Button(String(localized: "Delete brief"), role: .destructive) {
                        ResearchBriefStore.shared.delete(id: document.id)
                        selectedID = store.briefs.first?.id
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 12) {
                Text("\(document.sources.count) \(String(localized: "sources"))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if document.unverifiedQuotes > 0 {
                    Text("⚠️ \(document.unverifiedQuotes)")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                if let error = document.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(document.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 4) {
                            if !section.heading.isEmpty {
                                Text(section.heading)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            Text(section.markdown)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                        }
                    }
                    if !document.sources.isEmpty {
                        Divider()
                        Text(String(localized: "Sources"))
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(document.sources) { source in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(source.id).")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Button {
                                        if let url = URL(string: source.url) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    } label: {
                                        Text(source.title.isEmpty ? source.url : source.title)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.tint)
                                    HStack(spacing: 6) {
                                        Text(source.domain)
                                        if source.gated { Text(String(localized: "gated")) }
                                        if let note = source.note { Text(note) }
                                    }
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .padding(14)
    }

    private func start() {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let document = ResearchBriefService.shared.start(
            topic: trimmed, depth: depth,
            language: Self.isEnglishUI() ? "en" : "zh-Hans",
            template: template, conversationID: nil)
        selectedID = document.id
    }

    private static func isEnglishUI() -> Bool {
        (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("en")
    }
}
