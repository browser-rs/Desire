//
//  ScreenshotAnnotationRenderer.swift
//  Desire
//
//  Created by mankong on 2026/7/5.
//

import AppKit
import CoreGraphics

extension ScreenshotColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

enum ScreenshotAnnotationRenderer {
    /// Draw a single annotation into a CGContext that has been set up with
    /// the same top-left coordinate system as the overlay view (origin top-left,
    /// y down). Points are in canvas absolute coordinates.
    static func draw(
        _ annotation: ScreenshotAnnotation,
        in ctx: CGContext,
        canvasSize: CGSize,
        mosaicSource: NSImage?
    ) {
        let nsColor = annotation.color.nsColor
        let cgColor = nsColor.cgColor

        ctx.saveGState()
        ctx.setLineWidth(annotation.strokeWidth)
        ctx.setStrokeColor(cgColor)
        ctx.setFillColor(cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch annotation.tool {
        case .select:
            break

        case .rectangle:
            guard annotation.points.count >= 2 else { break }
            let p1 = annotation.points[0]
            let p2 = annotation.points[1]
            let rect = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            )
            if annotation.fillEnabled {
                ctx.fill(rect)
            } else {
                ctx.stroke(rect)
            }

        case .ellipse:
            guard annotation.points.count >= 2 else { break }
            let p1 = annotation.points[0]
            let p2 = annotation.points[1]
            let rect = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            )
            if annotation.fillEnabled {
                ctx.fillEllipse(in: rect)
            } else {
                ctx.strokeEllipse(in: rect)
            }

        case .arrow:
            guard annotation.points.count >= 2 else { break }
            let p1 = annotation.points[0]
            let p2 = annotation.points[1]
            ctx.move(to: p1)
            ctx.addLine(to: p2)
            ctx.strokePath()

            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let length = sqrt(dx * dx + dy * dy)
            guard length > 1 else { break }
            let ux = dx / length
            let uy = dy / length
            let arrowLength: CGFloat = max(12, annotation.strokeWidth * 5)
            let arrowAngle: CGFloat = .pi / 7
            let cosA = cos(arrowAngle)
            let sinA = sin(arrowAngle)
            let tip1 = CGPoint(
                x: p2.x - arrowLength * (ux * cosA - uy * sinA),
                y: p2.y - arrowLength * (ux * sinA + uy * cosA)
            )
            let tip2 = CGPoint(
                x: p2.x - arrowLength * (ux * cosA + uy * sinA),
                y: p2.y - arrowLength * (-ux * sinA + uy * cosA)
            )
            ctx.move(to: p2)
            ctx.addLine(to: tip1)
            ctx.move(to: p2)
            ctx.addLine(to: tip2)
            ctx.strokePath()

        case .brush:
            guard annotation.points.count >= 2 else { break }
            ctx.move(to: annotation.points[0])
            for i in 1..<annotation.points.count {
                ctx.addLine(to: annotation.points[i])
            }
            ctx.strokePath()

        case .mosaic:
            guard !annotation.points.isEmpty, let mosaicSource else { break }
            guard let mosaicCG = mosaicSource.cgImage(forProposedRect: nil, context: nil, hints: nil) else { break }
            let path = CGMutablePath()
            path.move(to: annotation.points[0])
            if annotation.points.count == 1 {
                path.addLine(to: annotation.points[0])
            } else {
                for i in 1..<annotation.points.count {
                    path.addLine(to: annotation.points[i])
                }
            }
            ctx.addPath(path)
            ctx.setLineWidth(annotation.strokeWidth * 4)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.draw(mosaicCG, in: CGRect(origin: .zero, size: mosaicSource.size))

        case .text:
            guard let text = annotation.text, !text.isEmpty, !annotation.points.isEmpty else { break }
            let point = annotation.points[0]
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: nsColor,
                .font: NSFont.boldSystemFont(ofSize: annotation.fontSize)
            ]
            let nsText = text as NSString
            let textSize = nsText.size(withAttributes: attributes)
            let textRect = CGRect(origin: point, size: textSize)
            nsText.draw(in: textRect, withAttributes: attributes)

        case .number:
            guard !annotation.points.isEmpty else { break }
            let point = annotation.points[0]
            let radius: CGFloat = 12
            let circleRect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            ctx.fillEllipse(in: circleRect)
            let text = String(annotation.number)
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.boldSystemFont(ofSize: 14)
            ]
            let nsText = text as NSString
            let textSize = nsText.size(withAttributes: attributes)
            let textPoint = CGPoint(
                x: point.x - textSize.width / 2,
                y: point.y - textSize.height / 2
            )
            let textRect = CGRect(origin: textPoint, size: textSize)
            nsText.draw(in: textRect, withAttributes: attributes)
        }

        ctx.restoreGState()
    }
}
