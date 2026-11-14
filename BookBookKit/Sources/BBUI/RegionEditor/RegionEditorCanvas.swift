import AppKit
import BBAI
import BBModel
import CoreGraphics
import SwiftUI

/// Phase 11: the region editor's drawing surface (A §6.2). Shows the version aspect-fit and records
/// brush and lasso drags into `RegionEditorModel` in image pixels. The mask preview is replayed from
/// the recorded operations at **screen resolution** (a translucent tint) on every redraw; the full-size
/// bitmap is only made on commit by `ImageOps.rasterize` (phase Risks).
public struct RegionEditorCanvas: NSViewRepresentable {
    public let model: RegionEditorModel
    /// The version, already downsampled for display. nil while it decodes.
    public let image: CGImage?

    public init(model: RegionEditorModel, image: CGImage?) {
        self.model = model
        self.image = image
    }

    public func makeNSView(context: Context) -> RegionEditorCanvasView {
        let view = RegionEditorCanvasView(model: model)
        view.image = image
        return view
    }

    public func updateNSView(_ view: RegionEditorCanvasView, context: Context) {
        // Read what the canvas draws so SwiftUI re-runs this when it changes (Observation).
        _ = model.drawing
        _ = model.tool
        _ = model.brushDiameter
        _ = model.isErasing
        if view.model !== model { view.model = model }
        if view.image !== image { view.image = image }
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

public final class RegionEditorCanvasView: NSView {
    var model: RegionEditorModel
    var image: CGImage? { didSet { needsDisplay = true } }

    /// The tint the edit area is previewed in.
    static var tint: NSColor { NSColor(Crayon.bubblegum).withAlphaComponent(0.55) }

    private var hoverPoint: CGPoint?
    private var cachedMask: (operations: [RegionMaskDrawing.Operation], size: CGSize, image: CGImage)?

    init(model: RegionEditorModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Picture. Drag to mark the area to change.")
        setAccessibilityIdentifier("regionEditor.canvas")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var fitRect: CGRect {
        let size = CGSize(width: model.pixelSize.width, height: model.pixelSize.height)
        return RegionEditorModel.aspectFitRect(imageSize: size, in: bounds.insetBy(dx: 8, dy: 8))
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return RegionEditorModel.imagePoint(fromView: point, fitRect: fitRect, pixelSize: model.pixelSize,
                                            viewIsFlipped: isFlipped)
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        guard !fitRect.isEmpty else { return }
        model.beginStroke(at: imagePoint(event), forceErase: event.modifierFlags.contains(.option))
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        model.continueStroke(to: imagePoint(event))
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        model.endStroke()
        needsDisplay = true
    }

    public override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                              .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    public override func resetCursorRects() {
        // The brush shows its own circle; the lasso a crosshair.
        if model.tool == .lasso { addCursorRect(fitRect, cursor: .crosshair) }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = fitRect
        guard !rect.isEmpty else { return }

        NSColor(Crayon.paperDeep).setFill()
        bounds.fill()

        if let image {
            drawUnflipped(context, in: rect) { context.draw(image, in: $0) }
        } else {
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
        }

        let backing = window?.backingScaleFactor ?? 2
        let maskSize = CGSize(width: (rect.width * backing).rounded(.up), height: (rect.height * backing).rounded(.up))
        if let mask = previewMask(size: maskSize) {
            drawUnflipped(context, in: rect) { maskRect in
                context.clip(to: maskRect, mask: mask)
                context.setFillColor(Self.tint.cgColor)
                context.fill(maskRect)
            }
        }

        drawActiveLassoOutline(context, rect: rect)
        drawBrushCursor(context, rect: rect)
    }

    /// Draws in a context whose y axis points up within `rect` (CGImage and image masks need it).
    private func drawUnflipped(_ context: CGContext, in rect: CGRect, _ body: (CGRect) -> Void) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        body(rect)
        context.restoreGState()
    }

    /// The committed operations (cached) plus the active stroke, as a screen-resolution grayscale mask.
    private func previewMask(size: CGSize) -> CGImage? {
        let operations = model.drawing.operations
        let committed: CGImage?
        if let cachedMask, cachedMask.operations == operations, cachedMask.size == size {
            committed = cachedMask.image
        } else if operations.isEmpty {
            committed = nil
            cachedMask = nil
        } else {
            committed = RegionMaskPreview.render(operations, pixelSize: model.pixelSize, size: size)
            if let committed { cachedMask = (operations, size, committed) }
        }
        guard let active = model.activeStroke?.operation else { return committed }
        return RegionMaskPreview.render([active], pixelSize: model.pixelSize, size: size, base: committed)
    }

    private func drawActiveLassoOutline(_ context: CGContext, rect: CGRect) {
        guard let stroke = model.activeStroke, stroke.tool == .lasso, stroke.points.count > 1 else { return }
        let points = stroke.points.map {
            RegionEditorModel.viewPoint(fromImage: $0, fitRect: rect, pixelSize: model.pixelSize, viewIsFlipped: true)
        }
        context.saveGState()
        context.addLines(between: points)
        context.closePath()
        context.setLineWidth(1.5)
        context.setStrokeColor(NSColor.white.cgColor)
        context.strokePath()
        context.addLines(between: points)
        context.closePath()
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.setStrokeColor(NSColor.black.cgColor)
        context.strokePath()
        context.restoreGState()
    }

    private func drawBrushCursor(_ context: CGContext, rect: CGRect) {
        guard model.tool == .brush, let hoverPoint, rect.insetBy(dx: -4, dy: -4).contains(hoverPoint) else { return }
        let diameter = model.brushDiameter * RegionEditorModel.scale(fitRect: rect, pixelSize: model.pixelSize)
        let circle = CGRect(x: hoverPoint.x - diameter / 2, y: hoverPoint.y - diameter / 2,
                            width: diameter, height: diameter)
        context.saveGState()
        context.setLineWidth(2.5)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.strokeEllipse(in: circle)
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.white.cgColor)
        if model.isErasing || NSEvent.modifierFlags.contains(.option) {
            context.setLineDash(phase: 0, lengths: [3, 3])
        }
        context.strokeEllipse(in: circle)
        context.restoreGState()
    }
}

/// Replays `RegionMaskDrawing` operations into a small grayscale bitmap (white = edit) for the
/// on-screen preview. Not the wire mask: that's `ImageOps.rasterize` at full size.
enum RegionMaskPreview {
    static func render(_ operations: [RegionMaskDrawing.Operation], pixelSize: PixelSize, size: CGSize,
                       base: CGImage? = nil) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, pixelSize.width > 0, pixelSize.height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(full)
        if let base { context.draw(base, in: full) }

        // Image px (top-left origin, y down) → bitmap px (bottom-left origin).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / CGFloat(pixelSize.width), y: -CGFloat(height) / CGFloat(pixelSize.height))
        let imageRect = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)

        for operation in operations {
            switch operation {
            case let .brush(points, diameter, erase):
                guard let first = points.first else { continue }
                let value: CGFloat = erase ? 0 : 1
                if points.count == 1 {
                    context.setFillColor(gray: value, alpha: 1)
                    context.fillEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2,
                                                   width: diameter, height: diameter))
                } else {
                    context.setStrokeColor(gray: value, alpha: 1)
                    context.setLineWidth(diameter)
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    context.addLines(between: points)
                    context.strokePath()
                }
            case let .lasso(points, erase):
                guard points.count >= 3 else { continue }
                context.setFillColor(gray: erase ? 0 : 1, alpha: 1)
                context.addLines(between: points)
                context.closePath()
                context.fillPath(using: .winding)
            case .invert:
                context.saveGState()
                context.setBlendMode(.difference)
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(imageRect)
                context.restoreGState()
            }
        }
        return context.makeImage()
    }
}
