import BBAICore
import BBModel
import BBNet
import Foundation

/// Maps an OpenAI error response to a `ProviderError` (architecture.md §7.11).
/// Switches on `error.code` and `param`, never `error.type` (newer 400s carry
/// `type: image_generation_user_error`, SP-5).
enum OpenAIErrorMapper {
    private static let maxRawBytes = 16_000

    static func map(_ response: HTTPResponse, key: APIKey) -> ProviderError {
        let error = ((try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any])?["error"] as? [String: Any]
        let code = error?["code"] as? String
        let param = error?["param"] as? String
        let message = (error?["message"] as? String)?.lowercased() ?? ""
        let raw = raw(response, code: code, key: key)

        switch response.status {
        case 401:
            return .invalidKey(raw)
        case 403:
            let haystack = (code ?? "").lowercased() + " " + message
            if haystack.contains("country") || haystack.contains("region") || haystack.contains("territory") {
                return .regionUnsupported(raw)
            }
            if haystack.contains("verif") || haystack.contains("organization") {
                return .verificationRequired(raw)
            }
            return .unknown(raw)
        case 404:
            return .modelUnavailable(raw)
        case 429:
            if let code, isBillingCode(code) { return .billing(raw) }
            return .rateLimited(retryAfter: retryAfter(response), raw)
        case 400:
            switch code {
            case "moderation_blocked":
                let details = error?["moderation_details"] as? [String: Any]
                let stage: RefusalStage = switch details?["moderation_stage"] as? String {
                case "input": .input
                case "output": .output
                default: .unknown
                }
                let categories = (details?["categories"] as? [Any])?.compactMap { $0 as? String } ?? []
                return .refused(stage: stage, categories: categories, raw)
            case "image_content_policy_violation":
                return .refused(stage: .unknown, categories: [], raw)
            case "invalid_value" where param == "model", "model_not_found":
                return .modelUnavailable(raw)
            default:
                return .invalidRequest(param: param, raw)
            }
        case 500, 502, 503, 504:
            return .transient(raw)
        default:
            return code == "server_is_overloaded" ? .transient(raw) : .unknown(raw)
        }
    }

    /// The status, code and body, with masked-key echoes redacted. If the body somehow contains
    /// the key itself, the body is withheld entirely.
    static func raw(_ response: HTTPResponse, code: String?, key: APIKey) -> ProviderErrorRaw {
        guard !key.occurs(in: response.body) else {
            return ProviderErrorRaw(status: response.status, code: code, body: "<body withheld: it contained credentials>")
        }
        let text = String(decoding: response.body.prefix(maxRawBytes), as: UTF8.self)
        return ProviderErrorRaw(status: response.status, code: code, body: Redaction.redactMaskedKeys(text))
    }

    private static func isBillingCode(_ code: String) -> Bool {
        code == "insufficient_quota" || code == "credit_balance_exhausted" || code == "billing_hard_limit_reached"
            || code.hasSuffix("spend_limit_exceeded")
    }

    private static func retryAfter(_ response: HTTPResponse) -> Double? {
        response.headers["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}
