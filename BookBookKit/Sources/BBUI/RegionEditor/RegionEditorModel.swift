import BBAI
import BBModel
import CoreGraphics
import Foundation
import Observation

/// Phase 11: the region editor's transient state (A §6.2 "Region editor", §7.6). Records the user's
/// brush and lasso operations as a `RegionMaskDrawing` in **image pixel coordinates** (origin top-left,
/// y down). Nothing here is a book edit: undo/redo are local to the sheet and vanish when it closes.
/// The mask is rasterised at full size elsewhere (`ImageOps.rasterize`), never here.
@MainActor
@Observable
public final class RegionEditorModel {
    public enum Tool: String, CaseIterable, Sendable {
        case brush, lasso
    }

    /// Brush diameter range and default, in image pixels.
    public static let brushDiameterRange: ClosedRange<Double> = 8...256
    public static let defaultBrushDiameter: Double = 48

    public var tool: Tool = .brush
    /// The Erase toggle. Option-drag also erases for one stroke.
    public var isErasing = false
    /// Brush diameter in image pixels, clamped to `brushDiameterRange`.
    public var brushDiameter: Double = RegionEditorModel.defaultBrushDiameter {
        didSet {
            let clamped = min(max(brushDiameter, Self.brushDiameterRange.lowerBound), Self.brushDiameterRange.upperBound)
            if clamped != brushDiameter { brushDiameter = clamped }
        }
    }
    public private(set) var drawing: RegionMaskDrawing
    public var prompt = ""

    /// The stroke being dragged (image px), drawn as a live preview. Not part of `drawing` until it ends.
    public private(set) var activeStroke: ActiveStroke?
    private var redoStack: [RegionMaskDrawing.Operation] = []

    public struct ActiveStroke: Equatable, Sendable {
        public var tool: Tool
        public var points: [CGPoint]
        public var diameter: Double
        public var erase: Bool

        /// The operation this stroke would commit, or nil when it's too small (a lasso needs 3 points).
        public var operation: RegionMaskDrawing.Operation? {
            switch tool {
            case .brush:
                guard !points.isEmpty else { return nil }
                return .brush(points: points, diameter: diameter, erase: erase)
            case .lasso:
                guard points.count >= 3 else { return nil }
                var closed = points
                if closed.first != closed.last, let first = closed.first { closed.append(first) }
                return .lasso(points: closed, erase: erase)
            }
        }
    }

    public init(pixelSize: PixelSize) {
        drawing = RegionMaskDrawing(pixelSize: pixelSize)
    }

    public var pixelSize: PixelSize { drawing.pixelSize }
    public var canUndo: Bool { !drawing.operations.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// "Edit Region" is enabled only with something drawn and a non-blank prompt.
    public var canSubmit: Bool { !drawing.isEmpty && !trimmedPrompt.isEmpty }

    // MARK: Strokes

    /// Starts a stroke at `point` (image px). `forceErase` is Option held during the drag.
    public func beginStroke(at point: CGPoint, forceErase: Bool = false) {
        activeStroke = ActiveStroke(tool: tool, points: [point], diameter: brushDiameter,
                                    erase: isErasing || forceErase)
    }

    /// Extends the active stroke. Points closer than a small spacing to the last one are dropped to
    /// keep the drawing compact (a brush keeps about 8 samples per diameter; a lasso one per pixel).
    public func continueStroke(to point: CGPoint) {
        guard var stroke = activeStroke, let last = stroke.points.last else { return }
        let spacing = stroke.tool == .brush ? max(1, stroke.diameter / 8) : 1
        guard hypot(point.x - last.x, point.y - last.y) >= spacing else { return }
        stroke.points.append(point)
        activeStroke = stroke
    }

    /// Commits the active stroke (a lasso closes itself; one with fewer than 3 points is dropped).
    public func endStroke() {
        guard let stroke = activeStroke else { return }
        activeStroke = nil
        if let operation = stroke.operation { append(operation) }
    }

    public func cancelStroke() { activeStroke = nil }

    /// Swaps edit and keep for everything drawn so far.
    public func invert() { append(.invert) }

    public func undoLast() {
        guard let last = drawing.operations.popLast() else { return }
        redoStack.append(last)
    }

    public func redoLast() {
        guard let next = redoStack.popLast() else { return }
        drawing.operations.append(next)
    }

    public func clear() {
        activeStroke = nil
        drawing.operations.removeAll()
        redoStack.removeAll()
    }

    private func append(_ operation: RegionMaskDrawing.Operation) {
        drawing.operations.append(operation)
        redoStack.removeAll()
    }

    // MARK: Coordinate mapping (pure)

    /// The rect an image of `imageSize` occupies when aspect-fit and centred in `bounds`
    /// (letterboxed or pillarboxed). Empty when either size is degenerate.
    public nonisolated static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// View points per image pixel for `fitRect`.
    public nonisolated static func scale(fitRect: CGRect, pixelSize: PixelSize) -> CGFloat {
        guard pixelSize.width > 0 else { return 0 }
        return fitRect.width / CGFloat(pixelSize.width)
    }

    /// Maps a view point to image pixels (origin top-left, y down). `viewIsFlipped` is the view's
    /// `isFlipped`: when false, view y grows upward and is flipped here. Not clamped to the image.
    public nonisolated static func imagePoint(fromView point: CGPoint, fitRect: CGRect, pixelSize: PixelSize,
                                              viewIsFlipped: Bool) -> CGPoint {
        let s = scale(fitRect: fitRect, pixelSize: pixelSize)
        guard s > 0 else { return .zero }
        let x = (point.x - fitRect.minX) / s
        let y = viewIsFlipped ? (point.y - fitRect.minY) / s : (fitRect.maxY - point.y) / s
        return CGPoint(x: x, y: y)
    }

    /// The inverse of `imagePoint(fromView:…)`.
    public nonisolated static func viewPoint(fromImage point: CGPoint, fitRect: CGRect, pixelSize: PixelSize,
                                             viewIsFlipped: Bool) -> CGPoint {
        let s = scale(fitRect: fitRect, pixelSize: pixelSize)
        let x = fitRect.minX + point.x * s
        let y = viewIsFlipped ? fitRect.minY + point.y * s : fitRect.maxY - point.y * s
        return CGPoint(x: x, y: y)
    }
}
