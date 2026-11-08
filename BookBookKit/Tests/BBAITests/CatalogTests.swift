import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct CatalogTests {
    @Test func bundledCatalogLoads() throws {
        let catalog = try ModelCatalog.bundled()
        #expect(catalog.asOf == "2026-11-07")
        #expect(!catalog.imageModels.isEmpty)
        #expect(catalog.imageModels.allSatisfy { $0.provider == .openai })
    }

    @Test func everyOpenAIImageEntryResolvesCapabilities() throws {
        let catalog = try ModelCatalog.bundled()
        let ids = Set(catalog.imageModels.map(\.id))
        #expect(ids == ["gpt-image-2.5-sunburst", "gpt-image-2.6-sunburst", "gpt-image-2.6-flare",
                        "gpt-image-2.5-flare", "gpt-image-2"])
        for model in catalog.imageModels {
            guard case let .free(minRatio, maxRatio, multiple, minPixels, maxPixels, experimental) = model.image.aspect else {
                Issue.record("\(model.id) should be free-size")
                continue
            }
            #expect(minRatio < 0.34 && maxRatio == 3.0 && multiple == 16)
            #expect(minPixels == 655_360 && maxPixels == 8_294_400 && experimental == 3_686_400)
            #expect(Set(model.image.quality.keys) == Set(QualityLevel.allCases))
            #expect(model.image.quality[.draft]?.param == "low")
            #expect(model.image.quality[.high]?.targetPixels == 3_686_400)
            #expect(model.image.supportsMask)
            #expect(model.image.maxReferenceImages == 16)
            #expect(model.typicalDurationSeconds[.high] == 29)
        }
        #expect(catalog.imageModel(provider: .openai, id: "gpt-image-2")?.successor == "gpt-image-2.5-sunburst")
    }

    @Test func defaultModel() throws {
        let catalog = try ModelCatalog.bundled()
        #expect(catalog.defaultImageModel(for: .openai)?.id == "gpt-image-2.5-sunburst")
        #expect(catalog.defaultImageModel(for: .gemini) == nil)
    }

    @Test func fixedAspectAndBadSourceDecode() throws {
        let fixed = """
        {"asOf":"x","models":[{"provider":"gemini","id":"g","displayName":"G","kind":"image","status":"current",
        "typicalDurationSeconds":{"draft":3},"image":{"maxReferenceImages":4,"maxImageBytes":1,"maxRequestBytes":2,
        "supportsMask":false,"nativeMultiTurn":true,"aspect":{"mode":"fixed","ratios":["1:1","2:3"]},
        "quality":{"draft":{"imageSize":"1K"}}}}]}
        """
        let catalog = try ModelCatalog(data: Data(fixed.utf8))
        #expect(catalog.imageModels[0].image.aspect == .fixed(ratios: ["1:1", "2:3"]))
        #expect(catalog.imageModels[0].image.quality[.draft]?.imageSize == "1K")
        let broken = """
        {"asOf":"x","models":[{"provider":"openai","id":"a","displayName":"A","kind":"image",
        "image":{"copyCapabilitiesFrom":"nope"}}]}
        """
        #expect(throws: ModelCatalog.CatalogError.self) { try ModelCatalog(data: Data(broken.utf8)) }
    }
}
