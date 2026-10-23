import SwiftUI

/// 竞品/市场监测来源编辑器（v0.8.3）。
struct PromotionCompetitorEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @ObservedObject private var store = PromotionStore.shared
    let source: PromotionCompetitorSource?

    @State private var name: String
    @State private var url: String
    @State private var note: String
    @State private var enabled: Bool
    @State private var error: String?

    init(source: PromotionCompetitorSource? = nil) {
        self.source = source
        _name = State(initialValue: source?.name ?? "")
        _url = State(initialValue: source?.url ?? "")
        _note = State(initialValue: source?.note ?? "")
        _enabled = State(initialValue: source?.isEnabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "binoculars")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(appAccent)
                Text(source == nil ? String(localized: "Add Market Source") : String(localized: "Edit Market Source"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            field(String(localized: "Name")) {
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            field(String(localized: "URL")) {
                TextField("https://…", text: $url)
                    .textFieldStyle(.roundedBorder)
            }
            field(String(localized: "Note")) {
                TextField("", text: $note)
                    .textFieldStyle(.roundedBorder)
            }
            if source != nil {
                Toggle(String(localized: "Enabled"), isOn: $enabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            Text(String(localized: "Checked in a background tab; only the page text / opsCompetitor view is compared. No login, no clicks, no bulk crawling."))
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
        .frame(width: 520, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            content()
                .font(.system(size: 11.5))
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { error = String(localized: "Name is required."); return }
        guard let parsed = URL(string: cleanURL),
              parsed.scheme == "http" || parsed.scheme == "https" else {
            error = String(localized: "URL must start with http(s)://")
            return
        }
        if let source {
            _ = store.updateCompetitorSource(source.id, name: cleanName, url: cleanURL,
                                             note: note, enabled: enabled)
        } else {
            _ = store.addCompetitorSource(name: cleanName, url: cleanURL, note: note)
        }
        dismiss()
    }
}
