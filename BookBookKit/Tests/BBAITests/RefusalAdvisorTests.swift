import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct RefusalAdvisorTests {
    let raw = ProviderErrorRaw(status: 400, code: "moderation_blocked", body: "{\"error\":\"nope\"}")

    func ctx(prompt: String = "A calm scene.", story: String? = nil, photo: Bool = false,
             provider: ProviderID = .openai) -> AdviceContext {
        AdviceContext(provider: provider,
                      report: AssemblyReport(promptText: prompt + (story.map { " " + $0 } ?? ""), storyTextIncluded: story != nil,
                                             styleRevision: 1, storyText: story),
                      includesRealPersonPhoto: photo)
    }

    func refused(_ stage: RefusalStage = .input) -> ProviderError { .refused(stage: stage, categories: [], raw) }

    @Test func photoBeatsTermBeatsOutputBeatsGeneric() {
        let a = RefusalAdvisor.advise(refused(.output), context: ctx(prompt: "A bath scene.", photo: true))
        #expect(a.fixes == ["Describe the child in words instead of uploading a photo."])
        let b = RefusalAdvisor.advise(refused(.output), context: ctx(prompt: "A bath scene."))
        #expect(b.fixes == ["Try removing the word 'bath'."])
        let c = RefusalAdvisor.advise(refused(.output), context: ctx())
        #expect(c.fixes == ["Try rephrasing the scene."] && c.headline.contains("blocked"))
        let d = RefusalAdvisor.advise(refused(.input), context: ctx())
        #expect(d.fixes.count == 1 && d.fixes[0].contains("rephrasing"))
        #expect(RefusalAdvisor.advise(refused(.unknown), context: ctx()).offersOtherProvider)
    }

    @Test func termOnlyInStoryOffersTurningStoryOff() {
        let a = RefusalAdvisor.advise(refused(), context: ctx(story: "Mia loves her bath."))
        #expect(a.fixes == ["Try removing the word 'bath'.", "Or turn off 'include story text' for this request."])
        let b = RefusalAdvisor.advise(refused(), context: ctx(prompt: "Bath time.", story: "Mia loves her bath."))
        #expect(b.fixes == ["Try removing the word 'bath'."])
        let noReport = RefusalAdvisor.advise(refused(), context: AdviceContext(provider: .openai, report: nil))
        #expect(!noReport.fixes.isEmpty)
    }

    @Test func everyCaseHasAdvice() {
        let errors: [ProviderError] = [
            .invalidKey(raw), .missingKey, .verificationRequired(raw), .regionUnsupported(raw), .billing(raw),
            .rateLimited(retryAfter: 3, raw), .rateLimited(retryAfter: nil, nil), refused(), .noImage(nil),
            .invalidRequest(param: "size", raw), .invalidRequest(param: nil, nil), .modelUnavailable(raw),
            .transient(raw), .offline, .timeout, .cancelled, .unknown(raw), .unknown(nil),
        ]
        for error in errors {
            for provider in [ProviderID.openai, .gemini] {
                let a = RefusalAdvisor.advise(error, context: ctx(provider: provider))
                #expect(!a.headline.isEmpty && !a.explanation.isEmpty, "\(error)")
            }
        }
        #expect(RefusalAdvisor.advise(.modelUnavailable(nil), context: ctx()).fixes.contains("Choose another model in Settings."))
    }

    @Test func authAndBillingLinkAndDontOfferOtherProvider() {
        let key = RefusalAdvisor.advise(.invalidKey(raw), context: ctx())
        #expect(key.headline == "Your OpenAI key was rejected")
        #expect(key.fixes.count == 2 && key.fixes[0].contains("Settings \u{2192} API Keys"))
        #expect(key.link?.host == "platform.openai.com" && key.link?.path == "/api-keys")
        for error in [ProviderError.invalidKey(nil), .missingKey, .billing(nil), .verificationRequired(nil)] {
            let a = RefusalAdvisor.advise(error, context: ctx())
            #expect(!a.offersOtherProvider && a.link != nil)
        }
        #expect(RefusalAdvisor.advise(.rateLimited(retryAfter: nil, nil), context: ctx()).offersOtherProvider)
        #expect(RefusalAdvisor.advise(.invalidKey(nil), context: ctx(provider: .gemini)).headline == "Your Gemini key was rejected")
    }

    @Test func detailsAreOnlyStatusCodeAndRawBody() {
        let a = RefusalAdvisor.advise(refused(), context: ctx())
        #expect(a.details == "HTTP 400 \u{00B7} moderation_blocked\n{\"error\":\"nope\"}")
        #expect(RefusalAdvisor.advise(.offline, context: ctx()).details == nil)
        let noBody = RefusalAdvisor.advise(.transient(ProviderErrorRaw(status: 503, code: nil, body: "")), context: ctx())
        #expect(noBody.details == "HTTP 503")
    }

    @Test func termsMatchWholeWordsCaseInsensitively() {
        let terms = SensitiveTerms(entries: [.init(term: "bath", forms: ["bathing"]), .init(term: "gun", forms: ["Guns"])])
        #expect(terms.matches(in: "She was BATHING, then gun, then a bath.") == ["bath", "gun"])
        #expect(terms.matches(in: "Order: gun then Bath") == ["gun", "bath"])
        #expect(terms.matches(in: "The bathroom and a gunnel; bathe.").isEmpty)
        #expect(terms.matches(in: "toy guns!") == ["gun"])
        #expect(SensitiveTerms.bundled.matches(in: "a bloody nose") == ["blood"])
        #expect(!SensitiveTerms.bundled.entries.isEmpty)
    }
}
