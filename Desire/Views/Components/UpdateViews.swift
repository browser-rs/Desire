import SwiftUI

/// In-app update banner (toolbar area): shows when a newer release exists
/// and the user hasn't dismissed it for this tag.
struct UpdateBannerView: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let tag = checker.latestTag, !checker.bannerDismissed {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "\(tag) is available"))
                        .font(.system(size: 12, weight: .medium))
                    Text(String(localized: "Click to view release notes"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    checker.bannerDismissed = true
                    if let url = checker.releasePageURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("View Release")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                Button {
                    checker.bannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Dismiss"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.06))
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Settings ▸ System ▸ "Check for Updates" row: manual trigger with
/// inline result feedback.
struct CheckUpdatesRow: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Check for Updates")
                    .font(.system(size: 13, weight: .medium))
                switch checker.lastCheckResult {
                case .available(let tag):
                    Text(String(localized: "\(tag) is available"))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                case .upToDate:
                    Text(String(localized: "You're up to date."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .failed(let error):
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case nil:
                    Text(String(localized: "Check GitHub Releases for the latest build."))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                checker.startCheck()
            } label: {
                if checker.isChecking {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 60, height: 18)
                } else {
                    Text("Check Now")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(checker.isChecking)
        }
    }
}
