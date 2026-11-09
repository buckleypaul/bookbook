import BBAICore
import BBModel
import Foundation

/// Plain-language failure advice (A §7.11). An ordered rules table decides; provider wording is
/// never parsed. The raw response appears only in `details`.
public enum RefusalAdvisor {
    public static func advise(_ error: ProviderError, context: AdviceContext,
                              terms: SensitiveTerms = .bundled) -> FailureAdvice {
        let facts = Facts(error: error, context: context, terms: terms)
        var advice = rules.lazy.compactMap { $0(facts) }.first ?? fallback(facts)
        advice.details = details(for: error)
        return advice
    }

    // MARK: Facts

    struct Facts {
        let error: ProviderError
        let context: AdviceContext
        let provider: String
        let promptTerms: [String]
        let storyTerms: [String]

        init(error: ProviderError, context: AdviceContext, terms: SensitiveTerms) {
            self.error = error
            self.context = context
            provider = RefusalAdvisor.displayName(context.provider)
            let story = context.report?.storyText ?? ""
            var prompt = context.report?.promptText ?? ""
            if !story.isEmpty { prompt = prompt.replacingOccurrences(of: story, with: " ") }
            promptTerms = terms.matches(in: prompt)
            storyTerms = story.isEmpty ? [] : terms.matches(in: story)
        }

        var refusalStage: RefusalStage? {
            if case .refused(let stage, _, _) = error { return stage }
            return nil
        }
    }

    static func displayName(_ id: ProviderID) -> String {
        switch id {
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        default: id.rawValue.prefix(1).uppercased() + id.rawValue.dropFirst()
        }
    }

    // MARK: Ordered rules (first match wins)

    typealias Rule = @Sendable (Facts) -> FailureAdvice?

    static let rules: [Rule] = [
        // 1. Refusal with a real-person photo attached.
        { f in
            guard f.refusalStage != nil, f.context.includesRealPersonPhoto else { return nil }
            return FailureAdvice(
                headline: "\(f.provider) declined this request",
                explanation: "Image models often refuse pictures that include a photo of a real person.",
                fixes: ["Describe the child in words instead of uploading a photo."], offersOtherProvider: true)
        },
        // 2. Refusal with a sensitive word in the prompt or the story text.
        { f in
            guard f.refusalStage != nil else { return nil }
            if let word = f.promptTerms.first {
                return FailureAdvice(
                    headline: "\(f.provider) declined this request",
                    explanation: "A safety filter may have reacted to a word in the request.",
                    fixes: ["Try removing the word '\(word)'."], offersOtherProvider: true)
            }
            if let word = f.storyTerms.first {
                return FailureAdvice(
                    headline: "\(f.provider) declined this request",
                    explanation: "A safety filter may have reacted to a word in the story text sent with it.",
                    fixes: ["Try removing the word '\(word)'.", "Or turn off 'include story text' for this request."],
                    offersOtherProvider: true)
            }
            return nil
        },
        // 3. The model's own picture was blocked.
        { f in
            guard f.refusalStage == .output else { return nil }
            return FailureAdvice(
                headline: "\(f.provider) blocked the picture it made",
                explanation: "The picture the model made was blocked.",
                fixes: ["Try rephrasing the scene."], offersOtherProvider: true)
        },
        // 4. Key, billing and verification problems.
        { f in
            let p = f.provider
            switch f.error {
            case .invalidKey:
                return FailureAdvice(
                    headline: "Your \(p) key was rejected",
                    explanation: "\(p) didn't accept the key BookBook sent.",
                    fixes: ["Check the key in Settings \u{2192} API Keys.", "Create a new key on the \(p) site and paste it in."],
                    link: link(f.context.provider, .keys))
            case .missingKey:
                return FailureAdvice(
                    headline: "No \(p) key is set up",
                    explanation: "BookBook needs a \(p) key before it can make pictures.",
                    fixes: ["Add your key in Settings \u{2192} API Keys.", "Create one on the \(p) site if you don't have one."],
                    link: link(f.context.provider, .keys))
            case .billing:
                return FailureAdvice(
                    headline: "\(p) says there's a billing problem",
                    explanation: "The account may be out of credit or have no payment method.",
                    fixes: ["Check your balance and payment method on the \(p) billing page.", "Add credit, then retry."],
                    link: link(f.context.provider, .billing))
            case .verificationRequired:
                return FailureAdvice(
                    headline: "\(p) needs to verify your organization",
                    explanation: "This model is only available to verified accounts.",
                    fixes: ["Complete verification on the \(p) organization settings page.", "Or choose another model in Settings."],
                    link: link(f.context.provider, .organization))
            default: return nil
            }
        },
        // 5. Generic refusal.
        { f in
            guard f.refusalStage != nil else { return nil }
            return FailureAdvice(
                headline: "\(f.provider) declined this request",
                explanation: "The model refused, and it doesn't always say why.",
                fixes: ["Try rephrasing the request in simpler words."], offersOtherProvider: true)
        },
    ]

