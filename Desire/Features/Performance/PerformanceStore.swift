import Combine
import Foundation
import WebKit

/// Performance manager that handles memory optimization, cache cleanup,
/// and system memory pressure response.
@MainActor
class PerformanceStore: ObservableObject {
    // Memory pressure thresholds (MB)
    private let warningThreshold: Int = 500

    // Memory state
    @Published var memoryUsage: Int = 0
    @Published var isUnderPressure = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        setupMemoryPressureObserver()
    }

    // MARK: - Memory Pressure

    private func setupMemoryPressureObserver() {
        // Listen for system memory pressure notifications
        DistributedNotificationCenter.default
            .publisher(for: Notification.Name("NSApplicationDidReceiveMemoryWarningNotification"))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMemoryWarning()
                }
            }
            .store(in: &cancellables)

        // Also monitor memory usage periodically
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMemoryUsage()
            }
        }
    }

    private func handleMemoryWarning() {
        isUnderPressure = true

        // 1. Clear all caches
        clearAllCaches()

        // 2. Suspend inactive tabs more aggressively
        NotificationCenter.default.post(name: .suspendInactiveTabs, object: nil)

        #if DEBUG
        print("⚠️ Memory warning received - clearing caches")
        #endif
    }

    private func updateMemoryUsage() {
        // Get memory footprint using Darwin API
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), ptr, &count)
            }
        }

        if result == KERN_SUCCESS {
            memoryUsage = Int(info.phys_footprint) / 1024 / 1024

            // Check if under pressure
            if memoryUsage > warningThreshold && !isUnderPressure {
                isUnderPressure = true
                handleMemoryWarning()
            } else if memoryUsage < warningThreshold / 2 {
                isUnderPressure = false
            }
        }
    }

    // MARK: - Cache Management

    func clearAllCaches() {
        // Clear WKWebsiteDataStore
        let dataTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ]

        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast, completionHandler: {})

        // Clear favicon cache
        NotificationCenter.default.post(name: .clearFaviconCache, object: nil)

        // Clear thumbnail cache
        NotificationCenter.default.post(name: .clearThumbnailCache, object: nil)

        // Clear URL cache
        URLCache.shared.removeAllCachedResponses()
    }

    func clearCacheForDomain(_ domain: String) {
        let dataTypes: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeWebSQLDatabases,
            WKWebsiteDataTypeIndexedDBDatabases
        ]

        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: dataTypes) { records in
            let matchingRecords = records.filter { record in
                record.displayName.contains(domain)
            }
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, for: matchingRecords, completionHandler: {})
        }
    }

    // MARK: - Tab Memory Optimization

    /// Suspend a tab to free memory. The WKWebView is kept but the page is unloaded.
    func suspendTab(_ tab: Tab) {
        guard !tab.isSuspended else { return }

        tab.isSuspended = true

        // Stop loading and clear the page
        tab.browser.webView.stopLoading()
        tab.browser.webView.loadHTMLString("", baseURL: nil)
    }

    /// Resume a suspended tab by reloading the original URL.
    func resumeTab(_ tab: Tab) {
        guard tab.isSuspended else { return }

        tab.isSuspended = false

        if let url = URL(string: tab.urlString), !tab.isOnNewTabPage {
            tab.browser.webView.load(URLRequest(url: url))
        }
    }

    /// Get the most appropriate tabs to suspend based on memory pressure.
    func getTabsToSuspend(from tabs: [Tab], selectedTab: Tab?) -> [Tab] {
        let sortedTabs = tabs
            .filter { $0.id != selectedTab?.id && !$0.isPinned && !$0.isIncognito && !$0.isSuspended }
            .sorted { $0.lastAccessed < $1.lastAccessed }

        // Under critical pressure, suspend more aggressively
        let suspendCount = memoryUsage > warningThreshold ? 5 : 2

        return Array(sortedTabs.prefix(suspendCount))
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let suspendInactiveTabs = Notification.Name("suspendInactiveTabs")
    static let clearFaviconCache = Notification.Name("clearFaviconCache")
    static let clearThumbnailCache = Notification.Name("clearThumbnailCache")
}