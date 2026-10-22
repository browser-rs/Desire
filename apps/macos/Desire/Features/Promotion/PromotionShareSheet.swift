import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// “分享 Desire”面板（v0.8.2）：渠道化文案 + 带 UTM 链接 + 二维码。
/// 内容可编辑，复制走剪贴板；不发任何网络请求、不自动打开社交平台。
struct PromotionShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent: Color
    @ObservedObject private var share = PromotionShareCenter.shared

    @State private var channelSlug = PromotionShare.defaultChannel.slug
    @State private var caption = ""
    @State private var qrImage: NSImage?
    @State private var copied = false

    private var version: String { WhatsNewStore.shared.versionName }

    private var channel: PromotionChannel {
        PromotionChannel.preset(slug: channelSlug) ?? PromotionShare.defaultChannel
    }

    private var shareURL: String {
        PromotionShare.trackedURL(version: version, channel: channel.slug)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(appAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Desire")
                        .font(.system(size: 16, weight: .semibold))
                    Text("A ready-to-post caption and a tracked link. Nothing is posted automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Close")) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(String(localized: "Channel"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Picker("", selection: $channelSlug) {
                    ForEach(PromotionChannel.presets) { channel in
                        Text(channel.platform).tag(channel.slug)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Text("v\(PromotionShare.normalizedVersion(version))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $caption)
                .font(.system(size: 12))
                .frame(minHeight: 180)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(nsColor: .separatorColor)))

            HStack(alignment: .top, spacing: 14) {
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 128, height: 128)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(shareURL)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(String(localized: "UTM source = \(channel.slug), medium = social. The link opens the product page."))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            HStack {
                Button(String(localized: "Copy Caption")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(caption, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .buttonStyle(.borderedProminent)
                Button(String(localized: "Copy Link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shareURL, forType: .string)
                    copied = true
                }
                .buttonStyle(.bordered)
                Button(String(localized: "Open Product Page")) {
                    if let url = URL(string: PromotionShare.defaultProductURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                if copied {
                    Label(String(localized: "Copied"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .onAppear { refresh() }
        .onChange(of: channelSlug) { _, _ in refresh() }
        .onChange(of: share.isPresented) { _, presented in
            if presented { refresh() }
        }
    }

    private func refresh() {
        caption = PromotionShare.caption(platform: channel.platform, version: version)
        qrImage = makeQR(shareURL)
    }

    private func makeQR(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
