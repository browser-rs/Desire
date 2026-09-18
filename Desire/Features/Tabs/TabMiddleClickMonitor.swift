import AppKit
import os

/// Closes the tab under a middle mouse click.
///
/// SwiftUI has no middle-click gesture, and an NSView overlay on each tab
/// pill would swallow left clicks too. Instead every pill registers its
/// screen-coordinate frame (it already tracks one for hover previews) plus
/// a prebound close closure; a single local NSEvent monitor matches
/// `.otherMouseUp` against the registry. Per-pill closures keep multiple
/// browser windows unambiguous — the fired closure belongs to the window
/// whose pill was hit.
@MainActor
final class TabMiddleClickMonitor {
    static let shared = TabMiddleClickMonitor()

    private struct Entry {
        let rect: CGRect
        let close: () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var monitor: Any?

    func register(frame: CGRect, for id: UUID, close: @escaping () -> Void) {
        entries[id] = Entry(rect: frame, close: close)
        installIfNeeded()
    }

    func unregister(id: UUID) {
        entries.removeValue(forKey: id)
    }

    private func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self, event.buttonNumber == 2 else { return event }
            // Floating hover previews (NSPanel) sit above a tab pill; a
            // middle click there must not close the tab underneath.
            if event.window is NSPanel { return event }
            // Screen coordinates: prefer the event's own location (converted
            // out of its window) — the cursor may have moved between down and
            // up, and NSEvent.mouseLocation is not event-bound.
            let point: NSPoint
            if let win = event.window {
                point = win.convertToScreen(CGRect(origin: event.locationInWindow, size: .zero)).origin
            } else {
                point = NSEvent.mouseLocation
            }
            let rects = self.entries.values.map { entry -> String in
                let r = entry.rect
                return "(\(Int(r.minX)),\(Int(r.minY)))-(\(Int(r.maxX)),\(Int(r.maxY)))"
            }.joined(separator: " ")
            Log.tabs.info("middle-click up at \(Int(point.x), privacy: .public),\(Int(point.y), privacy: .public) over \(self.entries.count, privacy: .public) pill frames: \(rects, privacy: .public)")
            if let hit = self.entries.values.first(where: { $0.rect.contains(point) }) {
                Log.tabs.info("middle-click HIT — firing close")
                hit.close()
                return nil
            }
            return event
        }
    }
}
