import AppKit
import SwiftUI

struct GeneralSettingsSection: View {
    @ObservedObject var settings: Settings
    @ObservedObject var downloadStore: DownloadStore

    var body: some View {
        SettingsContainer {
            // MARK: - Appearance

            SettingsSection(
                title: "Appearance",
                subtitle: "Theme and accent color used across the entire app.",
                icon: "paintpalette"
            ) {
                VStack(spacing: 0) {
                    SettingsPickerRow(
                        "Theme",
                        subtitle: "Match the system, or pin to light or dark.",
                        systemImage: "circle.lefthalf.filled",
                        selection: $settings.appearanceTheme,
                        options: AppearanceTheme.allCases,
                        label: appearanceLabel
                    )
                    SettingsRowDivider()
                    AccentColorRow(settings: settings)
                }
            }

            // MARK: - Startup

            SettingsSection(
                title: "Startup",
                subtitle: "What Desire does when you launch it.",
                icon: "power"
            ) {
                VStack(spacing: 0) {
                    SettingsPickerRow(
                        "On Launch",
                        subtitle: "Restore the last session or start fresh on the new tab page.",
                        systemImage: "arrow.up.forward.app",
                        selection: $settings.startupBehavior,
                        options: StartupBehavior.allCases,
                        label: startupLabel
                    )
                    SettingsRowDivider()
                    SettingsRow(
                        "Homepage",
                        subtitle: "Used by the Home button and the New Tab page header.",
                        systemImage: "house"
                    ) {
                        SettingsTextField(
                            placeholder: "https://example.com",
                            text: $settings.homePage,
                            width: 280
                        )
                    }
                }
            }

            // MARK: - Tabs

            SettingsSection(
                title: "Tabs",
                subtitle: "How new tabs open and how background tabs are handled.",
                icon: "rectangle.stack"
            ) {
                VStack(spacing: 0) {
                    SettingsPickerRow(
                        "New Tabs Open",
                        subtitle: "Position relative to the current tab.",
                        systemImage: "rectangle.stack.badge.plus",
                        selection: $settings.newTabPosition,
                        options: NewTabPosition.allCases,
                        label: newTabPositionLabel
                    )
                    SettingsRowDivider()
                    SettingsPickerRow(
                        "Suspend Background Tabs After",
                        subtitle: "Free memory by suspending tabs you've switched away from.",
                        systemImage: "moon.zzz",
                        selection: $settings.suspendAfterMinutes,
                        options: [-1.0, 5.0, 10.0, 30.0, 60.0, 120.0],
                        label: suspendLabel
                    )
                    SettingsRowDivider()
                    SettingsToggleRow(
                        "Confirm Before Closing Multiple Tabs",
                        subtitle: "Show a prompt when ⌘W would close more than one tab.",
                        systemImage: "exclamationmark.bubble",
                        isOn: $settings.confirmCloseMultipleTabs
                    )
                }
            }

            // MARK: - Tab Containers

            ContainerSection()

            // MARK: - Media

            SettingsSection(
                title: "Media",
                subtitle: "Auto-play policy for video and audio on web pages.",
                icon: "play.rectangle"
            ) {
                SettingsPickerRow(
                    "Auto-play",
                    subtitle: "Whether media starts playing automatically without your input.",
                    systemImage: "speaker.wave.2",
                    selection: $settings.autoPlayPolicy,
                    options: AutoPlayPolicy.allCases,
                    label: autoPlayLabel
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Skip YouTube Sponsor Segments",
                    subtitle: "Auto-skip in-video sponsor/promo segments on YouTube (SponsorBlock community data). Applies to the next page load.",
                    systemImage: "forward.endpoints",
                    isOn: $settings.sponsorBlockSkip
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Sponsors & Self-promos",
                    subtitle: "Paid promotions and creator self-promotion readouts.",
                    systemImage: "dollarsign.circle",
                    isOn: $settings.sponsorSkipMain
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Intros, Outros & Previews",
                    subtitle: "Skippable opening/ending cards and recap previews.",
                    systemImage: "forward.frame",
                    isOn: $settings.sponsorSkipChapters
                )
                SettingsRowDivider()
                SettingsToggleRow(
                    "Filler Tangents",
                    subtitle: "Off-topic filler content that adds nothing.",
                    systemImage: "water.waves",
                    isOn: $settings.sponsorSkipFiller
                )
            }

            // MARK: - Search

            SettingsSection(
                title: "Search",
                subtitle: "Default search engine for the address bar.",
                icon: "magnifyingglass"
            ) {
                VStack(spacing: 0) {
                    SettingsPickerRow(
                        "Default Search Engine",
                        subtitle: "Used when you type a query in the address bar.",
                        systemImage: "globe",
                        selection: $settings.searchEngine,
                        options: SearchEngine.allCases,
                        label: { $0.rawValue }
                    )
                    CustomEngineSection(settings: settings)
                }
            }

            // MARK: - Downloads

            SettingsSection(
                title: "Downloads",
                subtitle: "Where files and screenshots are saved by default.",
                icon: "arrow.down.circle"
            ) {
                VStack(spacing: 0) {
                    FolderPathRow(
                        title: "Download Location",
                        subtitle: "Where downloaded files end up.",
                        systemImage: "tray.and.arrow.down",
                        path: downloadStore.downloadFolder.path,
                        buttonTitle: "Change…",
                        action: { downloadStore.chooseDownloadFolder() }
                    )
                    SettingsRowDivider()
                    FolderPathRow(
                        title: "Screenshot Save Location",
                        subtitle: "Where captured screenshots are written.",
                        systemImage: "camera.viewfinder",
                        path: settings.screenshotFolder.path,
                        buttonTitle: "Change…",
                        action: { settings.chooseScreenshotFolder() },
                        secondaryButtonTitle: "Reset",
                        secondaryAction: { settings.resetScreenshotFolder() }
                    )
                }
            }

            // MARK: - System

            SystemSection()
        }
    }

