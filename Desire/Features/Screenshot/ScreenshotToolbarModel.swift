import Combine
import Foundation

/// Active-tool state for the screenshot overlay toolbar.
/// Extracted from `ScreenshotOverlay.swift` (Store per AGENTS.md).
@MainActor class ScreenshotToolbarModel: ObservableObject {
    @Published var activeTool: ScreenshotTool = .select
    @Published var activeColor: ScreenshotColor = .red
    @Published var strokeWidth: CGFloat = 2
    @Published var fontSize: CGFloat = 16
    @Published var fillEnabled: Bool = false
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    /// True when the active color came from NSColorPanel (not the palette).
    /// Used to render the "custom" swatch with the current picked color.
    @Published var customColor: ScreenshotColor?
}
