import BBAI
import BBModel
import Foundation
import Testing
@testable import BBUI

@MainActor
struct OnboardingTests {
    private func suite() -> UserDefaults {
        let name = "onboarding-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Typical costs

    @Test func typicalCostsMatchPriceListTimesCounts() throws {
        let list = try PriceList.bundled()
        let model = try #require(try ModelCatalog.bundled().defaultImageModel(for: .openai))
        let costs = TypicalCosts(model: model, priceList: list)
        let entry = try #require(list.entry(provider: model.provider, model: model.pricingModelID))
        let est = try #require(entry.estimation)
        let rates = entry.perMillionTokens
        let textTokens = Int((Double(TypicalCosts.promptCharacters) * (est.textTokensPerPromptChar ?? 0.27)).rounded(.up))

        func expected(_ quality: QualityLevel) throws -> Decimal {
            let param = try #require(model.image.quality[quality]?.param)
            let out = try #require(est.outputImageTokens?["\(param)@1024x1024"])
            return ((rates["textIn"] ?? 0) * Decimal(textTokens) + (rates["imageOut"] ?? 0) * Decimal(out)) / 1_000_000
        }
        #expect(costs.draftPerImage == (try expected(.draft)))
        #expect(costs.standardPerImage == (try expected(.standard)))
        #expect(costs.bookAtStandard == (try expected(.standard)) * 12)
        #expect(costs.priceListAsOf == list.asOf)
    }

    @Test func typicalCostsFollowAUserPriceList() throws {
        var list = try PriceList.bundled()
        let model = try #require(try ModelCatalog.bundled().defaultImageModel(for: .openai))
        let base = TypicalCosts(model: model, priceList: list)
        for i in list.entries.indices {
            list.entries[i].perMillionTokens = list.entries[i].perMillionTokens.mapValues { $0 * 2 }
        }
        let doubled = TypicalCosts(model: model, priceList: list)
        #expect(doubled.standardPerImage == base.standardPerImage.map { $0 * 2 })
    }

    @Test func unknownWhenNoPriceEntry() throws {
        let model = try #require(try ModelCatalog.bundled().defaultImageModel(for: .openai))
        let costs = TypicalCosts(model: model, priceList: PriceList(asOf: "", entries: []))
        #expect(costs.standardPerImage == nil)
        #expect(costs.bookAtStandard == nil)
    }

    // MARK: First-run decision

    @Test func showsWhenFlagUnsetAndNoKey() {
        let state = OnboardingState(defaults: suite())
        #expect(state.shouldShowOnLaunch(hasKey: false, underTests: false))
    }

    @Test func notShownWhenFlagSet() {
        let state = OnboardingState(defaults: suite())
        state.markCompleted()
        #expect(!state.shouldShowOnLaunch(hasKey: false, underTests: false))
    }

    @Test func notShownWhenKeyPresentOrUnderTests() {
        let state = OnboardingState(defaults: suite())
        #expect(!state.shouldShowOnLaunch(hasKey: true, underTests: false))
        #expect(!state.shouldShowOnLaunch(hasKey: false, underTests: true))
        #expect(OnboardingState.runningUnderTests)
    }

    // MARK: Flag

    @Test func finishingAndSkippingSetTheFlag() {
        let a = OnboardingState(defaults: suite())
        OnboardingModel(state: a).finish()
        #expect(a.isCompleted)
        let b = OnboardingState(defaults: suite())
        OnboardingModel(state: b).skipSetup()
        #expect(b.isCompleted)
    }

    @Test func stepsAdvanceAndSkipping() {
        let state = OnboardingState(defaults: suite())
        let model = OnboardingModel(state: state)
        #expect(model.isFirst)
        for _ in 1..<OnboardingModel.Step.allCases.count { model.skipStep() }
        #expect(model.isLast)
        #expect(!state.isCompleted)
        model.back()
        #expect(model.step == .costs)
    }
}