    // MARK: - Labels

    private func appearanceLabel(_ theme: AppearanceTheme) -> String {
        switch theme {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private func startupLabel(_ behavior: StartupBehavior) -> String {
        switch behavior {
        case .restoreSession: "Restore previous session"
        case .newTabPage: "Open new tab page"
        }
    }

    private func newTabPositionLabel(_ position: NewTabPosition) -> String {
        switch position {
        case .end: "At the end"
        case .afterCurrent: "After current tab"
        }
    }

    private func suspendLabel(_ minutes: Double) -> String {
        switch minutes {
        case 5: "5 minutes"
        case 10: "10 minutes"
        case 30: "30 minutes"
        case 60: "1 hour"
        case 120: "2 hours"
        case -1: "Never"
        default: "\(Int(minutes)) min"
        }
    }

    private func autoPlayLabel(_ policy: AutoPlayPolicy) -> String {
        switch policy {
        case .allowAll: "Allow all"
        case .requireUserAction: "Require user action"
        case .never: "Never auto-play"
        }
    }
}

// MARK: - Accent Color Row

private struct AccentColorRow: View {
    @ObservedObject var settings: Settings

    var body: some View {
        SettingsRow(
            "Accent Color",
            subtitle: "Used for highlights, focus rings, and primary buttons.",
            systemImage: "paintbrush"
        ) {
            HStack(spacing: 6) {
                ForEach(AccentColor.allCases, id: \.self) { color in
                    AccentSwatch(
                        color: color,
                        isSelected: settings.accentColor == color
                    ) {
                        settings.accentColor = color
                    }
                }
            }
        }
    }
}

private struct AccentSwatch: View {
    let color: AccentColor
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.color)
                    .frame(width: 18, height: 18)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 26, height: 26)
            .background(
                Circle()
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.18)
                          : Color.secondary.opacity(isHovering ? 0.12 : 0.06))
            )
            .overlay(
                Circle()
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(0.6)
                            : Color.secondary.opacity(0.0),
                        lineWidth: 1.0
                    )
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.rawValue.capitalized)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }
}

// MARK: - Tab Containers

private struct ContainerSection: View {
    @ObservedObject var store = ContainerStore.shared
    @State private var newName = ""
    @State private var wipingContainer: TabContainer?

