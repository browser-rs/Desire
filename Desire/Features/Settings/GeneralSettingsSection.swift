import AppKit
import SwiftUI

struct GeneralSettingsSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var downloadStore: DownloadStore

    var body: some View {
        Form {
            AppearanceSection(settings: settings)
            StartupSection(settings: settings)
            TabBehaviorSection(settings: settings)
            ContainerSection()
            MediaSection(settings: settings)
            SearchSection(settings: settings)
            DownloadsSection(settings: settings, downloadStore: downloadStore)
            SystemSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Appearance

private struct AppearanceSection: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.appearanceTheme) {
                Text("System").tag(AppearanceTheme.system)
                Text("Light").tag(AppearanceTheme.light)
                Text("Dark").tag(AppearanceTheme.dark)
            }

            Picker("Accent Color", selection: $settings.accentColor) {
                ForEach(AccentColor.allCases, id: \.self) { color in
                    Label {
                        Text(color.rawValue.capitalized)
                    } icon: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 12, height: 12)
                    }
                    .tag(color)
                }
            }
        }
    }
}

// MARK: - Startup

private struct StartupSection: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Section("Startup") {
            Picker("On Launch", selection: $settings.startupBehavior) {
                Text("Restore previous session").tag(StartupBehavior.restoreSession)
                Text("Open new tab page").tag(StartupBehavior.newTabPage)
            }
            TextField("Homepage URL", text: $settings.homePage)
        }
    }
}

// MARK: - Tab Behavior

private struct TabBehaviorSection: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Section("Tabs") {
            Picker("New tabs open", selection: $settings.newTabPosition) {
                Text("At the end").tag(NewTabPosition.end)
                Text("After current tab").tag(NewTabPosition.afterCurrent)
            }
            Toggle("Confirm before closing multiple tabs", isOn: $settings.confirmCloseMultipleTabs)
            Picker("Suspend background tabs after", selection: $settings.suspendAfterMinutes) {
                Text("5 Minutes").tag(5.0)
                Text("10 Minutes").tag(10.0)
                Text("30 Minutes").tag(30.0)
                Text("1 Hour").tag(60.0)
                Text("2 Hours").tag(120.0)
                Text("Never").tag(-1.0)
            }
        }
    }
}

// MARK: - Tab Containers

/// Manages tab containers (Firefox multi-account-container style). Each
/// container gets a persistent, isolated website data store; new tabs open
/// into it via the "+" button's right-click menu in the tab bar.
private struct ContainerSection: View {
    @ObservedObject var store = ContainerStore.shared
    @State private var newName = ""

    var body: some View {
        Section("Tab Containers") {
            Text("Each container isolates cookies and sessions — use separate containers for different accounts on the same site. New container tabs open from the \"+\" button's right-click menu.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.containers.isEmpty {
                Text("No containers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.containers) { container in
                HStack {
                    Circle()
                        .fill(container.color)
                        .frame(width: 9, height: 9)
                    Text(container.name)
                    Spacer()
                    Button("Delete") { store.removeContainer(container.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            HStack {
                TextField("New container name", text: $newName)
                    .onSubmit {
                        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        store.addContainer(name: newName)
                        newName = ""
                    }
                Button("Add") {
                    store.addContainer(name: newName)
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Media

private struct MediaSection: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Section("Media") {
            Picker("Auto-play", selection: $settings.autoPlayPolicy) {
                Text("Allow All").tag(AutoPlayPolicy.allowAll)
                Text("Require User Action").tag(AutoPlayPolicy.requireUserAction)
                Text("Never Auto-play").tag(AutoPlayPolicy.never)
            }
        }
    }
}

// MARK: - Search

private struct SearchSection: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Section("Search") {
            Picker("Default Search Engine", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases, id: \.self) { engine in
                    Text(engine.rawValue).tag(engine)
                }
            }

            CustomEngineSection(settings: settings)
        }
    }
}

// MARK: - Downloads

private struct DownloadsSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var downloadStore: DownloadStore

    var body: some View {
        Section("Downloads") {
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
    }
}

// MARK: - System

private struct SystemSection: View {
    @State private var isDefault = false

    var body: some View {
        Section("System") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default Browser")
                    Text(isDefault ? "Desire is your default browser" : "Set Desire as your default browser")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isDefault {
                    Button("Set as Default…") {
                        setAsDefaultBrowser()
                    }
                }
            }
        }
        .onAppear {
            checkDefaultBrowser()
        }
    }

    private func checkDefaultBrowser() {
        let scheme = URL(string: "https://")!
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: scheme) {
            isDefault = appURL == Bundle.main.bundleURL
        }
    }

    private func setAsDefaultBrowser() {
        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { error in
            if error == nil {
                NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { _ in
                    isDefault = true
                }
            }
        }
    }
}

// MARK: - Custom Engine

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


// MARK: - AccentColor → SwiftUI Color bridge

/// View-layer mapping so the pure Model enum stays free of `import SwiftUI`.
extension AccentColor {
    var color: Color {
        switch self {
        case .blue:   .blue
        case .purple: .purple
        case .pink:   .pink
        case .red:    .red
        case .orange: .orange
        case .yellow: .yellow
        case .green:  .green
        case .teal:   .teal
        }
    }
}
