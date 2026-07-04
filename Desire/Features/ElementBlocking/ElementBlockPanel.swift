import SwiftUI

struct ElementBlockPanel: View {
    @ObservedObject var store: ElementBlockStore
    var onStartPicker: () -> Void
    var onClose: () -> Void

    @State private var showAddSheet = false
    @State private var newPattern = ""
    @State private var newCss = ""
    @State private var newXpath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Element Blocker").font(.headline)
                Spacer()
                Button("Pick from Page") { onStartPicker(); onClose() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Button("Add Rule") { showAddSheet = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                Button("Close", action: onClose)
            }
            .padding()

            if store.rules.isEmpty {
                EmptyState(message: String(localized: "No Blocking Rules"))
            } else {
                List {
                    ForEach(store.rules) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(rule.urlPattern)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(rule.createdAt.formatted(date: .numeric, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(rule.cssSelector)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                            if let x = rule.xpath {
                                Text(x)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.remove(id: rule.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.remove(id: rule.id) }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 400)
        .sheet(isPresented: $showAddSheet) {
            VStack(spacing: 12) {
                Text("Add Blocking Rule").font(.headline)
                TextField("URL Pattern (e.g. example.com, * for all)", text: $newPattern)
                TextField("CSS Selector", text: $newCss)
                TextField("XPath (optional)", text: $newXpath)
                HStack {
                    Button("Cancel") { showAddSheet = false }
                    Button("Add") {
                        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
                        let css = newCss.trimmingCharacters(in: .whitespaces)
                        guard !pattern.isEmpty, !css.isEmpty else { return }
                        let xpath = newXpath.trimmingCharacters(in: .whitespaces)
                        store.add(cssSelector: css, xpath: xpath.isEmpty ? nil : xpath, urlPattern: pattern)
                        newPattern = ""; newCss = ""; newXpath = ""
                        showAddSheet = false
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty || newCss.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
            .frame(width: 380)
        }
    }
}

#Preview {
    ElementBlockPanel(store: ElementBlockStore(), onStartPicker: {}, onClose: {})
}