    var body: some View {
        SettingsSection(
            title: "Tab Containers",
            subtitle: "Each container isolates cookies and sessions — useful for separate accounts on the same site. Open new container tabs from the + button's right-click menu.",
            icon: "square.stack.3d.up"
        ) {
            VStack(spacing: 0) {
                if store.containers.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("No containers yet. Add one below to start isolating sessions.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else {
                    ForEach(Array(store.containers.enumerated()), id: \.element.id) { index, container in
                        containerRow(container)
                        if index < store.containers.count - 1 {
                            SettingsRowDivider()
                        }
                    }
                }
                SettingsRowDivider()
                HStack(spacing: 8) {
                    SettingsTextField(
                        placeholder: "New container name",
                        text: $newName
                    )
                    .frame(maxWidth: .infinity)
                    Button {
                        addContainer()
                    } label: {
                        Text("Add")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.18))
                            )
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .alert(
            "Wipe container data?",
            isPresented: Binding(
                get: { wipingContainer != nil },
                set: { if !$0 { wipingContainer = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Wipe Data", role: .destructive) {
                if let container = wipingContainer {
                    Task { await store.purgeData(for: container.id) }
                }
            }
        } message: {
            Text("This removes all cookies and site data of the container. Websites will log you out.")
        }
    }

    private func containerRow(_ container: TabContainer) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(swiftUIColor(for: container.colorName))
                .frame(width: 12, height: 12)
            Text(container.name)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button {
                wipingContainer = container
            } label: {
                Image(systemName: "eraser")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Wipe data")
            Button {
                store.removeContainer(container.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete container")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    private func addContainer() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addContainer(name: trimmed)
        newName = ""
    }
}

// MARK: - Folder Path Row

private struct FolderPathRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let path: String
    let buttonTitle: String
    let action: () -> Void
    var secondaryButtonTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.secondary.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)

            HStack(spacing: 6) {
                if let secondaryButtonTitle, let secondaryAction {
                    Button(secondaryButtonTitle, action: secondaryAction)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.10)))
                        .foregroundStyle(.primary)
                }
                Button(buttonTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

// MARK: - System (default browser)

private struct SystemSection: View {
    @State private var isDefault = false

    var body: some View {
        SettingsSection(
            title: "System",
            subtitle: "Whether Desire is the default handler for http(s) links.",
            icon: "gear.badge"
        ) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isDefault ? "checkmark.seal.fill" : "globe.badge.chevron.backward")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isDefault ? .green : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill((isDefault ? Color.green : .secondary).opacity(0.10))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Default Browser")
                        .font(.system(size: 13, weight: .medium))
                    Text(isDefault
                         ? "Desire is your default browser."
                         : "Set Desire as your default browser to open http and https links.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isDefault {
                    StatusPill(text: "Default", kind: .success)
                } else {
                    Button {
                        setAsDefaultBrowser()
                    } label: {
                        Text("Set as Default…")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            CheckUpdatesRow(checker: UpdateChecker.shared)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics")
                        .font(.system(size: 13, weight: .medium))
                    Text("Crash and performance reports collected via MetricKit.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let archive = MetricsManager.shared.exportDiagnosticsArchive() {
                        NSWorkspace.shared.activateFileViewerSelecting([archive])
                    } else {
                        MetricsManager.shared.revealDiagnosticsFolder()
                    }
                } label: {
                    Text("Export…")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                Button {
                    MetricsManager.shared.revealDiagnosticsFolder()
                } label: {
                    Text("Show in Finder")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear(perform: checkDefaultBrowser)
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

// MARK: - Custom Search Engines

private struct CustomEngineSection: View {
    @ObservedObject var settings: Settings
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newSuggestionURL = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsRowDivider()
            if settings.customEngines.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("No custom search engines. Add one to use a private engine.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                ForEach(Array(settings.customEngines.enumerated()), id: \.element.id) { index, engine in
                    engineRow(engine)
                    if index < settings.customEngines.count - 1 {
                        SettingsRowDivider()
                    }
                }
                SettingsRowDivider()
            }
            HStack {
                Spacer()
                Button {
                    showAdd = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add Search Engine")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showAdd) {
            AddCustomEngineSheet(
                name: $newName,
                searchURL: $newURL,
                suggestionURL: $newSuggestionURL,
                onCancel: { showAdd = false },
                onAdd: {
                    settings.addCustomEngine(
                        name: newName,
                        searchURL: newURL,
                        suggestionURL: newSuggestionURL
                    )
                    newName = ""; newURL = ""; newSuggestionURL = ""
                    showAdd = false
                }
            )
        }
    }

    private func engineRow(_ engine: CustomSearchEngine) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(engine.name)
                    .font(.system(size: 12, weight: .medium))
                if let host = URL(string: engine.searchURL)?.host {
                    Text(host)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                settings.removeCustomEngine(engine.id)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

// MARK: - Add Custom Engine Sheet

private struct AddCustomEngineSheet: View {
    @Binding var name: String
    @Binding var searchURL: String
    @Binding var suggestionURL: String
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Add Search Engine")
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                SettingsTextField(placeholder: "Wikipedia", text: $name)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Search URL")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                SettingsTextField(
                    placeholder: "https://en.wikipedia.org/wiki/Special:Search?search=",
                    text: $searchURL
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Suggestion URL (optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                SettingsTextField(placeholder: "https://…/suggest?q=", text: $suggestionURL)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.secondary.opacity(0.10)))
                    .foregroundStyle(.primary)

                Spacer()

                Button("Add", action: onAdd)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(
                            Color.accentColor.opacity(canAdd ? 0.22 : 0.08)
                        )
                    )
                    .foregroundStyle(canAdd ? Color.accentColor : .secondary)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !searchURL.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - AccentColor → SwiftUI Color bridge

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

// MARK: - TabContainer color name → SwiftUI Color

private func swiftUIColor(for name: String) -> Color {
    switch name {
    case "orange": .orange
    case "blue":   .blue
    case "green":  .green
    case "purple": .purple
    case "pink":   .pink
    case "red":    .red
    case "teal":   .teal
    case "indigo": .indigo
    default:       .gray
    }
}
