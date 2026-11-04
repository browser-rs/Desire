import SwiftUI

/// EXIF 面板（v0.8.42）：查看/编辑核心字段 + GPS 清除 + 全清除。
struct ImageEXIFPanel: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color

    @State private var summary: ImageEXIF.Summary?
    @State private var titleText = ""
    @State private var artistText = ""
    @State private var copyrightText = ""
    @State private var descriptionText = ""
    @State private var keywordsText = ""
    @State private var message: String?
    @State private var confirmClearGPS = false
    @State private var confirmClearAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "EXIF Metadata"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.borderless)
            }
            if let summary {
                // 只读摘要
                VStack(alignment: .leading, spacing: 2) {
                    exifRow("Camera", [summary.cameraMake, summary.cameraModel]
                        .compactMap(\.self).joined(separator: " "))
                    exifRow("Lens", summary.lensModel ?? "—")
                    exifRow("Settings", [summary.exposureTime, summary.fNumber,
                                         summary.iso, summary.focalLength]
                        .compactMap(\.self).joined(separator: " · "))
                    exifRow("Date", summary.dateTimeOriginal ?? "—")
                    exifRow("Size", "\(summary.pixelWidth ?? 0) × \(summary.pixelHeight ?? 0) px")
                    if let lat = summary.gpsLatitude, let lon = summary.gpsLongitude {
                        exifRow("GPS", String(format: "%.4f, %.4f", lat, lon))
                    } else {
                        exifRow("GPS", String(localized: "No GPS data"))
                    }
                    exifRow("Format", summary.formatName ?? "—")
                    exifRow("File size",
                            summary.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                }
                Divider()
                // 编辑字段
                Text(String(localized: "Editable fields"))
                    .font(.system(size: 11, weight: .semibold))
                field(String(localized: "Title"), $titleText)
                field(String(localized: "Artist"), $artistText)
                field(String(localized: "Copyright"), $copyrightText)
                field(String(localized: "Description"), $descriptionText)
                field(String(localized: "Keywords (comma separated)"), $keywordsText)
                Button(String(localized: "Save Fields")) { saveFields() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                Divider()
                // GPS 清除 / 全清除
                HStack(spacing: 8) {
                    Button(String(localized: "Clear GPS"), role: .destructive) {
                        confirmClearGPS = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(summary.gpsLatitude == nil && summary.gpsLongitude == nil)
                    Button(String(localized: "Clear All Metadata"), role: .destructive) {
                        confirmClearAll = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                if let message {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 440, height: 560)
        .onAppear(perform: load)
        .confirmationDialog(String(localized: "Clear GPS data? This is irreversible."),
                            isPresented: $confirmClearGPS, titleVisibility: .visible) {
            Button(String(localized: "Clear GPS"), role: .destructive) { clearGPS() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(String(localized: "Clear ALL metadata? This is irreversible."),
                            isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button(String(localized: "Clear All"), role: .destructive) { clearAll() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    private func exifRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 10.5))
                .lineLimit(1)
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }

    private func load() {
        summary = ImageEXIF.read(from: fileURL)
        titleText = summary?.cameraModel ?? ""
        artistText = summary?.artist ?? ""
        copyrightText = summary?.copyright ?? ""
        descriptionText = summary?.description ?? ""
        keywordsText = summary?.keywords.joined(separator: ", ") ?? ""
    }

    private func saveFields() {
        let keywords = keywordsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let ok = ImageEXIF.write(
            to: fileURL,
            title: titleText.isEmpty ? nil : titleText,
            artist: artistText.isEmpty ? nil : artistText,
            copyright: copyrightText.isEmpty ? nil : copyrightText,
            description: descriptionText.isEmpty ? nil : descriptionText,
            keywords: keywords,
            clearGPS: false, clearAll: false)
        message = ok ? String(localized: "Saved.") : String(localized: "Write failed")
        load()
    }

    private func clearGPS() {
        let ok = ImageEXIF.write(to: fileURL, title: nil, artist: nil,
                                 copyright: nil, description: nil,
                                 keywords: [], clearGPS: true, clearAll: false)
        message = ok ? String(localized: "GPS cleared.") : String(localized: "Write failed")
        load()
    }

    private func clearAll() {
        let ok = ImageEXIF.write(to: fileURL, title: nil, artist: nil,
                                 copyright: nil, description: nil,
                                 keywords: [], clearGPS: false, clearAll: true)
        message = ok ? String(localized: "All metadata cleared.")
                     : String(localized: "Write failed")
        load()
    }
}
