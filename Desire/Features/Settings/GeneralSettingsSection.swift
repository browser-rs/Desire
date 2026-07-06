import SwiftUI

struct GeneralSettingsSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var downloadStore: DownloadStore

    var body: some View {
        Form {
            Picker("Default Search Engine", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases, id: \.self) { engine in
                    Text(engine.rawValue).tag(engine)
                }
            }

            CustomEngineSection(settings: settings)

            TextField("Homepage URL", text: $settings.homePage)

            Divider()

            LabeledContent("Download Location") {
                HStack(spacing: 8) {
                    Text(downloadStore.downloadFolder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Button("Change…") {
                        downloadStore.chooseDownloadFolder()
                    }
                }
            }

            Divider()

            LabeledContent("Screenshot Save Location") {
                HStack(spacing: 8) {
                    Text(settings.screenshotFolder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Button("Change…") {
                        settings.chooseScreenshotFolder()
                    }
                    Button("Reset") {
                        settings.resetScreenshotFolder()
                    }
                }
            }
        }
        .padding()
    }
}

private struct CustomEngineSection: View {
    @ObservedObject var settings: Settings
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newSuggestionURL = ""

    var body: some View {
        Section("Custom Search Engines") {
            if settings.customEngines.isEmpty {
                Text("No custom search engines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.customEngines) { engine in
                    HStack {
                        Text(engine.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Button("Delete") { settings.removeCustomEngine(engine.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            Button("Add") { showAdd = true }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .sheet(isPresented: $showAdd) {
            VStack(spacing: 16) {
                Text("Add Search Engine").font(.headline)
                TextField("Name (e.g. Wikipedia)", text: $newName)
                TextField("Search URL (e.g. https://en.wikipedia.org/wiki/Special:Search?search=)", text: $newURL)
                TextField("Suggestion URL (optional)", text: $newSuggestionURL)
                HStack {
                    Button("Cancel") { showAdd = false }
                    Button("Add") {
                        settings.addCustomEngine(name: newName, searchURL: newURL, suggestionURL: newSuggestionURL)
                        newName = ""; newURL = ""; newSuggestionURL = ""
                        showAdd = false
                    }
                    .disabled(newName.isEmpty || newURL.isEmpty)
                }
            }
            .padding()
            .frame(width: 420)
        }
    }
}
