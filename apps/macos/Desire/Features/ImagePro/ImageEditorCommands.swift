import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// ImagePro 命令 API（v0.8.46）：UI、桥、Agent 共用同一套动作。
/// 所有坐标 = **base 像素（左上原点、y 向下）**，与缩放/平移无关。
/// 入口：`POST /image/edit`、Agent 工具 `editImage`。
@MainActor
enum ImageEditorCommands {

    // MARK: - 入口

    static func apply(_ body: [String: Any],
                      session: ImageEditorSession?) -> [String: Any] {
        guard let session else {
            return ["error": "No image editor is open. Open an image in a tab first."]
        }
        guard let action = (body["action"] as? String)?.lowercased(), !action.isEmpty else {
            return ["error": "Missing action. See /image/edit for supported actions."]
        }
        let document = session.document
        if document.isActiveLayerLocked,
           ["brush", "stroke", "eraser", "shape", "text", "fill", "mosaic",
            "move", "retouch"].contains(action) {
            return ["error": "Layer is locked"]
        }
        do {
            switch action {
            case "state":
                return state(session)
            case "settool", "tool":
                guard let name = body["tool"] as? String,
                      let tool = ImageEditorTool(rawValue: name.lowercased()) else {
                    return ["error": "Unknown tool"]
                }
                session.tool = tool
                return ["ok": true, "tool": tool.rawValue]
            case "brush", "stroke":
                guard let raw = body["points"] as? [[Any]],
                      let points = Self.points(raw) else {
                    return ["error": "brush needs points: [[x,y], ...]"]
                }
                return try brush(points: points, body: body, session: session, document: document)
            case "eraser":
                guard let raw = body["points"] as? [[Any]],
                      let points = Self.points(raw) else {
                    return ["error": "eraser needs points: [[x,y], ...]"]
                }
                return try brush(points: points, body: body, session: session,
                                 document: document, erase: true)
            case "shape":
                return try shape(body: body, session: session, document: document)
            case "text":
                return try text(body: body, session: session, document: document)
            case "fill":
                return try fill(body: body, document: document)
            case "mosaic":
                return try mosaic(body: body, document: document)
            case "retouch":
                guard let rawMode = (body["mode"] as? String)?.lowercased(),
                      let mode = ImageRetouchMode(rawValue: rawMode) else {
                    return ["error": "retouch needs mode: clone|heal|dodge|burn|blur|sharpen"]
                }
                guard let raw = body["points"] as? [[Any]], let pts = Self.points(raw),
                      pts.isEmpty == false else {
                    return ["error": "retouch needs points: [[x,y], ...]"]
                }
                document.bakeActiveLayerGeometry()
                guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
                let size = Self.number(body["size"]).map { CGFloat($0) } ?? session.brushSize
                let strength = Self.number(body["strength"]) ?? session.retouchStrength
                let sample = Self.point(body["sample"])
                var current = bitmap
                let first = pts[0]
                for p in pts {
                    var source: CGPoint?
                    if let sample {
                        source = CGPoint(x: sample.x + (p.x - first.x),
                                         y: sample.y + (p.y - first.y))
                    }
                    guard let next = ImageEditorRaster.retouch(current, mode: mode, at: p,
                                                               radius: max(1, size / 2),
                                                               strength: strength,
                                                               source: source) else { continue }
                    current = next
                }
                document.replaceActiveBitmap(current, title: mode.localizedTitle)
                return ["ok": true, "points": pts.count]
            case "place":
                guard let path = body["path"] as? String,
                      let image = ImageTransforms.load(
                        from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else {
                    return ["error": "place needs a readable image path"]
                }
                document.placeImage(image, name: (path as NSString).lastPathComponent)
                return ["ok": true, "layers": document.layers.count]
            case "newdoc":
                let w = Self.number(body["width"]) ?? 1280
                let h = Self.number(body["height"]) ?? 720
                let name = (body["name"] as? String) ?? "Untitled"
                session.newDocument(size: CGSize(width: w, height: h), name: name)
                return ["ok": true, "width": Int(session.canvasSize.width),
                        "height": Int(session.canvasSize.height)]
            case "canvassize":
                guard let w = Self.number(body["width"]),
                      let h = Self.number(body["height"]) else {
                    return ["error": "canvassize needs width and height"]
                }
                document.resizeCanvas(to: CGSize(width: w, height: h))
                return ["ok": true, "width": Int(document.canvasSize.width),
                        "height": Int(document.canvasSize.height)]
            case "crop":
                guard let rect = Self.rect(body["rect"]) else {
                    return ["error": "crop needs rect: [x, y, width, height]"]
                }
                document.crop(to: rect)
                return ["ok": true, "width": Int(document.canvasSize.width),
                        "height": Int(document.canvasSize.height)]
            case "resize":
                let w = Self.number(body["width"]).map { CGFloat($0) }
                let h = Self.number(body["height"]).map { CGFloat($0) }
                guard w != nil || h != nil else { return ["error": "resize needs width or height"] }
                let current = document.canvasSize
                let targetW = w ?? current.width * ((h ?? current.height) / current.height)
                let targetH = h ?? current.height * ((w ?? current.width) / current.width)
                document.resize(to: CGSize(width: targetW.rounded(), height: targetH.rounded()))
                return ["ok": true, "width": Int(document.canvasSize.width),
                        "height": Int(document.canvasSize.height)]
            case "rotate":
                let direction = (body["direction"] as? String)?.lowercased() ?? "cw"
                document.rotate(clockwise: direction != "ccw")
                return ["ok": true, "width": Int(document.canvasSize.width),
                        "height": Int(document.canvasSize.height)]
            case "move":
                let dx = Self.number(body["dx"]) ?? 0
                let dy = Self.number(body["dy"]) ?? 0
                document.nudgeActiveLayer(dx: CGFloat(dx), dy: CGFloat(dy))
                return ["ok": true, "dx": dx, "dy": dy]
            case "flip":
                let axis = (body["axis"] as? String)?.lowercased() ?? "h"
                document.flip(horizontal: axis != "v")
                return ["ok": true]
            case "select":
                return select(body: body, session: session, document: document)
            case "preview":
                var params = ImageAdjustParams()
                params.brightness = Self.number(body["brightness"]) ?? 0
                params.contrast = Self.number(body["contrast"]) ?? 1
                params.saturation = Self.number(body["saturation"]) ?? 1
                params.exposure = Self.number(body["exposure"]) ?? 0
                params.temperature = Self.number(body["temperature"]) ?? 0
                params.tint = Self.number(body["tint"]) ?? 0
                params.highlights = Self.number(body["highlights"]) ?? 0
                params.shadows = Self.number(body["shadows"]) ?? 0
                params.vibrance = Self.number(body["vibrance"]) ?? 0
                params.clarity = Self.number(body["clarity"]) ?? 0
                params.sharpen = Self.number(body["sharpen"]) ?? 0
                params.vignette = Self.number(body["vignette"]) ?? 0
                params = ImageAdjustParams.clamped(params)
                let preset = (body["filter"] as? String).flatMap { ImageFilterPreset(rawValue: $0.lowercased()) }
                document.setPreview(adjust: params.isNeutral ? nil : params, filter: preset)
                return ["ok": true, "previewing": document.previewAdjust != nil || document.previewFilter != nil]
            case "cancelpreview":
                document.clearPreview()
                return ["ok": true]
            case "adjust":
                var params = ImageAdjustParams()
                params.brightness = Self.number(body["brightness"]) ?? 0
                params.contrast = Self.number(body["contrast"]) ?? 1
                params.saturation = Self.number(body["saturation"]) ?? 1
                params.exposure = Self.number(body["exposure"]) ?? 0
                params.temperature = Self.number(body["temperature"]) ?? 0
                params.tint = Self.number(body["tint"]) ?? 0
                params.highlights = Self.number(body["highlights"]) ?? 0
                params.shadows = Self.number(body["shadows"]) ?? 0
                params.vibrance = Self.number(body["vibrance"]) ?? 0
                params.clarity = Self.number(body["clarity"]) ?? 0
                params.sharpen = Self.number(body["sharpen"]) ?? 0
                params.vignette = Self.number(body["vignette"]) ?? 0
                params = ImageAdjustParams.clamped(params)
                guard params.isNeutral == false else { return ["error": "adjust params are neutral"] }
                document.applyAdjust(params)
                return ["ok": true]
            case "filter":
                let name = (body["name"] as? String) ?? (body["preset"] as? String) ?? ""
                guard let preset = ImageFilterPreset(rawValue: name.lowercased()),
                      preset != .none else {
                    return ["error": "Unknown filter '\(name)'. Options: "
                        + ImageFilterPreset.allCases.map(\.rawValue).joined(separator: ", ")]
                }
                document.applyFilter(preset)
                return ["ok": true, "filter": preset.rawValue]
            case "layer":
                return layer(body: body, document: document)
            case "dumpcomposite":
                guard let path = body["path"] as? String,
                      let image = document.composite(),
                      let data = NSBitmapImageRep(cgImage: image)
                        .representation(using: .png, properties: [:]) else {
                    return ["error": "no composite"]
                }
                try data.write(to: URL(fileURLWithPath: path))
                return ["ok": true, "path": path, "revision": document.revision,
                        "cachedRevision": document.debugCachedRevision]
            case "dumplayer":
                guard let path = body["path"] as? String,
                      let bitmap = document.activeBitmap,
                      let data = NSBitmapImageRep(cgImage: bitmap)
                        .representation(using: .png, properties: [:]) else {
                    return ["error": "no active layer"]
                }
                try data.write(to: URL(fileURLWithPath: path))
                return ["ok": true, "path": path,
                        "width": bitmap.width, "height": bitmap.height]
            case "dumpmask":
                // DEBUG 排障：把当前选区蒙版写成 PNG（检查 y 方向约定）。
                guard let path = body["path"] as? String,
                      let mask = document.selection.maskImage(canvasSize: document.canvasSize),
                      let data = NSBitmapImageRep(cgImage: mask)
                        .representation(using: .png, properties: [:]) else {
                    return ["error": "no mask"]
                }
                try data.write(to: URL(fileURLWithPath: path))
                return ["ok": true, "path": path]
            case "undo":
                document.undo()
                return ["ok": true, "history": document.historyTitles.count]
            case "redo":
                document.redo()
                return ["ok": true, "history": document.historyTitles.count]
            case "save":
                let saved = session.saveInPlace()
                return ["ok": saved, "path": session.fileURL?.path ?? ""]
            case "export":
                guard let path = body["path"] as? String, !path.isEmpty else {
                    return ["error": "export needs path"]
                }
                let format = (body["format"] as? String)
                    ?? (path as NSString).pathExtension.lowercased()
                let quality = Self.number(body["quality"]) ?? 0.92
                let ok = session.export(format: format,
                                        to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                                        quality: quality)
                return ["ok": ok, "path": path]
            case "zoom", "fit":
                if action == "fit" || (body["scale"] as? String) == "fit" {
                    session.canvas.fit()
                } else if let scale = Self.number(body["scale"]) {
                    session.canvas.zoom(to: CGFloat(scale), anchor: CGPoint(
                        x: session.canvas.containerSize.width / 2,
                        y: session.canvas.containerSize.height / 2))
                } else {
                    return ["error": "zoom needs scale (number or \"fit\")"]
                }
                return ["ok": true, "zoom": Double(session.canvas.zoom)]
            default:
                return ["error": "Unknown action '\(action)'"]
            }
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - 动作实现

    private struct CommandError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private static func lockedError(_ document: ImageEditorDocument) -> [String: Any]? {
        document.isActiveLayerLocked ? ["error": "Layer is locked"] : nil
    }

    private static func brush(points: [CGPoint], body: [String: Any],
                              session: ImageEditorSession,
                              document: ImageEditorDocument,
                              erase: Bool = false) throws -> [String: Any] {
        document.bakeActiveLayerGeometry()
        guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
        guard points.isEmpty == false else { return ["error": "points is empty"] }
        let size = Self.number(body["size"]).map { CGFloat($0) } ?? session.brushSize
        let opacity = Self.number(body["opacity"]) ?? session.brushOpacity
        let hardness = Self.number(body["hardness"]) ?? session.brushHardness
        let color = (body["color"] as? String).flatMap { ImageEditorRaster.color(from: $0) }
            ?? session.primaryCGColor
        let clamped = points.map { clamp($0, to: document.canvasSize) }
        let mask = document.selection.maskImage(canvasSize: document.canvasSize)
        guard let output = ImageEditorRaster.stroke(bitmap, points: clamped, size: size,
                                                    color: color, opacity: CGFloat(opacity),
                                                    hardness: CGFloat(hardness),
                                                    erase: erase,
                                                    clipMask: mask,
                                                    contentOffset: document.activeLayerOffset) else {
            return ["error": "stroke failed"]
        }
        document.replaceActiveBitmap(output, title: erase ? "Erase" : "Brush")
        return ["ok": true, "points": clamped.count]
    }

    private static func shape(body: [String: Any], session: ImageEditorSession,
                              document: ImageEditorDocument) throws -> [String: Any] {
        document.bakeActiveLayerGeometry()
        guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
        guard let from = Self.point(body["from"]), let to = Self.point(body["to"]) else {
            return ["error": "shape needs from:[x,y] and to:[x,y]"]
        }
        let rawKind = (body["kind"] as? String)?.lowercased() ?? "rectangle"
        guard let kind = ImageEditorShape(rawValue: rawKind) else {
            return ["error": "Unknown shape '\(rawKind)'. Options: rectangle, ellipse, line, arrow"]
        }
        let stroke = (body["stroke"] as? String).flatMap { ImageEditorRaster.color(from: $0) }
            ?? session.primaryCGColor
        let fill = (body["fill"] as? String).flatMap { ImageEditorRaster.color(from: $0) }
        let width = Self.number(body["width"]).map { CGFloat($0) } ?? session.lineWidth
        guard let output = ImageEditorRaster.drawShape(
            bitmap, shape: kind, from: clamp(from, to: document.canvasSize),
            to: clamp(to, to: document.canvasSize), stroke: stroke, fill: fill,
            lineWidth: width, contentOffset: document.activeLayerOffset)
        else { return ["error": "shape failed"] }
        document.replaceActiveBitmap(output, title: kind.localizedTitle)
        return ["ok": true]
    }

    private static func text(body: [String: Any], session: ImageEditorSession,
                             document: ImageEditorDocument) throws -> [String: Any] {
        document.bakeActiveLayerGeometry()
        guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
        guard let value = body["text"] as? String, !value.isEmpty else {
            return ["error": "text needs text"]
        }
        let at = Self.point(body["at"]) ?? CGPoint(x: 20, y: 20)
        var style = ImageEditorRaster.TextStyle()
        style.fontSize = Self.number(body["size"]).map { CGFloat($0) } ?? session.fontSize
        style.color = (body["color"] as? String).flatMap { ImageEditorRaster.color(from: $0) }
            ?? session.primaryCGColor
        style.fontName = body["font"] as? String ?? session.textFontFamily
        style.weight = (body["weight"] as? String) ?? session.textWeight
        style.alignment = (body["align"] as? String) ?? session.textAlignment
        style.lineSpacing = Self.number(body["lineSpacing"]).map { CGFloat($0) }
            ?? CGFloat(session.textLineSpacing)
        style.strokeWidth = Self.number(body["strokeWidth"]).map { CGFloat($0) }
            ?? session.textStrokeWidth
        if let hex = body["strokeColor"] as? String,
           let c = ImageEditorRaster.color(from: hex) { style.strokeColor = c }
        style.shadow = (body["shadow"] as? Bool) ?? session.textShadow
        if let hex = body["shadowColor"] as? String,
           let c = ImageEditorRaster.color(from: hex) { style.shadowColor = c }
        if (body["background"] as? Bool) ?? session.textBackground {
            style.backgroundColor = (body["backgroundColor"] as? String)
                .flatMap { ImageEditorRaster.color(from: $0) }
                ?? ImageEditorRaster.color(from: NSColor(session.textBackgroundColor))
        }
        guard let output = ImageEditorRaster.drawText(
            bitmap, text: value, at: clamp(at, to: document.canvasSize),
            style: style, contentOffset: document.activeLayerOffset) else {
            return ["error": "text failed"]
        }
        document.replaceActiveBitmap(output, title: "Text")
        return ["ok": true]
    }

    private static func fill(body: [String: Any], document: ImageEditorDocument) throws -> [String: Any] {
        guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
        guard let hex = body["color"] as? String,
              let color = ImageEditorRaster.color(from: hex) else {
            return ["error": "fill needs color (hex)"]
        }
        let rect = Self.rect(body["rect"])
            ?? CGRect(origin: .zero, size: document.canvasSize)
        guard let ctx = ImageEditorRaster.drawingContext(bitmap) else {
            return ["error": "fill failed"]
        }
        let offset = document.activeLayerOffset
        if offset != .zero {
            ctx.translateBy(x: -offset.width, y: -offset.height)
        }
        ctx.setFillColor(color)
        ctx.fill(rect)
        guard let filled = ctx.makeImage() else { return ["error": "fill failed"] }
        var output = filled
        if let mask = document.selection.maskImage(canvasSize: document.canvasSize),
           let blended = ImageEditorRaster.maskedBlend(base: bitmap, effect: filled,
                                                       mask: mask) {
            output = blended
        }
        document.replaceActiveBitmap(output, title: "Fill")
        return ["ok": true]
    }

    private static func mosaic(body: [String: Any], document: ImageEditorDocument) throws -> [String: Any] {
        guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
        let rect = Self.rect(body["rect"])
            ?? document.selection.bounds(canvasSize: document.canvasSize)
        guard var target = rect else { return ["error": "mosaic needs rect or a selection"] }
        target = target.intersection(CGRect(origin: .zero, size: document.canvasSize))
        let block = Self.number(body["block"]).map { CGFloat($0) } ?? 12
        guard let output = ImageEditorRaster.mosaic(bitmap, rect: target, block: block,
                                               contentOffset: document.activeLayerOffset) else {
            return ["error": "mosaic failed"]
        }
        document.replaceActiveBitmap(output, title: "Mosaic")
        return ["ok": true]
    }

    private static func select(body: [String: Any], session: ImageEditorSession,
                               document: ImageEditorDocument) -> [String: Any] {
        let kind = (body["kind"] as? String)?.lowercased() ?? "rect"
        let feather = Self.number(body["feather"]) ?? session.selectionFeather
        let combine = ImageEditorRaster.SelectionCombine(
            rawValue: (body["mode"] as? String)?.lowercased() ?? "replace") ?? .replace
        switch kind {
        case "clear", "none", "deselect":
            document.clearSelection()
            return ["ok": true, "selection": "none"]
        case "all":
            document.selectAll()
            return ["ok": true, "selection": "all"]
        case "invert":
            document.invertSelection()
            return ["ok": true, "selection": document.selection.describe]
        case "rect", "ellipse":
            guard let rect = Self.rect(body["rect"]) else {
                return ["error": "select rect needs rect: [x, y, w, h]"]
            }
            document.setSelectionRect(rect, ellipse: kind == "ellipse",
                                      feather: feather, combine: combine)
            return ["ok": true, "selection": document.selection.describe]
        case "lasso":
            guard let raw = body["points"] as? [[Any]], let pts = Self.points(raw), pts.count >= 3 else {
                return ["error": "lasso needs points: [[x,y], ...]"]
            }
            let mask = ImageEditorRaster.polygonMask(points: pts,
                                                     size: document.canvasSize,
                                                     feather: 0)
            document.setSelectionMask(mask, feather: feather, combine: combine)
            return ["ok": true, "selection": document.selection.describe]
        case "wand", "magicwand":
            guard let at = Self.point(body["at"]) ?? Self.rect(body["rect"]).map({
                CGPoint(x: $0.midX, y: $0.midY)
            }) else { return ["error": "wand needs at:[x,y]"] }
            guard let composite = document.composite(),
                  let mask = ImageSelectionAdvanced.magicWandMask(
                      image: composite, start: at,
                      tolerance: Self.number(body["tolerance"]) ?? session.wandTolerance,
                      contiguous: true) else {
                return ["error": "wand failed"]
            }
            document.setSelectionMask(mask, feather: feather, combine: combine)
            return ["ok": true, "selection": document.selection.describe]
        default:
            return ["error": "Unknown selection kind '\(kind)'"]
        }
    }

    private static func layer(body: [String: Any], document: ImageEditorDocument) -> [String: Any] {
        let op = (body["op"] as? String)?.lowercased() ?? "add"
        switch op {
        case "add":
            _ = document.addLayer(name: body["name"] as? String)
            return ["ok": true, "layers": document.layers.count]
        case "duplicate":
            document.duplicateActiveLayer()
            return ["ok": true, "layers": document.layers.count]
        case "delete":
            document.deleteActiveLayer()
            return ["ok": true, "layers": document.layers.count]
        case "merge":
            document.mergeDown()
            return ["ok": true, "layers": document.layers.count]
        case "flatten":
            document.flattenLayers()
            return ["ok": true, "layers": document.layers.count]
        case "scale":
            guard let id = document.activeLayer?.id else { return ["error": "No active layer"] }
            document.setLayerScale(id, Self.number(body["scale"]) ?? 1)
            return ["ok": true]
        case "rotate":
            guard let id = document.activeLayer?.id else { return ["error": "No active layer"] }
            document.setLayerRotation(id, Self.number(body["angle"]) ?? 0)
            return ["ok": true]
        case "resett": 
            guard let id = document.activeLayer?.id else { return ["error": "No active layer"] }
            document.resetLayerTransform(id)
            return ["ok": true]
        case "lock":
            guard let id = document.activeLayer?.id else { return ["error": "No active layer"] }
            document.setLayerLocked(id, locked: true)
            return ["ok": true, "locked": true]
        case "unlock":
            guard let id = document.activeLayer?.id else { return ["error": "No active layer"] }
            document.setLayerLocked(id, locked: false)
            return ["ok": true, "locked": false]
        case "up":
            document.moveActiveLayer(up: true)
            return ["ok": true]
        case "down":
            document.moveActiveLayer(up: false)
            return ["ok": true]
        case "select":
            guard let idString = body["id"] as? String,
                  let id = document.layers.first(where: {
                      $0.id.uuidString.lowercased() == idString.lowercased()
                          || $0.name.lowercased() == idString.lowercased()
                  })?.id else {
                return ["error": "No layer matches '\(body["id"] ?? "")'"]
            }
            document.selectLayer(id)
            return ["ok": true, "active": document.activeLayer?.name ?? ""]
        case "visible":
            guard let id = document.activeLayer?.id else { return ["error": "No active layer"] }
            document.setLayerVisible(id, visible: body["visible"] as? Bool ?? true)
            return ["ok": true]
        case "opacity":
            guard let id = document.activeLayer?.id else { return ["error": "No active layer"] }
            document.setLayerOpacity(id, opacity: Self.number(body["opacity"]) ?? 1)
            return ["ok": true]
        case "blend":
            guard let id = document.activeLayer?.id,
                  let raw = body["blend"] as? String,
                  let blend = ImageEditorBlend(rawValue: raw.lowercased()) else {
                return ["error": "blend needs blend: normal|multiply|screen|overlay|darken|lighten|add"]
            }
            document.setLayerBlend(id, blend: blend)
            return ["ok": true]
        case "name":
            guard let id = document.activeLayer?.id,
                  let name = body["name"] as? String else {
                return ["error": "name needs name"]
            }
            document.renameLayer(id, name: name)
            return ["ok": true]
        default:
            return ["error": "Unknown layer op '\(op)'"]
        }
    }

    // MARK: - 状态

    private static func state(_ session: ImageEditorSession) -> [String: Any] {
        let document = session.document
        let layers: [[String: Any]] = document.layers.map { layer in
            [
                "id": layer.id.uuidString,
                "name": layer.name,
                "visible": layer.isVisible,
                "opacity": layer.opacity,
                "blend": layer.blend.rawValue,
                "active": layer.id == document.activeLayerID,
            ]
        }
        return [
            "ok": true,
            "file": session.fileURL?.path ?? "",
            "width": Int(document.canvasSize.width),
            "height": Int(document.canvasSize.height),
            "tool": session.tool.rawValue,
            "color": ImageEditorRaster.hexString(from: session.primaryCGColor),
            "layerOffset": [Double(document.activeLayerOffset.width),
                            Double(document.activeLayerOffset.height)],
            "layerScale": document.activeLayer?.scale ?? 1,
            "layerRotation": document.activeLayer?.rotation ?? 0,
            "zoom": Double(session.canvas.zoom),
            "selection": document.selection.describe,
            "selectionEmpty": document.selection.isEmpty,
            "selectionEllipse": document.selection.isEllipse,
            "history": document.historyTitles,
            "redoCount": document.redoCount,
            "dirty": document.isDirty,
            "previewing": document.previewAdjust != nil || document.previewFilter != nil,
            "layers": layers,
        ]
    }

    // MARK: - 解析

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func point(_ value: Any?) -> CGPoint? {
        if let pair = value as? [Any], pair.count >= 2,
           let x = number(pair[0]), let y = number(pair[1]) {
            return CGPoint(x: x, y: y)
        }
        if let dict = value as? [String: Any],
           let x = number(dict["x"]), let y = number(dict["y"]) {
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    static func points(_ raw: [[Any]]) -> [CGPoint]? {
        let pts = raw.compactMap { point($0) }
        return pts.count == raw.count ? pts : nil
    }

    static func rect(_ value: Any?) -> CGRect? {
        if let quad = value as? [Any], quad.count >= 4,
           let x = number(quad[0]), let y = number(quad[1]),
           let w = number(quad[2]), let h = number(quad[3]) {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        if let dict = value as? [String: Any],
           let x = number(dict["x"]), let y = number(dict["y"]),
           let w = number(dict["width"]), let h = number(dict["height"]) {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    private static func clamp(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, point.x), max(0, size.width)),
                y: min(max(0, point.y), max(0, size.height)))
    }
}
