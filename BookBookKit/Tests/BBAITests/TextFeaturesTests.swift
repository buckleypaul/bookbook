import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

private func diff(_ asset: String?, _ aspect: String, _ observed: String = "x", _ expected: String,
                  _ severity: ConsistencySeverity) -> ConsistencyDifference {
    ConsistencyDifference(asset: asset, aspect: aspect, observed: observed, expected: expected, severity: severity)
}

@Suite struct ConsistencyThresholdTests {
    @Test func oneMajorWarns() {
        #expect(ConsistencyThresholds.standard.warns([diff("Pip", "scarf", "blue", "red", .major)]))
    }

    @Test func threeMinorWarn() {
        let minors = (0..<3).map { diff(nil, "a\($0)", "x", "y", .minor) }
        #expect(ConsistencyThresholds.standard.warns(minors))
    }

    @Test func twoMinorDoNotWarn() {
        #expect(!ConsistencyThresholds.standard.warns((0..<2).map { diff(nil, "a\($0)", "x", "y", .minor) }))
        #expect(!ConsistencyThresholds.standard.warns([]))
    }

    @Test func customThresholds() {
        let strict = ConsistencyThresholds(warnOnMajor: 2, warnOnMinor: 1)
        #expect(strict.warns([diff(nil, "a", "x", "y", .minor)]))
        #expect(!strict.warns([diff(nil, "a", "x", "y", .major)]))
    }
}

@Suite struct CorrectionMessageTests {
    @Test func emptyIsEmpty() {
        #expect(ConsistencyPrompt.correctionMessage([]) == "")
    }

    @Test func singleClause() {
        let message = ConsistencyPrompt.correctionMessage([diff("Pip", "scarf", "blue", "red", .major)])
        #expect(message == "Keep everything the same, but: make Pip's scarf red as in the reference")
    }

    @Test func majorFirstThenMinorKeepingOrder() {
        let message = ConsistencyPrompt.correctionMessage([
            diff("Pip", "ears", "short", "long", .minor),
            diff("Pip", "scarf", "blue", "red", .major),
            diff("Castle", "towers", "two", "three", .minor),
            diff(nil, "palette", "bright", "muted", .major),
        ])
        #expect(message == "Keep everything the same, but: make Pip's scarf red as in the reference; "
            + "make the palette muted as in the reference; make Pip's ears long as in the reference; "
            + "make Castle's towers three as in the reference")
    }

    @Test func possessiveAfterS() {
        let message = ConsistencyPrompt.correctionMessage([diff("Chris", "hat", "green", "blue", .major)])
        #expect(message.contains("Chris' hat blue"))
    }

    @Test func blankDifferencesAreSkipped() {
        #expect(ConsistencyPrompt.correctionMessage([diff(nil, " ", "x", " ", .major)]) == "")
    }
}

@Suite struct ConsistencyInstructionsTests {
    @Test func mentionsAssetsStyleAndImages() {
        let (system, user) = ConsistencyPrompt.instructions(
            assets: [ConsistencyAssetContext(name: "Pip", description: "a fox with a red scarf")],
            styleDescription: "soft watercolour", imageLabels: ["page", "Pip", "style 1"])
        #expect(!system.isEmpty)
        #expect(system.contains("major") && system.contains("minor"))
        #expect(user.contains("Image 1 (page)"))
        #expect(user.contains("Image 2: Pip") && user.contains("Image 3: style 1"))
        #expect(user.contains("- Pip: a fox with a red scarf"))
        #expect(user.contains("soft watercolour"))
        #expect(!user.contains("{{"))
    }

    @Test func handlesNoAssetsAndNoStyle() {
        let (_, user) = ConsistencyPrompt.instructions(assets: [], styleDescription: " ", imageLabels: ["page"])
        #expect(user.contains("(none)") && user.contains("No references"))
        #expect(!user.contains("{{"))
    }
}

@Suite struct LayoutPromptTests {
    static let model = CatalogTextModel(provider: .openai, id: "gpt-6-luna", displayName: "Luna", kind: .text)
    static let setup = PageSetup(trimSize: PointSize(width: 576, height: 720), orientation: .portrait,
                                 margins: EdgeInsetsPt(top: 36, leading: 54, bottom: 36, trailing: 54), bleedEnabled: true)