    /// Plain advice for every remaining case.
    private static func fallback(_ f: Facts) -> FailureAdvice {
        let p = f.provider
        switch f.error {
        case .rateLimited(let retryAfter, _):
            let wait = retryAfter.map { " Try again in about \(Int($0.rounded(.up))) seconds." } ?? " Try again in a minute."
            return FailureAdvice(headline: "\(p) is busy", explanation: "You're sending requests faster than \(p) allows.\(wait)",
                                 fixes: ["Wait a moment, then retry."], offersOtherProvider: true)
        case .transient:
            return FailureAdvice(headline: "\(p) had a temporary problem", explanation: "This is usually brief and not caused by your request.",
                                 fixes: ["Try again in a moment."], offersOtherProvider: true)
        case .offline:
            return FailureAdvice(headline: "You're offline", explanation: "BookBook couldn't reach \(p). Nothing was sent.",
                                 fixes: ["Check your internet connection, then retry."], offersOtherProvider: true)
        case .timeout:
            return FailureAdvice(headline: "\(p) took too long", explanation: "The request timed out before a picture came back.",
                                 fixes: ["Try again.", "Try a lower quality level, which is usually faster."], offersOtherProvider: true)
        case .cancelled:
            return FailureAdvice(headline: "Cancelled", explanation: "You stopped this request before it finished.", offersOtherProvider: false)
        case .noImage where RegionEditFailure.isBlankArea(f.error):
            return FailureAdvice(headline: "The edit came back blank",
                                 explanation: "The model returned a blank area instead of an edit.",
                                 fixes: ["Try again.", "Or select a slightly larger area."], offersOtherProvider: false)
        case .noImage(let raw) where raw?.code == RegionEditFailure.compositeFailedCode:
            return FailureAdvice(headline: "The edit couldn't be blended in",
                                 explanation: "\(p) sent a picture, but BookBook couldn't blend it into the selected area.",
                                 fixes: ["Try again."], offersOtherProvider: false)
        case .noImage:
            return FailureAdvice(headline: "\(p) didn't return a picture", explanation: "The request went through, but no image came back.",
                                 fixes: ["Try again.", "Try rephrasing the scene."], offersOtherProvider: true)
        case .invalidRequest(let param, _):
            let which = param.map { " It points at '\($0)'." } ?? ""
            return FailureAdvice(headline: "\(p) couldn't use this request", explanation: "\(p) rejected the request's settings.\(which)",
                                 fixes: ["Try a different size, quality or number of references.", "If it keeps happening, choose another model in Settings."],
                                 offersOtherProvider: true)
        case .modelUnavailable:
            return FailureAdvice(headline: "That model isn't available", explanation: "\(p) says this model isn't available to your account.",
                                 fixes: ["Choose another model in Settings."], offersOtherProvider: true)
        case .regionUnsupported:
            return FailureAdvice(headline: "\(p) isn't available in your region", explanation: "\(p) doesn't offer this service where you are.",
                                 fixes: ["Try the other provider if you have a key for it."], offersOtherProvider: true)
        default:
            return FailureAdvice(headline: "Something went wrong", explanation: "\(p) returned an error BookBook doesn't recognize.",
                                 fixes: ["Try again.", "See Details for what \(p) said."], offersOtherProvider: true)
        }
    }

    // MARK: Links and details

    private enum Page { case keys, billing, organization }

    private static func link(_ provider: ProviderID, _ page: Page) -> URL? {
        let string: String? = switch (provider, page) {
        case (.openai, .keys): "https://platform.openai.com/api-keys"
        case (.openai, .billing): "https://platform.openai.com/settings/organization/billing/overview"
        case (.openai, .organization): "https://platform.openai.com/settings/organization/general"
        case (.gemini, .keys): "https://aistudio.google.com/apikey"
        case (.gemini, .billing): "https://aistudio.google.com/usage"
        case (.gemini, .organization): "https://aistudio.google.com/apikey"
        default: nil
        }
        return string.flatMap(URL.init(string:))
    }

    static func raw(of error: ProviderError) -> ProviderErrorRaw? {
        switch error {
        case .invalidKey(let r), .verificationRequired(let r), .regionUnsupported(let r), .billing(let r),
             .noImage(let r), .modelUnavailable(let r), .transient(let r), .unknown(let r):
            r
        case .rateLimited(_, let r), .refused(_, _, let r), .invalidRequest(_, let r): r
        case .missingKey, .offline, .timeout, .cancelled: nil
        }
    }

    private static func details(for error: ProviderError) -> String? {
        guard let raw = raw(of: error) else { return nil }
        var head: [String] = []
        if let status = raw.status { head.append("HTTP \(status)") }
        if let code = raw.code, !code.isEmpty { head.append(code) }
        var text = head.joined(separator: " \u{00B7} ")
        if !raw.body.isEmpty { text += (text.isEmpty ? "" : "\n") + raw.body }
        return text.isEmpty ? nil : text
    }
}
