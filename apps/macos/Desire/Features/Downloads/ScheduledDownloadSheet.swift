import SwiftUI

/// 定时下载（v0.8.0）：URL + 开始时间，交给 `DownloadScheduler`。
struct ScheduledDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var filename = ""
    @State private var startAt = Date().addingTimeInterval(30 * 60)
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule Download")
                .font(.system(size: 16, weight: .semibold))
            TextField("https://example.com/file.zip", text: $urlText)
                .textFieldStyle(.roundedBorder)
            TextField("Filename (optional)", text: $filename)
                .textFieldStyle(.roundedBorder)
            DatePicker("Start at", selection: $startAt,
                       in: Date()..., displayedComponents: [.date, .hourAndMinute])
            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Schedule") { schedule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func schedule() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorText = String(localized: "Enter a valid http(s) URL.")
            return
        }
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DownloadScheduler.shared.schedule(
            url: url,
            filename: name.isEmpty ? nil : name,
            startAt: startAt) != nil else {
            errorText = String(localized: "Could not schedule this download.")
            return
        }
        dismiss()
    }
}
