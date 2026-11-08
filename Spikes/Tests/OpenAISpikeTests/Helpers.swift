// Shared helpers for the live OpenAI spikes (SP-1…SP-7). Key hygiene: nothing here touches the key
// except by handing it to SpikeKit (OpenAIClient / FixtureRecorder). Request headers and bodies are never printed.

import Foundation
import SpikeKit
import Testing

enum SpikeSetupError: Error, CustomStringConvertible {
    case missingKey
    case badJSON
    var description: String {
        switch self {
        case .missingKey: "no OpenAI key in the environment (run through scripts/live-tests.sh)"
        case .badJSON: "internal: could not build JSON"
        }
    }
}

/// The live suite. Extended across files, one per spike.
@Suite(.serialized, .enabled(if: LiveEnvironment.isEnabled(.openai)))
struct LiveProviderTests {}

enum SpikeModels {
    static var image: String { LiveEnvironment.string("SPIKE_IMAGE_MODEL", default: "gpt-image-2.5-sunburst") }
    static var template: String { LiveEnvironment.string("SPIKE_TEMPLATE_MODEL", default: "gpt-6-luna") }
    static var vision: String { LiveEnvironment.string("SPIKE_VISION_MODEL", default: "gpt-6.1-terra") }
}

/// Prints one observation line.
func result(_ spike: String, _ key: String, _ value: Any) {
    let text = redactMaskedKeys(String(describing: value)).replacingOccurrences(of: "\n", with: " ")
    print("SPIKE-RESULT \(spike) \(key): \(text)")
}

func milliseconds(_ d: Duration) -> Int {
    Int(d.components.seconds) * 1000 + Int(d.components.attoseconds / 1_000_000_000_000_000)
}

func isoNow() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: Date())
}

// MARK: - JSON helpers

func toSendable(_ v: Any) -> any Sendable {
    if let d = v as? [String: Any] { return d.mapValues(toSendable) }
    if let a = v as? [Any] { return a.map(toSendable) }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n }
    return NSNull()
}

/// Parses a JSON object literal into a Sendable dictionary usable with `postJSON`.
func jsonObject(_ text: String) throws -> [String: any Sendable] {
    let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
    guard let dict = toSendable(parsed) as? [String: any Sendable] else { throw SpikeSetupError.badJSON }
    return dict
}

func compactJSON(_ value: Any, limit: Int = 900) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let s = String(data: data, encoding: .utf8) else { return String(describing: value) }
    return s.count > limit ? String(s.prefix(limit)) + "…" : s
}

struct ErrorInfo {
    var type: String?
    var code: String?
    var message: String?
    var param: String?
    var raw: String
}

/// Extracts `error.type`, `error.code`, `error.message`, `error.param` from an error body.
func errorInfo(_ response: HTTPResponse) -> ErrorInfo {
    let rawText = String(data: response.body.prefix(1200), encoding: .utf8) ?? "<non-UTF8 \(response.body.count) bytes>"
    let err = response.json?["error"] as? [String: Any]
    func str(_ k: String) -> String? {
        guard let v = err?[k], !(v is NSNull) else { return nil }
        return String(describing: v)
    }
    return ErrorInfo(type: str("type"), code: str("code"), message: str("message"), param: str("param"), raw: rawText)
}

func printError(_ spike: String, _ tag: String, _ response: HTTPResponse) {
    let e = errorInfo(response)
    result(spike, "\(tag).error.type", e.type ?? "nil")
    result(spike, "\(tag).error.code", e.code ?? "nil")
    result(spike, "\(tag).error.param", e.param ?? "nil")
    result(spike, "\(tag).error.message", e.message ?? "nil")
    if let err = response.json?["error"] {
        result(spike, "\(tag).error.body", compactJSON(err))
    } else {
        result(spike, "\(tag).error.raw", e.raw)
    }
}

// MARK: - Images in responses

func b64Images(_ response: HTTPResponse) -> [Data] {
    guard let arr = response.json?["data"] as? [[String: Any]] else { return [] }
    return arr.compactMap { ($0["b64_json"] as? String).flatMap { Data(base64Encoded: $0) } }
}

func firstImage(_ response: HTTPResponse) -> RGBAImage? {
    b64Images(response).first.flatMap { TestImages.decode($0) }
}

// MARK: - Request context

enum Req: Sendable {
    case get(String)
    case json(String, [String: any Sendable])
    case multipart(String, MultipartForm)

    var isGet: Bool {
        if case .get = self { return true }
        return false
    }
}

struct LiveContext: Sendable {
    let client: OpenAIClient
    let recorder: FixtureRecorder
    let spike: String

    static func make(_ spike: String) throws -> LiveContext {
        guard let key = LiveEnvironment.apiKey(.openai) else { throw SpikeSetupError.missingKey }
        return LiveContext(client: OpenAIClient(key: key),
                           recorder: FixtureRecorder(provider: .openai, spike: spike, key: key),
                           spike: spike)
    }

