import BBAI
import BBAICore
import BBModel
import CoreGraphics
import Foundation
import Testing
@testable import BBUI

/// Phase 11 lane 3: the region editor's availability, coordinate mapping and drawing model.
/// (The full-size mask is `ImageOps`' job and isn't exercised here.)
@MainActor
struct RegionEditorTests {
    static func catalogModel(supportsMask: Bool, name: String) -> CatalogModel {
        CatalogModel(provider: supportsMask ? .openai : .gemini, id: name.lowercased(), displayName: name,
                     image: ImageCapabilities(maxReferenceImages: 4, maxImageBytes: 50_000_000,
                                              maxRequestBytes: 20_000_000, supportsMask: supportsMask,
                                              nativeMultiTurn: false, aspect: .fixed(ratios: ["1:1"]),
                                              quality: [:]))
    }

    // MARK: Availability

    @Test func availabilityFollowsSupportsMask() {
        #expect(RegionEditAvailability.of(Self.catalogModel(supportsMask: true, name: "GPT Image")) == .available)

        let gemini = RegionEditAvailability.of(Self.catalogModel(supportsMask: false, name: "Nano Banana"))
        guard case let .unavailable(reason) = gemini else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("Nano Banana"))
        #expect(reason.contains("follow-up prompt"))
        #expect(!gemini.isAvailable)

