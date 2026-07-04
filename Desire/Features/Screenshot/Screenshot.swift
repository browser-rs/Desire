//
//  Screenshot.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import CoreGraphics
import Foundation

/// Available tools in the screenshot editor toolbar.
enum ScreenshotTool: Int, Codable, Sendable {
    case select
    case rectangle
    case ellipse
    case arrow
    case brush
    case mosaic
    case text
    case number
}

/// A resize handle on the selection rect. Used for hit-testing during mouseDown.
enum ScreenshotHandle: Int, Sendable {
    case none
    case body
    case topLeft, top, topRight
    case right, bottomRight, bottom
    case bottomLeft, left
}

/// Top-level interaction state of the overlay.
enum ScreenshotMode: Sendable {
    case idle
    case drawingSelection
    case editing
    case drawingAnnotation(ScreenshotTool)
    case adjustingSelection(handle: ScreenshotHandle)
}

/// Codable RGB color for annotations. Avoids NSColor archiving fragility
/// across deviceRGB / genericRGB / sRGB color spaces.
struct ScreenshotColor: Codable, Sendable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let red    = ScreenshotColor(r: 1.0, g: 0.2,  b: 0.2,  a: 1.0)
    static let orange = ScreenshotColor(r: 1.0, g: 0.584, b: 0.0,  a: 1.0)
    static let yellow = ScreenshotColor(r: 1.0, g: 0.8,  b: 0.0,  a: 1.0)
    static let green  = ScreenshotColor(r: 0.204, g: 0.78, b: 0.349, a: 1.0)
    static let blue   = ScreenshotColor(r: 0.0, g: 0.478, b: 1.0,  a: 1.0)
    static let black  = ScreenshotColor(r: 0.0, g: 0.0,  b: 0.0,  a: 1.0)
    static let white  = ScreenshotColor(r: 1.0, g: 1.0,  b: 1.0,  a: 1.0)

    static let palette: [ScreenshotColor] = [.red, .orange, .yellow, .green, .blue, .black, .white]
}

/// One annotation on the screenshot. Points are in canvas absolute coordinates;
/// the selection rect is a viewport that clips annotations, never transforms them.
struct ScreenshotAnnotation: Identifiable, Codable, Sendable {
    let id: UUID
    let tool: ScreenshotTool
    var points: [CGPoint]
    var color: ScreenshotColor
    var strokeWidth: CGFloat
    var text: String?
    var number: Int
    /// Shapes (rectangle/ellipse) render filled when true, outlined when false.
    var fillEnabled: Bool = false
    /// Font size for text annotations (points).
    var fontSize: CGFloat = 16

    init(id: UUID = UUID(),
         tool: ScreenshotTool,
         points: [CGPoint] = [],
         color: ScreenshotColor = .red,
         strokeWidth: CGFloat = 2,
         text: String? = nil,
         number: Int = 0,
         fillEnabled: Bool = false,
         fontSize: CGFloat = 16) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.strokeWidth = strokeWidth
        self.text = text
        self.number = number
        self.fillEnabled = fillEnabled
        self.fontSize = fontSize
    }
}

/// Result of a completed screenshot session, returned to the host app.
enum ScreenshotResult: Sendable {
    case cancelled
    case saved(URL)
    case copied
}
