import AppKit
import Combine
import Foundation
import os
@preconcurrency import UserNotifications

/// Lightweight update check against GitHub Releases (no Sparkle dependency):
/// on launch AND on demand (Settings ▸ manual button), fetch the latest
/// release tag; when it differs from the current one, publish an in-app
/// banner state AND post ONE system notification.
///
/// State is Combine-published so ContentView can render the banner and
/// Settings can report check results without polling.
///
/// version-agnostic by design: the app bundle's CFBundleShortVersionString
/// has never tracked release tags, so we compare TAGS, not versions.
///
/// Requires the repo to be PUBLIC (unauthenticated API). While the repo is
/// private, api.github.com 404s and this check is a silent no-op — it
/// starts working the moment the repo goes public, no code change needed.
@MainActor
final class UpdateChecker: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateChecker()

    @Published private(set) var latestTag: String?
    @Published private(set) var releasePageURL: URL?
    @Published private(set) var lastCheckResult: CheckResult?

    /// Controls the in-app banner: reset by "跳过此版本" or by visiting.
    @Published var bannerDismissed = false

    enum CheckResult: Equatable {
        case upToDate
        case available(String)
        case failed(String)
    }

    private static let seenTagKey = "update.seenTag"
    private static let releasesURL = URL(string: "https://github.com/browser-rs/Desire/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/browser-rs/Desire/releases/latest")!

    private static let log = Log.app
    private var checkTask: Task<Void, Never>?
    private var lastCheckAt: Date?

    func checkIfNeeded() {
        // The notification delegate must be installed before any notification
        // fires for its tap handling to work.
        UNUserNotificationCenter.current().delegate = self
        startCheck()
    }

    func startCheck() {
        guard checkTask == nil else { return }
        lastCheckAt = Date()
        checkTask = Task { [weak self] in
            await self?.check()
            await MainActor.run { [weak self] in
                self?.checkTask = nil
            }
        }
    }

    var isChecking: Bool { checkTask != nil }

    private func check() async {
        var request = URLRequest(url: Self.apiURL)
        request.timeoutInterval = 10
        request.setValue("Desire-update-check", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = payload["tag_name"] as? String, !tag.isEmpty,
                  let htmlURL = payload["html_url"] as? String else {
                Self.log.info("update check: no release info")
                lastCheckResult = .failed("no release info")
                return
            }
            latestTag = tag
            releasePageURL = URL(string: htmlURL)

            let seen = UserDefaults.standard.string(forKey: Self.seenTagKey)
            guard tag != seen else {
                Self.log.info("update check: \(tag, privacy: .public) already seen")
                lastCheckResult = .upToDate
                return
            }
            UserDefaults.standard.set(tag, forKey: Self.seenTagKey)
            // First-run installs seed seenTag silently — a user who just
            // installed does not need a "new version" notification.
            if seen != nil {
                notify(tag: tag, url: htmlURL)
            }
            lastCheckResult = .available(tag)
        } catch {
            Self.log.info("update check failed: \(error.localizedDescription, privacy: .public)")
            lastCheckResult = .failed(error.localizedDescription)
        }
    }

    private func notify(tag: String, url: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "New version available")
            content.body = String(localized: "\(tag) is out — click to view the release notes.")
            content.userInfo = ["url": url]
            center.add(UNNotificationRequest(
                identifier: "desire.update.\(tag)", content: content, trigger: nil))
        }
    }

    /// Notification tap → open the release page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let url = response.notification.request.content.userInfo["url"] as? String,
           response.notification.request.identifier.hasPrefix("desire.update.") {
            Task { @MainActor in
                NSWorkspace.shared.open(URL(string: url) ?? Self.releasesURL)
            }
        }
        completionHandler()
    }

    /// Show notifications as banners even while the app is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