        let none = RegionEditAvailability.of(nil)
        #expect(!none.isAvailable)
        #expect(none.reason?.isEmpty == false)
    }

    // MARK: Coordinate mapping

    @Test func aspectFitLetterboxesAWideImage() {
        // 2000×1000 into 400×400: 400×200, centred vertically.
        let rect = RegionEditorModel.aspectFitRect(imageSize: CGSize(width: 2000, height: 1000),
                                                   in: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(rect == CGRect(x: 0, y: 100, width: 400, height: 200))
    }

    @Test func aspectFitPillarboxesATallImage() {
        let rect = RegionEditorModel.aspectFitRect(imageSize: CGSize(width: 1000, height: 2000),
                                                   in: CGRect(x: 10, y: 20, width: 600, height: 400))
        #expect(rect == CGRect(x: 210, y: 20, width: 200, height: 400))
    }

    @Test func aspectFitIsEmptyForDegenerateSizes() {
        #expect(RegionEditorModel.aspectFitRect(imageSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)) == .zero)
        #expect(RegionEditorModel.aspectFitRect(imageSize: CGSize(width: 10, height: 10), in: .zero) == .zero)
    }

    @Test func viewPointMapsToImagePixelsInFlippedAndUnflippedViews() {
        let size = PixelSize(width: 2000, height: 1000)
        let fit = CGRect(x: 0, y: 100, width: 400, height: 200) // letterboxed, scale 0.2
        #expect(RegionEditorModel.scale(fitRect: fit, pixelSize: size) == 0.2)

        // Flipped (y down): top-left of the fit rect is image (0, 0).
        #expect(RegionEditorModel.imagePoint(fromView: CGPoint(x: 0, y: 100), fitRect: fit, pixelSize: size,
                                             viewIsFlipped: true) == CGPoint(x: 0, y: 0))
        #expect(RegionEditorModel.imagePoint(fromView: CGPoint(x: 100, y: 150), fitRect: fit, pixelSize: size,
                                             viewIsFlipped: true) == CGPoint(x: 500, y: 250))
        // Unflipped (y up): the fit rect's top edge is maxY.
        #expect(RegionEditorModel.imagePoint(fromView: CGPoint(x: 100, y: 250), fitRect: fit, pixelSize: size,
                                             viewIsFlipped: false) == CGPoint(x: 500, y: 250))
        #expect(RegionEditorModel.imagePoint(fromView: CGPoint(x: 400, y: 100), fitRect: fit, pixelSize: size,
                                             viewIsFlipped: false) == CGPoint(x: 2000, y: 1000))
    }

    @Test func coordinateMappingRoundTrips() {
        let size = PixelSize(width: 1024, height: 1536)
        let fit = RegionEditorModel.aspectFitRect(imageSize: CGSize(width: 1024, height: 1536),
                                                  in: CGRect(x: 8, y: 8, width: 900, height: 500))
        for flipped in [true, false] {
            for image in [CGPoint(x: 0, y: 0), CGPoint(x: 512, y: 768), CGPoint(x: 1024, y: 1536), CGPoint(x: 37, y: 1201)] {
                let view = RegionEditorModel.viewPoint(fromImage: image, fitRect: fit, pixelSize: size, viewIsFlipped: flipped)
                let back = RegionEditorModel.imagePoint(fromView: view, fitRect: fit, pixelSize: size, viewIsFlipped: flipped)
                #expect(abs(back.x - image.x) < 1e-9 && abs(back.y - image.y) < 1e-9)
            }
        }
    }

    // MARK: Drawing model

    @Test func brushStrokeIsRecordedInImagePixelsWithItsDiameter() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 1024, height: 1024))
        model.brushDiameter = 64
        model.beginStroke(at: CGPoint(x: 100, y: 100))
        model.continueStroke(to: CGPoint(x: 101, y: 100)) // closer than the spacing: dropped
        model.continueStroke(to: CGPoint(x: 200, y: 100))
        model.continueStroke(to: CGPoint(x: 200, y: 300))
        #expect(model.drawing.isEmpty) // not committed until the drag ends
        model.endStroke()
        #expect(model.activeStroke == nil)
        #expect(model.drawing.pixelSize == PixelSize(width: 1024, height: 1024))
        #expect(model.drawing.operations == [
            .brush(points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 300)],
                   diameter: 64, erase: false),
        ])
    }

    @Test func singleClickBrushIsADot() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 512, height: 512))
        model.beginStroke(at: CGPoint(x: 10, y: 20))
        model.endStroke()
        #expect(model.drawing.operations == [.brush(points: [CGPoint(x: 10, y: 20)],
                                                    diameter: RegionEditorModel.defaultBrushDiameter, erase: false)])
    }

    @Test func brushDiameterIsClamped() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 512, height: 512))
        #expect(model.brushDiameter == 48)
        model.brushDiameter = 1
        #expect(model.brushDiameter == RegionEditorModel.brushDiameterRange.lowerBound)
        model.brushDiameter = 10_000
        #expect(model.brushDiameter == RegionEditorModel.brushDiameterRange.upperBound)
    }

    @Test func lassoClosesItsPolygon() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 512, height: 512))
        model.tool = .lasso
        model.beginStroke(at: CGPoint(x: 10, y: 10))
        model.continueStroke(to: CGPoint(x: 100, y: 10))
        model.continueStroke(to: CGPoint(x: 100, y: 100))
        model.endStroke()
        guard case let .lasso(points, erase) = model.drawing.operations.first else {
            Issue.record("expected a lasso"); return
        }
        #expect(!erase)
        #expect(points.first == points.last)
        #expect(points == [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 10), CGPoint(x: 100, y: 100), CGPoint(x: 10, y: 10)])
    }

    @Test func lassoWithTooFewPointsIsDropped() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 512, height: 512))
        model.tool = .lasso
        model.beginStroke(at: CGPoint(x: 10, y: 10))
        model.continueStroke(to: CGPoint(x: 50, y: 10))
        model.endStroke()
        #expect(model.drawing.isEmpty)
    }

    @Test func eraseToggleAndOptionDragProduceErase() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 512, height: 512))
        model.isErasing = true
        model.beginStroke(at: CGPoint(x: 1, y: 1))
        model.endStroke()
        model.isErasing = false
        model.tool = .lasso
        model.beginStroke(at: CGPoint(x: 0, y: 0), forceErase: true) // Option held
        model.continueStroke(to: CGPoint(x: 50, y: 0))
        model.continueStroke(to: CGPoint(x: 50, y: 50))
        model.endStroke()
        model.tool = .brush
        model.beginStroke(at: CGPoint(x: 5, y: 5))
        model.endStroke()

        let erases = model.drawing.operations.map { operation -> Bool? in
            switch operation {
            case let .brush(_, _, erase), let .lasso(_, erase): erase
            case .invert: nil
            }
        }
        #expect(erases == [true, true, false])
    }

    @Test func invertAppendsInvert() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 512, height: 512))
        model.beginStroke(at: CGPoint(x: 1, y: 1))
        model.endStroke()
        model.invert()
        #expect(model.drawing.operations.count == 2)
        #expect(model.drawing.operations.last == .invert)
    }

    @Test func undoRemovesTheLastOperationAndRedoRestoresIt() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 512, height: 512))
        model.beginStroke(at: CGPoint(x: 1, y: 1))
        model.endStroke()
        model.invert()
        model.undoLast()
        #expect(model.drawing.operations.count == 1)
        #expect(model.canRedo)
        model.redoLast()
        #expect(model.drawing.operations.last == .invert)
        model.undoLast()
        model.undoLast()
        #expect(!model.canUndo)
        model.undoLast() // nothing left: a no-op
        #expect(model.drawing.isEmpty)

        // A new stroke clears redo; Clear empties everything.
        model.beginStroke(at: CGPoint(x: 2, y: 2))
        model.endStroke()
        #expect(!model.canRedo)
        model.clear()
        #expect(model.drawing.isEmpty && !model.canUndo && !model.canRedo)
    }

    @Test func submitNeedsOperationsAndANonBlankPrompt() {
        let model = RegionEditorModel(pixelSize: PixelSize(width: 512, height: 512))
        #expect(!model.canSubmit)
        model.prompt = "Make the scarf yellow"
        #expect(!model.canSubmit) // nothing drawn
        model.beginStroke(at: CGPoint(x: 1, y: 1))
        model.endStroke()
        #expect(model.canSubmit)
        model.prompt = "   \n "
        #expect(!model.canSubmit)
        model.prompt = "  Make it yellow  "
        #expect(model.trimmedPrompt == "Make it yellow")
    }

    // MARK: Screen-resolution preview

    @Test func previewMaskReplaysBrushLassoEraseAndInvert() throws {
        let size = PixelSize(width: 100, height: 100)
        func value(_ image: CGImage, x: Int, y: Int) -> UInt8 {
            // Draw into a known gray buffer (top row first) and read one pixel.
            var bytes = [UInt8](repeating: 0, count: image.width * image.height)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width,
                                        space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes[y * image.width + x]
        }
        // Lasso the top-left quarter (image y down), erase a dot in it, then invert. Rendered at half size.
        let operations: [RegionMaskDrawing.Operation] = [
            .lasso(points: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 0, y: 50)],
                   erase: false),
            .brush(points: [CGPoint(x: 10, y: 10)], diameter: 8, erase: true),
        ]
        let mask = try #require(RegionMaskPreview.render(operations, pixelSize: size, size: CGSize(width: 50, height: 50)))
        #expect(value(mask, x: 12, y: 12) == 255) // inside the lasso, top-left
        #expect(value(mask, x: 5, y: 5) == 0)     // erased dot at image (10, 10)
        #expect(value(mask, x: 40, y: 40) == 0)   // outside

        let inverted = try #require(RegionMaskPreview.render(operations + [.invert], pixelSize: size,
                                                             size: CGSize(width: 50, height: 50)))
        #expect(value(inverted, x: 12, y: 12) == 0)
        #expect(value(inverted, x: 5, y: 5) == 255)
        #expect(value(inverted, x: 40, y: 40) == 255)
    }
}
