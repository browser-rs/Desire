import SwiftUI

/// 技能 Gallery sheet（v0.8.19 旗舰）：拉取站上索引 → 列表 → 一键安装
/// （SkillStore.installFromURL，.md/.zip 通吃）；已安装的技能标"已安装"。
struct SkillGallerySheet: View {
    @Environment(\.appAccent) private var appAccent: Color
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SkillStore.shared

    @State private var loadPhase: Phase = .loading
    @State private var entries: [SkillGallery.SkillEntry] = []
    @State private var installing: Set<String> = []
    @State private var failures: [String: String] = [:]
    @State private var installedNote: String?

    enum Phase: Equatable {
        case loading, loaded, failed(String)
    }

    private var installedNames: Set<String> {
        Set(store.skills.map(\.name))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundStyle(appAccent)
                Text("Skill Gallery")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Refresh")) { load() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch loadPhase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "Couldn't load the gallery: \(message)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 480, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { load() }
    }

    private func row(_ entry: SkillGallery.SkillEntry) -> some View {
        let isInstalled = installedNames.contains(entry.name)
        let isInstalling = installing.contains(entry.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12.5, weight: .semibold))
                    if isInstalled {
                        Text(String(localized: "Installed"))
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(appAccent.opacity(0.14)))
                            .foregroundStyle(appAccent)
                    }
                }
                Text(entry.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let failure = failures[entry.id] {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(isInstalling ? String(localized: "Installing…") : String(localized: "Install")) {
                install(entry)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isInstalled || isInstalling)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }

    private func load() {
        loadPhase = .loading
        Task {
            do {
                let indexURL = URL(string: "index.json", relativeTo: URL(string: SkillGallery.defaultBaseURL))!.absoluteURL
                let (data, response) = try await URLSession.shared.data(from: indexURL)
                guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                      let index = SkillGallery.parseIndex(data) else {
                    throw URLError(.badServerResponse)
                }
                entries = index.skills
                loadPhase = .loaded
            } catch {
                loadPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func install(_ entry: SkillGallery.SkillEntry) {
        guard let fileURL = SkillGallery.resolveFileURL(entry.file, base: SkillGallery.defaultBaseURL) else {
            failures[entry.id] = String(localized: "Unsafe file path in index")
            return
        }
        installing.insert(entry.id)
        failures[entry.id] = nil
        Task {
            do {
                let installed = try await store.installFromURL(fileURL)
                installedNote = installed.name
            } catch {
                failures[entry.id] = error.localizedDescription
            }
            installing.remove(entry.id)
        }
    }
}
