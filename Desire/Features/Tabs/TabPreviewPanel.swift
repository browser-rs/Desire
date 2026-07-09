import AppKit
import SwiftUI
import WebKit

/// Floating NSPanel that renders a tab preview above all other windows.
/// Solves the SwiftUI overlay layering problem: preview is no longer
/// clipped by the parent view bounds or hidden behind sibling windows.
@MainActor
final class TabPreviewPanel {
    static let shared = TabPreviewPanel()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<TabPreviewContent>?
    private var currentTabId: UUID?

    private init() {}

    /// Show preview anchored to a screen rect (global coordinates).
    func show(tab: Tab, thumbnail: NSImage?, anchor: CGRect, in window: NSWindow?) {
        let content = TabPreviewContent(
            tab: tab,
            thumbnail: thumbnail,
            isLoading: thumbnail == nil && !tab.isOnNewTabPage
        )

        if let existing = panel {
            // Reuse existing panel — update content and position
            if let host = hostingView {
                host.rootView = content
            }
            currentTabId = tab.id
            position(anchor: anchor, in: window)
            existing.orderFrontRegardless()
            return
        }

        // Create new borderless panel
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = true
        newPanel.isMovable = false

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        newPanel.contentView = host

        self.panel = newPanel
        self.hostingView = host
        self.currentTabId = tab.id

        position(anchor: anchor, in: window)
        newPanel.orderFrontRegardless()
    }

    /// Update the thumbnail without recreating the panel.
    func updateThumbnail(_ thumbnail: NSImage?, for tab: Tab) {
        guard let host = hostingView, currentTabId == tab.id else { return }
        host.rootView = TabPreviewContent(
            tab: tab,
            thumbnail: thumbnail,
            isLoading: thumbnail == nil && !tab.isOnNewTabPage
        )
    }

    /// Hide the preview.
    func hide() {
        panel?.orderOut(nil)
        currentTabId = nil
    }

    private func position(anchor: CGRect, in window: NSWindow?) {
        guard let panel = panel, let screen = window?.screen ?? NSScreen.main else { return }
        let panelSize = panel.frame.size

        // Convert anchor from window-local to global screen coordinates
        let globalAnchor: CGRect
        if let window = window {
            let winFrame = window.frame
            // NSWindow coordinate origin is bottom-left, our anchor uses top-left
            // anchor is in window coordinates with origin top-left
            // Convert to bottom-left origin
            let windowHeight = winFrame.height
            globalAnchor = CGRect(
                x: winFrame.origin.x + anchor.origin.x,
                y: winFrame.origin.y + (windowHeight - anchor.origin.y - anchor.height),
                width: anchor.width,
                height: anchor.height
            )
        } else {
            globalAnchor = anchor
        }

        // Center horizontally on the pill
        var x = globalAnchor.midX - panelSize.width / 2
        // Position above the pill
        var y = globalAnchor.maxY + 8

        // Clamp to screen
        let screenFrame = screen.visibleFrame
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - panelSize.width - 8))

        // If would go above screen, position below
        if y + panelSize.height > screenFrame.maxY {
            y = globalAnchor.minY - panelSize.height - 8
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Preview content

struct TabPreviewContent: View {
    let tab: Tab
    let thumbnail: NSImage?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack {
                if let image = thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            VStack(spacing: 6) {
                                if isLoading {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text(String(localized: "Loading…"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Image(systemName: "photo")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                }
            }
            .frame(height: 160)
            .clipped()

            // Title + URL
            HStack(spacing: 8) {
                faviconOrGlobe
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !tab.isOnNewTabPage {
                        Text(tab.browser.webView.url?.absoluteString ?? tab.urlString)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var faviconOrGlobe: some View {
        if tab.isOnNewTabPage {
            Image(systemName: "asterisk")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        } else {
            FaviconView(urlString: tab.browser.webView.url?.absoluteString ?? tab.urlString, size: 16)
        }
    }
}