    static func preset(_ name: String, kind: TemplateKind = .single, role: PageRole? = nil) -> Template {
        Template(name: name, kind: kind, boxes: [
            Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.6), bleedEdges: [.top, .leading, .trailing], content: .image),
            Box(frame: NormalizedRect(x: 0.1, y: 0.7, width: 0.8, height: 0.2), content: .text(TextBoxStyle())),
        ], pageRole: role)
    }

    @Test func requestIncludesSetupDescriptionAndTwoMatchingExamples() {
        let presets = [Self.preset("Title", role: .titlePage), Self.preset("Spread A", kind: .spread),
                       Self.preset("Plain A"), Self.preset("Plain B"), Self.preset("Plain C")]
        let request = LayoutPrompt.request(description: "big picture on top", kind: .single, pageSetup: Self.setup,
                                           presets: presets, model: Self.model)
        #expect(request.model == Self.model)
        #expect(request.system.contains("top-left"))
        #expect(request.user.contains("big picture on top"))
        #expect(request.user.contains("576 x 720 pt (8 x 10 in)"))
        #expect(request.user.contains("portrait"))
        #expect(request.user.contains("single page"))
        #expect(request.user.contains("top 36 pt, leading 54 pt"))
        #expect(request.user.contains("Bleed: on"))
        #expect(request.user.contains("Plain A") && request.user.contains("Plain B"))
        #expect(!request.user.contains("Plain C") && !request.user.contains("Spread A") && !request.user.contains("Title"))
        #expect(request.user.contains("\"textAlignment\" : null"))
        #expect(!request.user.contains("{{"))
    }

    @Test func spreadRequestUsesSpreadExamples() {
        let request = LayoutPrompt.request(description: "d", kind: .spread, pageSetup: Self.setup,
                                           presets: [Self.preset("Single"), Self.preset("Wide", kind: .spread)], model: Self.model)
        #expect(request.user.contains("Wide") && !request.user.contains("Single"))
        #expect(request.user.contains("spread"))
        #expect(request.user.contains("1152 x 720"))
    }

    @Test func fallsBackToRoleTemplatesWhenNoPlainOnes() {
        let request = LayoutPrompt.request(description: "d", kind: .single, pageSetup: Self.setup,
                                           presets: [Self.preset("Dedication", role: .dedication)], model: Self.model)
        #expect(request.user.contains("Dedication"))
    }

    @Test func bleedOffAndNoPresets() {
        var setup = Self.setup
        setup.bleedEnabled = false
        let request = LayoutPrompt.request(description: "d", kind: .single, pageSetup: setup, presets: [], model: Self.model)
        #expect(request.user.contains("Bleed: off"))
        #expect(!request.user.contains("Example 1"))
    }
}

@Suite struct LayoutRevisionPromptTests {
    @Test func revisionIncludesCurrentLayoutHistoryInstructionAndSetup() {
        var current = LayoutPromptTests.preset("Mine")
        current.boxes[1].content = .text(TextBoxStyle(background: RGBA(red: 1, green: 0.97, blue: 0.9, alpha: 1), alignment: .center))
        let request = LayoutPrompt.revisionRequest(instruction: "  make the picture full-bleed ",
                                                   history: ["big picture on top", " "], current: current,
                                                   pageSetup: LayoutPromptTests.setup, model: LayoutPromptTests.model)
        #expect(request.model == LayoutPromptTests.model)
        #expect(request.system == LayoutPrompt.request(description: "d", kind: .single, pageSetup: LayoutPromptTests.setup,
                                                       presets: [], model: LayoutPromptTests.model).system)
        #expect(request.user.contains("Request:\nmake the picture full-bleed"))
        #expect(request.user.contains("- big picture on top"))
        #expect(!request.user.contains("- \n"))
        #expect(request.user.contains("\"name\" : \"Mine\""))
        #expect(request.user.contains("\"textAlignment\" : \"center\""))
        #expect(request.user.contains("576 x 720 pt (8 x 10 in)"))
        #expect(request.user.contains("single page"))
        #expect(!request.user.contains("{{"))
    }

    @Test func noHistoryAndSpread() {
        let current = LayoutPromptTests.preset("Wide", kind: .spread)
        let request = LayoutPrompt.revisionRequest(instruction: "x", history: [], current: current,
                                                   pageSetup: LayoutPromptTests.setup, model: LayoutPromptTests.model)
        #expect(request.user.contains("oldest first:\n(none)"))
        #expect(request.user.contains("spread") && request.user.contains("1152 x 720"))
    }
}

@Suite struct TextEstimateTests {
    static func list(luna: PriceEntry.Estimation? = nil) throws -> PriceList { try PriceList.bundled() }
    static let luna = CatalogTextModel(provider: .openai, id: "gpt-6-luna", displayName: "Luna", kind: .text)
    static let terra = CatalogTextModel(provider: .openai, id: "gpt-6.1-terra", displayName: "Terra", kind: .vision)

