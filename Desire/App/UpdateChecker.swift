import AppKit
import Combine
import CryptoKit
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

    // MARK: - 自更新（0.3.8）：下载 zip → SHA256 校验（SHASUMS256.txt
    // 资产）→ 替换 /Applications 里的 bundle → 重启。

    enum InstallState: Equatable {
        case idle
        case downloading
        case installing
        case failed(String)
        case readyToRelaunch
    }

    @Published private(set) var installState: InstallState = .idle

    /// 只有装在 /Applications 的正式包才可自更新（DerivedData 调试包
    /// 替换没有意义且会被 Xcode 覆盖）。
    var canSelfUpdate: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    func installNow() {
        guard installState == .idle || installState == .failed("") else { return }
        guard canSelfUpdate else {
            installState = .failed("Move Desire to /Applications to enable in-app updates")
            return
        }
        guard let tag = latestTag else {
            installState = .failed("No release info")
            return
        }
        installState = .downloading
        Task { await install(tag: tag) }
    }

    private func install(tag: String) async {
        do {
            // 1) 取 release 资产清单（重新拉，带 assets）。
            var req = URLRequest(url: Self.apiURL)
            req.timeoutInterval = 15
            req.setValue("Desire-update", forHTTPHeaderField: "User-Agent")
            let (metaData, _) = try await URLSession.shared.data(for: req)
            guard let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any],
                  let assets = meta["assets"] as? [[String: Any]] else {
                throw UpdateError.noAssets
            }
            let zipURL = assets.compactMap { a -> String? in
                guard let name = a["name"] as? String, name.hasSuffix(".zip"),
                      name.contains("macos-arm64"),
                      let url = a["browser_download_url"] as? String else { return nil }
                return url
            }.first
            let shasumURL = assets.compactMap { a -> String? in
                guard let name = a["name"] as? String, name == "SHASUMS256.txt",
                      let url = a["browser_download_url"] as? String else { return nil }
                return url
            }.first
            guard let zipURL, let shasumURL else { throw UpdateError.noAssets }

            // 2) 下载 SHASUMS256.txt 并取 zip 对应哈希。
            let (sumData, _) = try await URLSession.shared.data(for: URLRequest(url: URL(string: shasumURL)!))
            let sums = String(data: sumData, encoding: .utf8) ?? ""
            let zipName = (zipURL as NSString).lastPathComponent
            let expectedHash = sums.split(separator: "\n")
                .first(where: { $0.contains(zipName) })?
                .split(separator: " ").first.map(String.init)
            guard let expectedHash, expectedHash.count == 64 else { throw UpdateError.noChecksum }

            // 3) 下载 zip 并校验。
            let (zipData, _) = try await URLSession.shared.data(for: URLRequest(url: URL(string: zipURL)!))
            let digest = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
            guard digest == expectedHash.lowercased() else { throw UpdateError.checksumMismatch }

            // 4) 解包找 Desire.app。
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("desire-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let zipPath = tmp.appendingPathComponent("update.zip")
            try zipData.write(to: zipPath)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", zipPath.path, tmp.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { throw UpdateError.unpack }
            let newAppURL = tmp.appendingPathComponent("Desire.app")
            guard FileManager.default.fileExists(atPath: newAppURL.path) else { throw UpdateError.unpack }

            // 5) 替换 /Applications/Desire.app。
            installState = .installing
            let destination = Bundle.main.bundleURL
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: newAppURL)

            // 6) 重启。
            installState = .readyToRelaunch
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = [destination.path]
            try? relaunch.run()
            NSApp.terminate(nil)
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }

    enum UpdateError: LocalizedError {
        case noAssets, noChecksum, checksumMismatch, unpack

        var errorDescription: String? {
            switch self {
            case .noAssets: "Release has no macOS zip asset"
            case .noChecksum: "SHASUMS256.txt missing or unparsable"
            case .checksumMismatch: "SHA256 mismatch — download rejected"
            case .unpack: "Couldn't unpack the update"
            }
        }
    }

    enum CheckResult: Equatable {
        case upToDate
        case available(String)
        case failed(String)
    }

    private static let seenTagKey = "update.seenTag"
    /// 发布页（设置里的“查看发布页”按钮也要用，所以不是 private）。
    static let releasesURL = URL(string: "https://github.com/browser-rs/Desire/releases/latest")!
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
