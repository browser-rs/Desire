import Combine
import SwiftUI
import WebKit

/// 缩略图缓存 Store
/// 负责捕获、缓存和更新标签页的缩略图截图
@MainActor
class TabThumbnailStore: ObservableObject {
    /// 缩略图缓存字典（Tab ID -> 缩略图）
    @Published private var thumbnails: [UUID: NSImage] = [:]

    /// 缩略图尺寸配置
    private let thumbnailSize = CGSize(width: 280, height: 180)

    /// 更新定时器
    private var updateTimer: Timer?

    /// 缩略图过期时间（秒）
    private let expirationInterval: TimeInterval = 30

    /// 缩略图创建时间记录
    private var thumbnailTimestamps: [UUID: Date] = [:]

    /// 正在捕获的 Tab ID 集合（避免重复捕获）
    private var capturingTabs: Set<UUID> = []

    init() {
        startUpdateTimer()
    }

    deinit {
        updateTimer?.invalidate()
    }

    // MARK: - Public Methods

    /// 获取指定 Tab 的缩略图
    /// - Parameter tabId: Tab 的唯一标识
    /// - Returns: 缓存的缩略图，如果不存在或过期则返回 nil
    func thumbnail(for tabId: UUID) -> NSImage? {
        guard let timestamp = thumbnailTimestamps[tabId] else { return nil }

        // 检查是否过期
        let elapsed = Date().timeIntervalSince(timestamp)
        if elapsed > expirationInterval {
            clearThumbnail(for: tabId)
            return nil
        }

        return thumbnails[tabId]
    }

    /// 为指定 Tab 捕获并缓存缩略图
    /// - Parameters:
    ///   - tab: 要捕获的 Tab
    ///   - completion: 捕获完成回调
    func captureThumbnail(for tab: Tab, completion: ((NSImage?) -> Void)? = nil) {
        // 避免重复捕获
        guard !capturingTabs.contains(tab.id) else {
            completion?(thumbnails[tab.id])
            return
        }

        // 不捕获新标签页或暂停的标签页
        guard !tab.isOnNewTabPage, !tab.isSuspended else {
            completion?(nil)
            return
        }

        capturingTabs.insert(tab.id)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: thumbnailSize)
        configuration.afterScreenUpdates = true

        tab.browser.webView.takeSnapshot(with: configuration) { [weak self] image, error in
            guard let self = self, let image = image, error == nil else {
                self?.capturingTabs.remove(tab.id)
                completion?(nil)
                return
            }

            // 缩放图像到目标尺寸
            let resizedImage = self.resizeImage(image, to: self.thumbnailSize)

            self.thumbnails[tab.id] = resizedImage
            self.thumbnailTimestamps[tab.id] = Date()
            self.capturingTabs.remove(tab.id)
            self.objectWillChange.send()

            completion?(resizedImage)
        }
    }

    /// 清除指定 Tab 的缩略图缓存
    /// - Parameter tabId: Tab 的唯一标识
    func clearThumbnail(for tabId: UUID) {
        thumbnails.removeValue(forKey: tabId)
        thumbnailTimestamps.removeValue(forKey: tabId)
        objectWillChange.send()
    }

    /// 清除所有缩略图缓存
    func clearAllThumbnails() {
        thumbnails.removeAll()
        thumbnailTimestamps.removeAll()
        objectWillChange.send()
    }

    /// 更新所有标签页的缩略图
    /// - Parameter tabs: 标签页数组
    func updateThumbnails(for tabs: [Tab]) {
        for tab in tabs {
            // 只更新未过期且不在捕获中的缩略图
            if let timestamp = thumbnailTimestamps[tab.id] {
                let elapsed = Date().timeIntervalSince(timestamp)
                if elapsed > expirationInterval / 2 {
                    captureThumbnail(for: tab)
                }
            } else {
                // 没有缓存的标签页，首次捕获
                captureThumbnail(for: tab)
            }
        }
    }

    /// 定时更新当前选中标签页的缩略图
    /// - Parameter selectedTab: 当前选中的标签页
    func updateSelectedTabThumbnail(_ selectedTab: Tab?) {
        guard let tab = selectedTab, !tab.isOnNewTabPage, !tab.isSuspended else { return }
        captureThumbnail(for: tab)
    }

    // MARK: - Private Methods

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // 定时清理过期缩略图
                self?.cleanExpiredThumbnails()
            }
        }
    }

    private func cleanExpiredThumbnails() {
        let now = Date()
        var expiredIds: [UUID] = []

        for (tabId, timestamp) in thumbnailTimestamps {
            if now.timeIntervalSince(timestamp) > expirationInterval {
                expiredIds.append(tabId)
            }
        }

        for id in expiredIds {
            clearThumbnail(for: id)
        }
    }

    private func resizeImage(_ image: NSImage, to size: CGSize) -> NSImage {
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size),
                   from: CGRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        return resized
    }
}