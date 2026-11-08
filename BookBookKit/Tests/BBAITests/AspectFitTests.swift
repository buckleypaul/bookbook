import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct AspectFitTests {
    static let boxes: [(name: String, aspect: Double)] = [
        ("square", 1), ("landscape 3:2", 1.5), ("portrait 2:3", 2.0 / 3), ("very wide 5:1", 5), ("very tall 1:5", 0.2),
        ("slice image box", 540.0 / (0.57 * 792)),
    ]

    @Test(arguments: boxes.map(\.name), QualityLevel.allCases)
    func openAIFitsAreLegal(name: String, quality: QualityLevel) throws {
        let aspect = try #require(Self.boxes.first { $0.name == name }).aspect
        let catalog = try ModelCatalog.bundled()
        for model in catalog.imageModels {
            guard case let .free(minRatio, maxRatio, multiple, minPixels, maxPixels, experimental) = model.image.aspect else {
                Issue.record("expected free")
                continue
            }
            guard case let .pixels(size) = AspectFitter.fit(boxAspect: aspect, model: model, quality: quality) else {
                Issue.record("expected pixels")
                continue
            }
            let ceiling = min(maxPixels, experimental ?? maxPixels)
            #expect(size.width % multiple == 0 && size.height % multiple == 0, "\(name) \(quality) \(size)")
            #expect(size.pixelCount >= minPixels && size.pixelCount <= ceiling, "\(name) \(quality) \(size)")
            let clamped = min(max(aspect, minRatio), maxRatio)
            #expect(abs(log(size.aspect / clamped)) < 0.06, "\(name) \(quality) \(size) vs \(clamped)")
        }
    }

    @Test func extremeBoxesAreClamped() throws {
        let model = try #require(try ModelCatalog.bundled().defaultImageModel(for: .openai))
        guard case let .pixels(wide) = AspectFitter.fit(boxAspect: 5, model: model, quality: .standard),
              case let .pixels(tall) = AspectFitter.fit(boxAspect: 0.2, model: model, quality: .standard) else {
            Issue.record("expected pixels")
            return
        }
        #expect(wide.aspect <= 3.05 && wide.aspect > 2.9)
        #expect(tall.aspect >= 0.32 && tall.aspect < 0.37)
    }

    @Test func degenerateAspectDoesNotCrash() throws {
        let model = try #require(try ModelCatalog.bundled().defaultImageModel(for: .openai))
        for aspect in [0, -1, .nan, .infinity] as [Double] {
            guard case let .pixels(size) = AspectFitter.fit(boxAspect: aspect, model: model, quality: .draft) else {
                Issue.record("expected pixels")
                continue
            }
            #expect(size.pixelCount >= 655_360)
        }
    }

    @Test func fixedRatioPicksNearest() {
        let ratios = ["1:1", "2:3", "3:2", "16:9"]
        #expect(AspectFitter.nearestRatio(boxAspect: 1.0, ratios: ratios) == "1:1")
        #expect(AspectFitter.nearestRatio(boxAspect: 0.7, ratios: ratios) == "2:3")
        #expect(AspectFitter.nearestRatio(boxAspect: 1.6, ratios: ratios) == "3:2")
        #expect(AspectFitter.nearestRatio(boxAspect: 2.5, ratios: ratios) == "16:9")
        #expect(AspectFitter.nearestRatio(boxAspect: 0.1, ratios: ratios) == "2:3")
        #expect(AspectFitter.nearestRatio(boxAspect: 1, ratios: []) == nil)
    }
}
