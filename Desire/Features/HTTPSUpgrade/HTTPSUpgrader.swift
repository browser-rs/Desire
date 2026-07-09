import Foundation

/// HTTPS auto-upgrade utility that manages HTTP-to-HTTPS conversion logic.
/// Tracks failed upgrades to avoid repeated attempts and handles fallback
/// scenarios when HTTPS is not available.
@MainActor
class HTTPSUpgrader {
    /// URLs that have failed HTTPS upgrade and should not be retried.
    private var failedUpgrades: Set<String> = []

    /// URLs currently in fallback process (HTTPS failed, HTTP being attempted).
    private var fallbackInProgress: Set<String> = []

    /// Maximum number of failed URLs to remember (to avoid memory growth).
    private let maxFailedCacheSize = 100

    /// Attempt to upgrade an HTTP URL to HTTPS.
    /// Returns the HTTPS URL if upgrade is possible, nil otherwise.
    func upgradeURL(_ url: URL) -> URL? {
        // Only upgrade HTTP URLs
        guard url.scheme?.lowercased() == "http" else { return nil }

        // Don't retry failed upgrades
        let urlString = url.absoluteString
        guard !failedUpgrades.contains(urlString) else { return nil }

        // Don't upgrade URLs that are already in fallback
        guard !fallbackInProgress.contains(urlString) else { return nil }

        // Convert to HTTPS
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    /// Record a failed HTTPS upgrade attempt.
    /// The URL will be added to the failed cache and won't be upgraded again.
    func recordFailedUpgrade(_ httpURL: URL) {
        let urlString = httpURL.absoluteString
        failedUpgrades.insert(urlString)

        // Evict oldest entries if cache is too large
        if failedUpgrades.count > maxFailedCacheSize {
            let toRemove = failedUpgrades.prefix(failedUpgrades.count - maxFailedCacheSize)
            failedUpgrades.subtract(toRemove)
        }
    }

    /// Mark a URL as being in fallback mode (HTTPS failed, HTTP being attempted).
    func beginFallback(_ httpURL: URL) {
        fallbackInProgress.insert(httpURL.absoluteString)
    }

    /// Clear the fallback marker for a URL (fallback completed).
    func endFallback(_ httpURL: URL) {
        fallbackInProgress.remove(httpURL.absoluteString)
    }

    /// Clear all failed upgrade records (useful for manual reset).
    func clearFailedUpgrades() {
        failedUpgrades.removeAll()
    }

    /// Clear all fallback markers.
    func clearFallbackMarkers() {
        fallbackInProgress.removeAll()
    }

    /// Check if a URL should be allowed without upgrade (for back/forward navigation).
    /// Returns true if this is a known HTTP URL that has failed HTTPS upgrade.
    func shouldAllowHTTPDirectly(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return failedUpgrades.contains(url.absoluteString)
    }
}