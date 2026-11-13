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
                      session: ImageEditorSession?) async -> [String: Any] {
        guard let session else {
            // 两种情况共用：① 根本没有打开的编辑器；② 显式给了 session/file
            // 但没匹配到（resolve 刻意不回落 active，防止静默改错文档）。
            return ["error": "No matching image editor. Omit file/session to target " +
                    "the active editor, or list open editors via /image/state (sessions)."]
        }
        guard let action = (body["action"] as? String)?.lowercased(), !action.isEmpty else {
            return ["error": "Missing action. See /image/edit for supported actions."]
        }
        let document = session.document
        if document.isActiveLayerLocked,
           ["brush", "stroke", "eraser", "shape", "fill", "mosaic",
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
            case "liquify":
                guard let raw = body["points"] as? [[Any]],
                      let points = Self.points(raw) else {
                    return ["error": "liquify needs points: [[x,y], ...]"]
                }
                return liquify(points: points, body: body, session: session,
                               document: document)
            case "perspective":
                // 透视校正（v0.8.54 批 8）：4 角（[x,y] 数组，TL/TR/BL/BR）
                // → CIPerspectiveCorrection 拉直 → 裁剪到校正后范围。
                guard let cornersRaw = body["corners"] as? [[Any]],
                      cornersRaw.count == 4 else {
                    return ["error": "perspective needs corners: [[x,y]×4] (TL/TR/BL/BR)"]
                }
                let corners: [CGPoint] = cornersRaw.map { raw in
                    let x = Self.number(raw.count > 0 ? raw[0] : nil).map { CGFloat($0) } ?? 0
                    let y = Self.number(raw.count > 1 ? raw[1] : nil).map { CGFloat($0) } ?? 0
                    return CGPoint(x: x, y: y)
                }
                document.bakeActiveLayerGeometry()
                document.bakeActiveLayerEffects()
                guard let bitmap = document.activeBitmap else {
                    return ["error": "No active layer"]
                }
                let ciInput = CIImage(cgImage: bitmap)
                guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
                    return ["error": "CIPerspectiveCorrection unavailable"]
                }
                filter.setValue(ciInput, forKey: kCIInputImageKey)
                filter.setValue(CIVector(cgPoint: corners[0]), forKey: "inputTopLeft")
                filter.setValue(CIVector(cgPoint: corners[1]), forKey: "inputTopRight")
                filter.setValue(CIVector(cgPoint: corners[2]), forKey: "inputBottomLeft")
                filter.setValue(CIVector(cgPoint: corners[3]), forKey: "inputBottomRight")
                guard let output = filter.outputImage,
                      let rendered = ImagePipelineRenderer.context.createCGImage(
                        output.cropped(to: CGRect(x: 0, y: 0,
                                                  width: bitmap.width,
                                                  height: bitmap.height)),
                        from: CGRect(x: 0, y: 0,
                                     width: bitmap.width, height: bitmap.height)) else {
                    return ["error": "perspective correction failed"]
                }
                document.replaceActiveBitmap(rendered, title: "Perspective")
                let cornerText = corners.map { point in
                    "[\(Int(point.x)),\(Int(point.y))]"
                }.joined(separator: " ")
                return ["ok": true, "corners": cornerText]
            case "shape":
                return try shape(body: body, session: session, document: document)
            case "text":
                return try text(body: body, session: session, document: document)
            case "fill":
                return try fill(body: body, document: document)
            case "mosaic":
                return try mosaic(body: body, document: document)
            case "setclonesample":
                guard let at = Self.point(body["at"]) else { return ["error": "needs at:[x,y]"] }
                session.cloneSample = at
                return ["ok": true]
            case "gradient":
                guard let from = Self.point(body["from"]), let to = Self.point(body["to"]) else {
                    return ["error": "gradient needs from:[x,y] and to:[x,y]"]
                }
                document.bakeActiveLayerGeometry()
                document.bakeActiveLayerEffects()
                guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
                let start = (body["start"] as? String).flatMap { ImageEditorRaster.color(from: $0) }
                    ?? ImageEditorRaster.color(from: NSColor(session.primaryColor))
                let end = (body["end"] as? String).flatMap { ImageEditorRaster.color(from: $0) }
                    ?? ImageEditorRaster.color(from: NSColor(session.secondaryColor))
                let radial = (body["radial"] as? Bool) ?? session.gradientRadial
                let mask = document.selectionMaskImage()
                guard let output = ImageEditorRaster.drawGradient(
                    bitmap, from: from, to: to, colors: [start, end], radial: radial,
                    clipMask: mask, contentOffset: document.activeLayerOffset) else {
                    return ["error": "gradient failed"]
                }
                document.replaceActiveBitmap(output, title: String(localized: "Gradient"))
                return ["ok": true]
            case "retouch":
                guard let rawMode = (body["mode"] as? String)?.lowercased(),
                      let mode = ImageRetouchMode(rawValue: rawMode) else {
                    return ["error": "retouch needs mode: clone|heal|dodge|burn|blur|sharpen"]
                }
                guard let raw = body["points"] as? [[Any]], let pts = Self.points(raw),
                      pts.isEmpty == false else {
                    return ["error": "retouch needs points: [[x,y], ...]"]
                }
                session.retouchMode = mode
                session.tool = .retouch
                document.bakeActiveLayerGeometry()
                document.bakeActiveLayerEffects()
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
            case "dumpsubject":
                guard let path = body["path"] as? String else {
                    return ["error": "dumpsubject needs path"]
                }
                document.bakeActiveLayerGeometry()
                document.bakeActiveLayerEffects()
                guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
                guard let mask = await ImageAICore.subjectMask(bitmap) else {
                    return ["error": "no mask"]
                }
                guard let data = NSBitmapImageRep(cgImage: mask)
                    .representation(using: .png, properties: [:]) else {
                    return ["error": "encode failed"]
                }
                try data.write(to: URL(fileURLWithPath: path))
                let bounds = ImageEditorRaster.maskBounds(mask)
                return ["ok": true, "path": path,
                        "width": mask.width, "height": mask.height,
                        "bounds": bounds.map {
                            [Double($0.minX), Double($0.minY),
                             Double($0.width), Double($0.height)] } ?? []]
            case "cutout":
                let mode = (body["mode"] as? String)?.lowercased() ?? "erase"
                document.bakeActiveLayerGeometry()
                document.bakeActiveLayerEffects()
                guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
                guard let mask = await ImageAICore.subjectMask(bitmap) else {
                    return ["error": "No subject found (subject lifting returned no mask)"]
                }
                // 空蒙版（全黑）也要按"无主体"处理：否则会把整层擦成透明。
                guard let subjectBounds = ImageEditorRaster.maskBounds(mask),
                      subjectBounds.width >= 4, subjectBounds.height >= 4 else {
                    return ["error": "No subject found (empty mask)"]
                }
                guard let cut = ImageAICore.cutout(image: bitmap, mask: mask,
                                                   background: nil) else {
                    return ["error": "cutout failed"]
                }
                if mode == "layer" {
                    document.placeImage(cut, name: "Subject")
                } else {
                    document.replaceActiveBitmap(cut, title: "Remove Background")
                }
                return ["ok": true, "mode": mode]
            case "extractframe":
                guard let path = body["path"] as? String else {
                    return ["error": "extractframe needs path"]
                }
                let time = Self.number(body["time"]) ?? 1.0
                let result = ImageEditorVideo.extractFrame(from: path, time: time)
                if let error = result.error { return ["error": error] }
                guard let image = result.image else { return ["error": "no frame"] }
                document.placeImage(image, name: (path as NSString).lastPathComponent)
                if let export = body["output"] as? String,
                   let data = NSBitmapImageRep(cgImage: image)
                    .representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath:
                        (export as NSString).expandingTildeInPath))
                }
                return ["ok": true, "width": image.width, "height": image.height]
            case "place":
                guard let path = body["path"] as? String,
                      let image = ImageTransforms.load(
                        from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else {
                    return ["error": "place needs a readable image path"]
                }
                document.placeImage(image, name: (path as NSString).lastPathComponent)
                return ["ok": true, "layers": document.layers.count]
            case "template":
                let name = (body["name"] as? String)?.lowercased() ?? ""
                guard let template = ImageEditorTemplate.all.first(where: {
                    $0.id == name || $0.name.lowercased().contains(name)
                }), name.isEmpty == false else {
                    return ["error": "unknown template '\(name)'. Options: "
                        + ImageEditorTemplate.all.map(\.id).joined(separator: ", ")]
                }
                session.newDocument(size: template.size, name: template.name)
                return ["ok": true, "width": template.width, "height": template.height]
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
                      let mask = document.selectionMaskImage(),
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
            case "draft":
                let op = (body["op"] as? String)?.lowercased() ?? "status"
                switch op {
                case "save":
                    guard let image = document.flattened(over: nil) else {
                        return ["error": "nothing to save"]
                    }
                    return ["ok": ImageEditorDraft.save(image, for: session.draftSourceKey)]
                case "restore":
                    return ["ok": session.restoreDraft()]
                case "discard":
                    ImageEditorDraft.remove(for: session.draftSourceKey)
                    return ["ok": true]
                default:
                    return ["ok": true,
                            "exists": ImageEditorDraft.exists(for: session.draftSourceKey),
                            "modified": ImageEditorDraft.modified(for: session.draftSourceKey)?
                                .timeIntervalSince1970 ?? 0,
                            "path": ImageEditorDraft.url(for: session.draftSourceKey).path]
                }
            case "revert":
                return ["ok": session.revertToSaved()]
            case "restoreall":
                // 一键还原到打开时的原图（区别于 revert=重新从磁盘读文件；
                // restoreall 用内存里的只读锚点，另存为/未保存文档也能还原）。
                let restored = document.restoreOriginal()
                return ["ok": true, "restored": restored]
            case "histogram":
                guard let image = document.composite(),
                      let hist = ImageEditorRaster.histogram(image) else {
                    return ["error": "histogram failed"]
                }
                func peak(_ bins: [Int]) -> Int { bins.firstIndex(of: bins.max() ?? 0) ?? 0 }
                return ["ok": true, "rPeak": peak(hist.r), "gPeak": peak(hist.g),
                        "bPeak": peak(hist.b),
                        "width": image.width, "height": image.height]
            case "lookImage", "look":
                return lookImage(body: body, document: document)
            case "copy":
                return ["ok": session.copyToClipboard()]
            case "export":
                guard let path = body["path"] as? String, !path.isEmpty else {
                    return ["error": "export needs path"]
                }
                let format = (body["format"] as? String)
                    ?? (path as NSString).pathExtension.lowercased()
                let quality = Self.number(body["quality"]) ?? 0.92
                var scale = Self.number(body["scale"]) ?? 1
                if let width = Self.number(body["width"]), document.canvasSize.width > 0 {
                    scale = width / document.canvasSize.width
                }
                let ok = session.export(format: format,
                                        to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                                        quality: quality, scale: scale)
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
                document.bakeActiveLayerEffects()
        guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
        guard points.isEmpty == false else { return ["error": "points is empty"] }
        // 蒙版绘制模式（v0.8.54 批 2）：画笔在图层蒙版上画黑/白，不碰内容位图。
        if session.paintOnMask, document.activeLayer?.hasMask == true {
            let radius = (Self.number(body["size"]).map { CGFloat($0) } ?? session.brushSize) / 2
            let gray: Double = erase ? 0 : 1
            for point in points.map({ clamp($0, to: document.canvasSize) }) {
                document.paintMask(at: point, radius: radius, gray: gray)
            }
            return ["ok": true, "paintedOn": "mask", "points": points.count]
        }
        let size = Self.number(body["size"]).map { CGFloat($0) } ?? session.brushSize
        let opacity = Self.number(body["opacity"]) ?? session.brushOpacity
        let hardness = Self.number(body["hardness"]) ?? session.brushHardness
        let color = (body["color"] as? String).flatMap { ImageEditorRaster.color(from: $0) }
            ?? session.primaryCGColor
        let clamped = points.map { clamp($0, to: document.canvasSize) }
        let offset = document.activeLayerOffset
        // 纯矩形选区（无羽化/反选）走几何 clip：蒙版生成 + maskedBlend 全链
        // 在 96MP 上 ~600ms，几何 clip ~0ms，像素结果一致。
        var clipRect: CGRect?
        var clipMask: CGImage?
        if let rect = document.selection.rect, document.selection.feather == 0,
           document.selection.inverted == false, document.selection.isEllipse == false {
            clipRect = rect.offsetBy(dx: -offset.width, dy: -offset.height)
        } else {
            clipMask = document.selectionMaskImage()
        }
        guard let output = ImageEditorRaster.stroke(bitmap, points: clamped, size: size,
                                                    color: color, opacity: CGFloat(opacity),
                                                    hardness: CGFloat(hardness),
                                                    erase: erase,
                                                    clipMask: clipMask,
                                                    clipRect: clipRect,
                                                    contentOffset: offset) else {
            return ["error": "stroke failed"]
        }
        document.replaceActiveBitmap(output, title: erase ? "Erase" : "Brush")
        return ["ok": true, "points": clamped.count]
    }

    /// lookImage（v0.8.55 批 1）：修图闭环的"看"——把画布渲染成 dataURI
    /// 裸返（vision 通道与 screenshot 同机制；执行端按 `visionImage` 键
    /// 特判剥壳，见 BrowserToolProvider+Execution）。mode：
    /// `canvas` 当前合成（含蒙版/样式/组）｜`layer` 活动图层独立内容｜
    /// `before` 原图锚点｜`compare` before|now 同高并排（自检）。
    /// `maxSide` 控制长边（默认 1024，vision 通道的实用分辨率）。
    private static func lookImage(body: [String: Any],
                                  document: ImageEditorDocument) -> [String: Any] {
        let modeRaw = (body["mode"] as? String ?? "canvas").lowercased()
        let maxSide = min(1024, max(128, Self.number(body["maxSide"]).map { CGFloat($0) } ?? 1024))
        let rendered: CGImage?
        switch modeRaw {
        case "layer":
            rendered = document.activeBitmap.map { ImageLookCompare.downscaled($0, maxSide: maxSide) }
        case "before":
            rendered = document.originalImage.map { ImageLookCompare.downscaled($0, maxSide: maxSide) }
            if document.originalImage == nil {
                return ["error": "No original image anchor (use canvas instead)"]
            }
        case "compare":
            guard let before = document.originalImage else {
                return ["error": "No original image anchor (use canvas instead)"]
            }
            guard let now = document.displayComposite(maxSide: maxSide) else {
                return ["error": "composite failed"]
            }
            rendered = ImageLookCompare.compose(
                before: ImageLookCompare.downscaled(before, maxSide: maxSide), after: now)
        default:
            rendered = document.displayComposite(maxSide: maxSide)
        }
        guard let image = rendered else {
            return ["error": "lookImage render failed"]
        }
        guard let uri = ImageAttachment.dataURI(from: NSImage(cgImage: image,
                                                               size: CGSize(width: image.width,
                                                                            height: image.height))) else {
            return ["error": "lookImage encode failed"]
        }
        return ["ok": true, "mode": modeRaw,
                "visionImage": uri,
                "width": image.width, "height": image.height]
    }

    /// 液化变形（v0.8.54 批 7）：brush 命令的 `mode: liquify-push|expand|pinch`
    /// 路径——逐段对内容位图做向前推挤/径向膨胀/收缩（软边位移，非破坏走历史）。
    private static func liquify(points: [CGPoint], body: [String: Any],
                                session: ImageEditorSession,
                                document: ImageEditorDocument) -> [String: Any] {
        document.bakeActiveLayerGeometry()
        document.bakeActiveLayerEffects()
        guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
        guard points.count >= 2 else { return ["error": "liquify needs at least 2 points"] }
        let radius = (Self.number(body["size"]).map { CGFloat($0) } ?? session.brushSize) / 2
        let modeRaw = (body["liquifyMode"] as? String ?? "push").lowercased()
        let mode: LiquifyBrush.Mode
        switch modeRaw {
        case "expand": mode = .expand
        case "pinch": mode = .pinch
        default: mode = .push
        }
        var output = bitmap
        var applied = 0
        for i in 1..<points.count {
            let from = points[i - 1]
            let to = points[i]
            let delta = CGPoint(x: to.x - from.x, y: to.y - from.y)
            if let warped = LiquifyBrush.warp(output, center: to, radius: radius,
                                              mode: mode, delta: delta) {
                output = warped
                applied += 1
            }
        }
        guard applied > 0 else { return ["error": "liquify failed"] }
        document.replaceActiveBitmap(output, title: "Liquify")
        return ["ok": true, "mode": modeRaw, "segments": applied,
                "points": points.count]
    }

    private static func shape(body: [String: Any], session: ImageEditorSession,
                              document: ImageEditorDocument) throws -> [String: Any] {
        document.bakeActiveLayerGeometry()
                document.bakeActiveLayerEffects()
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
            lineWidth: width,
            cornerRadius: Self.number(body["cornerRadius"]).map { CGFloat($0) } ?? 0,
            dashed: (body["dashed"] as? Bool) ?? false,
            contentOffset: document.activeLayerOffset)
        else { return ["error": "shape failed"] }
        document.replaceActiveBitmap(output, title: kind.localizedTitle)
        return ["ok": true]
    }

    /// 文字（可再编辑）：新建 = 自己的透明图层；`layer` = 重编辑该文字层
    /// （未给的字段继承原规格，锚点保留原位）。
    private static func text(body: [String: Any], session: ImageEditorSession,
                             document: ImageEditorDocument) throws -> [String: Any] {
        guard let value = body["text"] as? String, !value.isEmpty else {
            return ["error": "text needs text"]
        }
        // 起始规格：重编辑 = 原规格（未给字段保持原样）；新建 = 会话默认。
        var spec: ImageTextSpec
        let editID = (body["layer"] as? String).flatMap(UUID.init(uuidString:))
        if let editID {
            guard let stored = document.textSpec(of: editID) else {
                return ["error": "layer is not a text layer"]
            }
            guard !document.isLayerLocked(editID) else { return ["error": "Layer is locked"] }
            spec = stored
            spec.text = value
        } else {
            spec = ImageTextSpec(
                text: value,
                anchorX: Double((Self.point(body["at"]) ?? CGPoint(x: 20, y: 20)).x),
                anchorY: Double((Self.point(body["at"]) ?? CGPoint(x: 20, y: 20)).y))
            spec.fontName = session.textFontFamily
            spec.weight = session.textWeight
            spec.fontSize = Double(session.fontSize)
            spec.colorHex = ImageEditorRaster.hexString(from: session.primaryCGColor)
            spec.alignment = session.textAlignment
            spec.lineSpacing = session.textLineSpacing
            spec.strokeWidth = Double(session.textStrokeWidth)
            spec.shadow = session.textShadow
            if session.textBackground {
                spec.backgroundHex = ImageEditorRaster.hexString(
                    from: ImageEditorRaster.color(from: NSColor(session.textBackgroundColor)))
            }
        }
        if let at = Self.point(body["at"]) {
            let clamped = clamp(at, to: document.canvasSize)
            spec.anchorX = Double(clamped.x)
            spec.anchorY = Double(clamped.y)
        }
        if let v = body["font"] as? String { spec.fontName = v }
        if let v = body["weight"] as? String { spec.weight = v }
        if let v = Self.number(body["size"]) { spec.fontSize = v }
        if let v = body["color"] as? String { spec.colorHex = v }
        if let v = body["align"] as? String { spec.alignment = v }
        if let v = Self.number(body["lineSpacing"]) { spec.lineSpacing = v }
        if let v = Self.number(body["strokeWidth"]) { spec.strokeWidth = v }
        if let v = body["strokeColor"] as? String { spec.strokeColorHex = v }
        if let v = body["shadow"] as? Bool { spec.shadow = v }
        if let v = body["background"] as? Bool {
            spec.backgroundHex = v
                ? (body["backgroundColor"] as? String)
                    ?? ImageEditorRaster.hexString(
                        from: ImageEditorRaster.color(from: NSColor(session.textBackgroundColor)))
                : nil
        } else if let v = body["backgroundColor"] as? String, v.isEmpty == false {
            spec.backgroundHex = v
        }
        if let editID {
            guard document.updateTextLayer(editID, spec: spec) else {
                return ["error": "text failed"]
            }
            return ["ok": true, "edited": true, "layer": editID.uuidString]
        }
        guard let id = document.addTextLayer(spec: spec) else {
            return ["error": "text failed"]
        }
        return ["ok": true, "layer": id.uuidString]
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
        if let mask = document.selectionMaskImage(),
           let blended = ImageEditorRaster.maskedBlend(base: bitmap, effect: filled,
                                                       mask: mask) {
            output = blended
        }
        document.replaceActiveBitmap(output, title: "Fill")
        return ["ok": true]
    }

    private static func mosaic(body: [String: Any], document: ImageEditorDocument) throws -> [String: Any] {
        guard let bitmap = document.activeBitmap else { return ["error": "No active layer"] }
        var selection = document.selection
        let rect = Self.rect(body["rect"])
            ?? selection.bounds(canvasSize: document.canvasSize)
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
        case "style":
            guard let id = document.activeLayer?.id else { return ["error": "No active layer"] }
            var style = document.activeLayer?.style ?? ImageLayerStyle()
            if let v = body["shadow"] as? Bool { style.shadowEnabled = v }
            if let v = Self.number(body["shadowRadius"]) { style.shadowRadius = v }
            if let v = Self.number(body["shadowOpacity"]) { style.shadowOpacity = v }
            if let v = Self.number(body["shadowOffsetX"]) { style.shadowOffsetX = v }
            if let v = Self.number(body["shadowOffsetY"]) { style.shadowOffsetY = v }
            if let v = body["shadowColor"] as? String { style.shadowColor = v }
            if let v = body["stroke"] as? Bool { style.strokeEnabled = v }
            if let v = Self.number(body["strokeWidth"]) { style.strokeWidth = v }
            if let v = body["strokeColor"] as? String { style.strokeColor = v }
            if let v = body["glow"] as? Bool { style.glowEnabled = v }
            if let v = Self.number(body["glowRadius"]) { style.glowRadius = v }
            if let v = Self.number(body["glowOpacity"]) { style.glowOpacity = v }
            if let v = body["glowColor"] as? String { style.glowColor = v }
            document.setLayerStyle(id, style: style)
            return ["ok": true, "style": style.isActive]
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
                "text": layer.textSpec != nil,
                "style": layer.style?.isActive ?? false,
                "adjust": layer.adjust?.isNeutral == false,
                "filter": (layer.filter != nil && layer.filter != ImageFilterPreset.none)
                    ? layer.filter!.rawValue : "",
            ]
        }
        return [
            "ok": true,
            "file": session.fileURL?.path ?? "",
            "width": Int(document.canvasSize.width),
            "height": Int(document.canvasSize.height),
            "tool": session.tool.rawValue,
            "color": ImageEditorRaster.hexString(from: session.primaryCGColor),
            "secondaryColor": ImageEditorRaster.hexString(
                from: ImageEditorRaster.color(from: NSColor(session.secondaryColor))),
            "brushSize": Double(session.brushSize),
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
            // 有原图锚点且当前已偏离 = restoreall 有事可做
            "originalAvailable": document.originalImage != nil && document.hasEdits,
            "previewing": document.previewAdjust != nil || document.previewFilter != nil,
            "layers": layers,
            // 多窗口会话清单：AI/脚本据此发现全部打开的编辑器，再用
            // session=<id> / file=<路径> 定向（缺省仍打 active）。
            "sessions": ImageEditorSession.liveSessions.map { s in
                [
                    "id": s.id.uuidString,
                    "file": s.fileURL?.path ?? "",
                    "title": s.displayName,
                    "active": ImageEditorSession.active === s,
                ] as [String: Any]
            },
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
