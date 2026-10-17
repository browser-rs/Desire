import SwiftUI

/// 书签导入去重向导：把解析结果与现有书签库对照后**先给用户看**再落库。
/// 两个出口——「跳过重复导入」只保留全新条目（默认）／「全部导入」连着
/// 重复条目一起保留；重复清单只读展示（标题 + URL，超出截断说明）。
struct BookmarkImportDedupeSheet: View {
    let sourceName: String
    let plan: BookmarkImportDedupe.Plan
    let onCancel: () -> Void
    /// keepDuplicates: true = 全部导入（不跳过）；false = 只导入全新条目。
    let onCommit: (_ keepDuplicates: Bool) -> Void

    private let maxRows = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Bookmarks")
                .font(.headline)
            Text(sourceName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(String(localized: "Bookmarks in file"), value: "\(plan.total)")
                LabeledContent(String(localized: "New bookmarks"), value: "\(plan.fresh)")
                if !plan.existingDuplicates.isEmpty {
                    LabeledContent(String(localized: "Already in your library"),
                                   value: "\(plan.existingDuplicates.count)")
                }
                if !plan.innerDuplicates.isEmpty {
                    LabeledContent(String(localized: "Duplicates within the file"),
                                   value: "\(plan.innerDuplicates.count)")
                }
            }
            .font(.callout)

            if plan.hasDuplicates {
                Text("Duplicate entries are skipped by default. \"Import All\" keeps both copies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(duplicateRows.prefix(maxRows).enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(row.title.isEmpty ? row.url : row.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Text(row.kind.isExisting
                                         ? String(localized: "in library")
                                         : String(localized: "in file")
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                                }
                                Text(row.url)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if duplicateRows.count > maxRows {
                            Text(String(localized: "…and more") + " (\(duplicateRows.count - maxRows))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                if plan.hasDuplicates {
                    Button("Import All") { onCommit(true) }
                }
                Button(plan.hasDuplicates
                       ? String(localized: "Import New Only") + " · \(plan.fresh)"
                       : String(localized: "Import")) {
                    onCommit(false)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var duplicateRows: [BookmarkImportDedupe.Row] {
        plan.existingDuplicates + plan.innerDuplicates
    }
}