    @Test func layoutUsesTypicalTokensWhenNoPerCharRate() throws {
        let request = LayoutRequest(model: Self.luna, system: "s", user: "u")
        let estimate = CostEstimator.estimate(layout: request, priceList: try PriceList.bundled())
        // 230 in at $0.10/M + 260 out at $0.50/M.
        #expect(estimate.amount == Decimal(string: "0.000153"))
        #expect(!estimate.extrapolated)
        #expect(estimate.priceListAsOf != nil)
    }

    @Test func layoutScalesWithPromptLengthWhenPerCharRateKnown() throws {
        var list = try PriceList.bundled()
        let index = try #require(list.entries.firstIndex { $0.model == "gpt-6-luna" })
        list.entries[index].estimation?.textTokensPerPromptChar = 0.5
        let request = LayoutRequest(model: Self.luna, system: String(repeating: "a", count: 1000),
                                    user: String(repeating: "b", count: 1000))
        // 2000 chars * 0.5 = 1000 in tokens: 1000 * 0.1 + 260 * 0.5 = 230 -> $0.00023.
        #expect(CostEstimator.estimate(layout: request, priceList: list).amount == Decimal(string: "0.00023"))
    }

    @Test func consistencyWithTypicalTwoImages() throws {
        let estimate = CostEstimator.estimateConsistency(model: Self.terra, imageCount: 2, priceList: try PriceList.bundled())
        // 310 in at $1/M + 75 out at $5/M.
        #expect(estimate.amount == Decimal(string: "0.000685"))
        #expect(!estimate.extrapolated)
    }

    @Test func consistencyScalesInputWithImageCount() throws {
        let estimate = CostEstimator.estimateConsistency(model: Self.terra, imageCount: 4, priceList: try PriceList.bundled())
        // 620 in + 75 out: 620 + 375 = 995.
        #expect(estimate.amount == Decimal(string: "0.000995"))
        #expect(estimate.extrapolated)
    }

    @Test func unknownModelIsUnknown() throws {
        let list = try PriceList.bundled()
        let other = CatalogTextModel(provider: .openai, id: "nope", displayName: "?", kind: .vision)
        #expect(CostEstimator.estimateConsistency(model: other, imageCount: 2, priceList: list) == .unknown)
        #expect(CostEstimator.estimate(layout: LayoutRequest(model: other, system: "", user: ""), priceList: list) == .unknown)
        // Known model but the wrong kind of estimate data.
        #expect(CostEstimator.estimateConsistency(model: Self.luna, imageCount: 2, priceList: list) == .unknown)
    }
}

@Suite struct TextCatalogTests {
    @Test func bundledCatalogDecodesTextAndVision() throws {
        let catalog = try ModelCatalog.bundled()
        #expect(!catalog.imageModels.isEmpty)
        #expect(catalog.imageModels.allSatisfy { $0.provider == .openai })

        let luna = try #require(catalog.textModel(provider: .openai, id: "gpt-6-luna"))
        #expect(luna.kind == .text && luna.typicalDurationSeconds == 5)
        #expect(luna.imageDetail == nil && luna.consistency == nil)

        let terra = try #require(catalog.textModel(provider: .openai, id: "gpt-6.1-terra"))
        #expect(terra.kind == .vision && terra.typicalDurationSeconds == 2)
        #expect(terra.imageDetail == "low")
        #expect(terra.consistency == ConsistencyThresholds(warnOnMajor: 1, warnOnMinor: 3))

        #expect(catalog.textModels(kind: .text).map(\.id) == ["gpt-6-luna"])
        #expect(catalog.textModels(kind: .vision).map(\.id) == ["gpt-6.1-terra"])
    }

    @Test func customThresholdsAndMissingFieldsDecode() throws {
        let json = """
        {"asOf":"x","models":[{"provider":"openai","id":"v","displayName":"V","kind":"vision",
        "vision":{"detail":"low"},"consistency":{"warnOnMajor":2,"warnOnMinor":5}},
        {"provider":"openai","id":"t","displayName":"T","kind":"text","status":"deprecated"},
        {"provider":"openai","id":"other","displayName":"O","kind":"something-else"}]}
        """
        let catalog = try ModelCatalog(data: Data(json.utf8))
        #expect(catalog.imageModels.isEmpty)
        #expect(catalog.textModels.count == 2)
        #expect(catalog.textModel(provider: .openai, id: "v")?.consistency == ConsistencyThresholds(warnOnMajor: 2, warnOnMinor: 5))
        #expect(catalog.textModel(provider: .openai, id: "t")?.typicalDurationSeconds == nil)
    }
}
