import AppKit
import Foundation
import os
@preconcurrency import UserNotifications

/// Lightweight update check against GitHub Releases (0.2.4 pre-work, no
/// Sparkle dependency): on launch, fetch the latest release tag; when it
/// differs from the last one the user was told about, post ONE system
/// notification — clicking it opens the release page.
///
/// version-agnostic by design: the app bundle's CFBundleShortVersionString
/// has never tracked release tags, so we compare TAGS, not versions.
///
/// Requires the repo to be PUBLIC (unauthenticated API). While the repo is
/// private, api.github.com 404s and this check is a silent no-op — it
/// starts working the moment the repo goes public, no code change needed.
@MainActor
final class UpdateChecker: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateChecker()

    private static let seenTagKey = "update.seenTag"
    private static let releasesURL = URL(string: "https://github.com/browser-rs/Desire/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/browser-rs/Desire/releases/latest")!

    private static let log = Log.app

    func checkIfNeeded() {
        // The notification delegate must be installed before any notification
        // fires for its tap handling to work.
        UNUserNotificationCenter.current().delegate = self
        Task { await check() }
    }

    private func check() async {
        var request = URLRequest(url: Self.apiURL)
        request.timeoutInterval = 10
        // GitHub API requires a UA; default URLSession UA is fine but be explicit.
        request.setValue("Desire-update-check", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = payload["tag_name"] as? String, !tag.isEmpty,
                  let htmlURL = payload["html_url"] as? String else {
                Self.log.info("update check: no release info")
                return
            }
            let seen = UserDefaults.standard.string(forKey: Self.seenTagKey)
            guard tag != seen else {
                Self.log.info("update check: \(tag, privacy: .public) already seen")
                return
            }
            UserDefaults.standard.set(tag, forKey: Self.seenTagKey)
            // First-run installs seed seenTag silently — a user who just
            // installed does not need a "new version" notification.
            if seen != nil {
                notify(tag: tag, url: htmlURL)
            }
        } catch {
            Self.log.info("update check failed: \(error.localizedDescription, privacy: .public)")
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