    /// Performs one request: checks the budget, sends, prints status/latency/usage/error, records spend and
    /// the fixture. Returns nil on a transport error (already printed) so a spike can carry on.
    /// `estimateUSD` is recorded when the response has no usage; non-2xx responses are recorded as $0.
    @discardableResult
    func perform(_ req: Req, tag: String, model: String, estimateUSD: Double,
                 fixture: String? = nil, keepRealImage: Bool = false) async throws -> HTTPResponse? {
        try LiveSpendGuard.requireBudget()
        let response: HTTPResponse
        do {
            switch req {
            case .get(let path): response = try await client.get(path)
            case .json(let path, let body): response = try await client.postJSON(path, json: body)
            case .multipart(let path, let form): response = try await client.postMultipart(path, form: form)
            }
        } catch {
            result(spike, "\(tag).transport-error", "\(error)")
            LiveSpendGuard.record(spike: spike, provider: .openai, model: model, usage: nil, estimateUSD: 0)
            return nil
        }
        let ok = (200..<300).contains(response.status)
        result(spike, "\(tag).status", response.status)
        result(spike, "\(tag).latency-ms", milliseconds(response.duration))
        if let rid = response.headers["x-request-id"] { result(spike, "\(tag).request-id", rid) }
        var usage: Usage?
        if ok && !req.isGet {
            usage = Usage.openAI(from: response.body)
            if let u = usage {
                result(spike, "\(tag).usage", "in_text=\(u.inputTextTokens) in_image=\(u.inputImageTokens) cached=\(u.cachedInputTokens) out_text=\(u.outputTextTokens) out_image=\(u.outputImageTokens)")
                if let raw = response.json?["usage"] { result(spike, "\(tag).usage-raw", compactJSON(raw)) }
            } else {
                result(spike, "\(tag).usage", "absent")
            }
        }
        if !ok { printError(spike, tag, response) }
        let usd = LiveSpendGuard.record(spike: spike, provider: .openai, model: model, usage: usage,
                                        estimateUSD: ok && !req.isGet ? estimateUSD : 0)
        result(spike, "\(tag).spend-usd", String(format: "%.4f", usd))
        if ok, let img = firstImage(response) { result(spike, "\(tag).returned-size", "\(img.width)x\(img.height)") }
        if let fixture {
            do { try recorder.record(response, name: fixture, keepRealImage: keepRealImage) } catch {
                result(spike, "\(tag).fixture-error", "\(error)")
            }
        }
        return response
    }
}

// MARK: - Image generation helper

/// Output-image-token expectations from architecture.md §7.10 at 1024x1024, scaled by pixel count.
func expectedOutputImageTokens(quality: String, width: Int, height: Int) -> Int? {
    let base: [String: Double] = ["low": 200, "medium": 433, "high": 1767]
    guard let b = base[quality] else { return nil }
    return Int((b * Double(width * height) / (1024.0 * 1024.0)).rounded())
}

func estimateUSD(quality: String, width: Int, height: Int) -> Double {
    let perMP1024: [String: Double] = ["low": 0.006, "medium": 0.013, "high": 0.053]
    return (perMP1024[quality] ?? 0.013) * Double(width * height) / (1024.0 * 1024.0)
}

let genPrompt = "A simple flat picture-book illustration of a red kite flying over green rolling hills, soft pastel sky."

extension LiveContext {
    @discardableResult
    func generate(tag: String, size: String, quality: String, prompt: String = genPrompt,
                  model: String = SpikeModels.image, fixture: String? = nil,
                  keepRealImage: Bool = false, estimate: Double? = nil) async throws -> HTTPResponse? {
        let dims = size.split(separator: "x").compactMap { Int($0) }
        let (w, h) = dims.count == 2 ? (dims[0], dims[1]) : (1024, 1024)
        let body: [String: any Sendable] = [
            "model": model, "prompt": prompt, "size": size, "quality": quality, "n": 1, "output_format": "png",
        ]
        let response = try await perform(.json("/images/generations", body), tag: tag, model: model,
                                         estimateUSD: estimate ?? estimateUSD(quality: quality, width: w, height: h),
                                         fixture: fixture ?? tag, keepRealImage: keepRealImage)
        if let response, (200..<300).contains(response.status),
           let exp = expectedOutputImageTokens(quality: quality, width: w, height: h),
           let u = Usage.openAI(from: response.body) {
            result(spike, "\(tag).expected-vs-actual-output-image-tokens",
                   "expected=\(exp) (arch §7.10 table, scaled by pixels) actual=\(u.outputImageTokens)")
        }
        return response
    }
}

// MARK: - Edits helper

func editForm(model: String = SpikeModels.image, prompt: String, size: String, quality: String = "low",
              images: [(name: String, data: Data)], mask: Data? = nil) -> MultipartForm {
    var form = MultipartForm()
    form.addField(name: "model", value: model)
    form.addField(name: "prompt", value: prompt)
    form.addField(name: "quality", value: quality)
    form.addField(name: "output_format", value: "png")
    form.addField(name: "moderation", value: "auto")
    form.addField(name: "n", value: "1")
    form.addField(name: "size", value: size)
    for img in images { form.addFile(name: "image[]", filename: img.name, mimeType: "image/png", data: img.data) }
    if let mask { form.addFile(name: "mask", filename: "mask.png", mimeType: "image/png", data: mask) }
    return form
}
