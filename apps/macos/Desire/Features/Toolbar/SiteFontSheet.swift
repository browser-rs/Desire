import SwiftUI

/// 站点字体设置弹层（工具栏「Page Font…」）：最小字号 + 字体族两块。
/// 每改一项**立即重注入**（onReapply 回调）——用户当场看到页面变化，
/// 不用刷新。"跟随默认"档 = 删除站点覆盖（nil），回全局设置值。
struct SiteFontSheet: View {
    let host: String
    @ObservedObject var store: SiteSettingsStore
    let onReapply: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Site Font")
                    .font(.headline)
                Text(host)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("Minimum Font Size", selection: minSelection) {
                Text(followDefaultLabel).tag(Optional<Int>.none)
                ForEach(SiteFont.sizeChoices, id: \.self) { size in
                    Text(size == 0 ? String(localized: "Off") : "\(size) px")
                        .tag(Optional(size))
                }
            }

            Picker("Font Family", selection: familySelection) {
                Text("Follow Default").tag(Optional<String>.none)
                ForEach(SiteFont.familyChoices, id: \.self) { family in
                    Text(family.isEmpty ? String(localized: "Off") : family)
                        .tag(Optional(family))
                }
            }

            Text("Minimum size raises text smaller than the limit. Font family only affects pages that do not set their own fonts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// "跟随默认"标签带上生效值（开着默认时用户能看到它会回到哪一档）。
    private var followDefaultLabel: String {
        let base = String(localized: "Follow Default")
        let global = store.defaultFont.minFontSize
        return global > 0 ? "\(base) · \(global) px" : base
    }

    private var minSelection: Binding<Int?> {
        Binding(
            get: { store.fontOverride(for: host).min },
            set: { value in
                store.setMinFontSize(value, for: host)
                onReapply()
            }
        )
    }

    private var familySelection: Binding<String?> {
        Binding(
            get: { store.fontOverride(for: host).family },
            set: { value in
                store.setFontFamily(value, for: host)
                onReapply()
            }
        )
    }
}
