// SpikeKit public contract (Phase 0). Frozen: work packages implement these bodies and may add
// internal helpers or new files, but must not change any public signature below.
// Key hygiene (implementation-plan.md §2.2): the API key lives only inside `APIKey`, goes only into
// the Authorization / x-goog-api-key header, and never into a description, error, log or file.

import Foundation

// MARK: - Environment

public enum Provider: String, Sendable, Codable, CaseIterable {
    case openai, gemini
}

/// An API key read from the process environment. Never printable: `description` is redacted.
public struct APIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String  // internal on purpose: only SpikeKit's HTTP clients and recorder touch it.
    init(value: String) { self.value = value }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    /// True when `data` contains the key's bytes anywhere (used by the fixture recorder).
    public func occurs(in data: Data) -> Bool {
        let needle = Data(value.utf8)
        guard !needle.isEmpty else { return false }
        return data.range(of: needle) != nil
    }
}

public enum LiveEnvironment {
    /// `BOOKBOOK_LIVE_TESTS == "1"`.
    public static var isLiveRun: Bool { ProcessInfo.processInfo.environment["BOOKBOOK_LIVE_TESTS"] == "1" }
    /// `BOOKBOOK_RECORD_FIXTURES == "1"` (set by scripts/record-fixtures.sh).
    public static var isRecording: Bool { ProcessInfo.processInfo.environment["BOOKBOOK_RECORD_FIXTURES"] == "1" }
    /// `OPENAI_API_KEY` / `GEMINI_API_KEY` from `ProcessInfo.environment`; nil if unset or empty.
    public static func apiKey(_ provider: Provider) -> APIKey? {
        let name = provider == .openai ? "OPENAI_API_KEY" : "GEMINI_API_KEY"
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : APIKey(value: trimmed)
    }
    /// Live run + key present + `LiveSpendGuard.isUnderBudget()`. Use as `.enabled(if:)` trait.
    public static func isEnabled(_ provider: Provider) -> Bool {
        isLiveRun && apiKey(provider) != nil && LiveSpendGuard.isUnderBudget()
    }
    /// Optional override from the environment (e.g. `SPIKE_IMAGE_MODEL`), else `fallback`.
    public static func string(_ name: String, default fallback: String) -> String {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return fallback }
        return v
    }
}

// MARK: - HTTP

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 300) {
        self.method = method; self.url = url; self.headers = headers; self.body = body; self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data
    public var duration: Duration
    public init(status: Int, headers: [String: String], body: Data, duration: Duration) {
        self.status = status; self.headers = headers; self.body = body; self.duration = duration
    }
    /// Body parsed as a JSON object, or nil.
    public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

/// Transport errors. Descriptions contain only the host and a URLError code; never headers or bodies.
public enum HTTPClientError: Error, Sendable, CustomStringConvertible {
    case transport(code: Int, host: String)
    case cancelled
    case timedOut(host: String)
    public var description: String {
        switch self {
        case .transport(let code, let host): "transport error (code \(code)) talking to \(host)"
        case .cancelled: "request cancelled"
        case .timedOut(let host): "request to \(host) timed out"
        }
    }
}

public protocol HTTPClient: Sendable {
    /// Honours Swift task cancellation (cancelling the calling Task cancels the URLSessionTask
    /// and throws `HTTPClientError.cancelled`).
    func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse
}

/// `URLSessionConfiguration.ephemeral`, `timeoutIntervalForRequest = 300`, `waitsForConnectivity = false`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse {
        let host = request.url.host() ?? "unknown-host"
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let clock = ContinuousClock()
        let start = clock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.map(error, host: host)
        }
        let elapsed = clock.now - start
        guard let http = response as? HTTPURLResponse else {
            throw .transport(code: URLError.badServerResponse.rawValue, host: host)
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data, duration: elapsed)
    }

    static func map(_ error: any Error, host: String) -> HTTPClientError {
        if error is CancellationError { return .cancelled }
        if let e = error as? URLError {
            switch e.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut(host: host)
            default: return .transport(code: e.code.rawValue, host: host)
            }
        }
        return .transport(code: (error as NSError).code, host: host)
    }
}

/// Returns a copy with `authorization` and `x-goog-api-key` (any case) replaced by "<redacted>".
public func redactedHeaders(_ headers: [String: String]) -> [String: String] {
    var out = headers
    for name in headers.keys where ["authorization", "x-goog-api-key"].contains(name.lowercased()) {
        out[name] = "<redacted>"
    }
    return out
}

public struct MultipartForm: Sendable {
    private let boundary: String
    private var parts = Data()

    public init(boundary: String = "bookbook-\(UUID().uuidString)") { self.boundary = boundary }

    private static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    public mutating func addField(name: String, value: String) {
        parts.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        parts.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(name))\"; filename=\"\(Self.quoted(filename))\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        parts.append(data)
        parts.append(Data("\r\n".utf8))
    }

    /// `contentType` is `multipart/form-data; boundary=…`.
    public func encoded() -> (contentType: String, body: Data) {
        var body = parts
        body.append(Data("--\(boundary)--\r\n".utf8))
        return ("multipart/form-data; boundary=\(boundary)", body)
    }
}

/// Thin OpenAI client. Sets `Authorization: Bearer <key>` itself; callers never see the key.
public struct OpenAIClient: Sendable {
    private let key: APIKey
    private let http: any HTTPClient
    private let baseURL: URL

    public init(key: APIKey, http: any HTTPClient = URLSessionHTTPClient(),
                baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.key = key; self.http = http; self.baseURL = baseURL
    }

    private func makeURL(_ path: String) throws(HTTPClientError) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + suffix) else {
            throw .transport(code: URLError.badURL.rawValue, host: baseURL.host() ?? "unknown-host")
        }
        return url
    }

    private func headers(contentType: String?) -> [String: String] {
        var h = ["Authorization": "Bearer \(key.value)"]
        if let contentType { h["Content-Type"] = contentType }
        return h
    }

    public func get(_ path: String) async throws(HTTPClientError) -> HTTPResponse {
        let url = try makeURL(path)
        return try await http.send(HTTPRequest(method: "GET", url: url, headers: headers(contentType: nil)))
    }

    /// `json` must be a JSONSerialization-compatible object.
    public func postJSON(_ path: String, json: [String: any Sendable]) async throws(HTTPClientError) -> HTTPResponse {
        let url = try makeURL(path)
        let object: [String: Any] = json
        guard JSONSerialization.isValidJSONObject(object),
              let body = try? JSONSerialization.data(withJSONObject: object) else {
            throw .transport(code: URLError.cannotParseResponse.rawValue, host: url.host() ?? "unknown-host")
        }
        return try await http.send(HTTPRequest(method: "POST", url: url,
                                               headers: headers(contentType: "application/json"), body: body))
    }

    public func postMultipart(_ path: String, form: MultipartForm) async throws(HTTPClientError) -> HTTPResponse {
        let url = try makeURL(path)
        let encoded = form.encoded()
        return try await http.send(HTTPRequest(method: "POST", url: url,
                                               headers: headers(contentType: encoded.contentType), body: encoded.body))
    }
}

// MARK: - Usage and spend

/// Token usage as reported by a provider. Missing fields are 0.
public struct Usage: Sendable, Codable, Equatable {
    public var inputTextTokens: Int
    public var inputImageTokens: Int
    public var cachedInputTokens: Int
    public var outputTextTokens: Int
    public var outputImageTokens: Int
    public init(inputTextTokens: Int = 0, inputImageTokens: Int = 0, cachedInputTokens: Int = 0,
                outputTextTokens: Int = 0, outputImageTokens: Int = 0) {
        self.inputTextTokens = inputTextTokens; self.inputImageTokens = inputImageTokens
        self.cachedInputTokens = cachedInputTokens; self.outputTextTokens = outputTextTokens
        self.outputImageTokens = outputImageTokens
    }
    /// Parses OpenAI `usage` from an Images API body (`input_tokens`, `output_tokens`,
    /// `input_tokens_details.{text_tokens,image_tokens,cached_tokens}`, `output_tokens_details.{text_tokens,image_tokens}`;
    /// when output details are absent, all `output_tokens` count as image tokens) or a Chat Completions body
    /// (`prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`). Nil if no `usage`.
    public static func openAI(from body: Data) -> Usage? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { return nil }
        func int(_ d: [String: Any]?, _ k: String) -> Int? { (d?[k] as? NSNumber)?.intValue }
        var u = Usage()
        if let input = int(usage, "input_tokens") ?? int(usage, "prompt_tokens") {
            let details = (usage["input_tokens_details"] ?? usage["prompt_tokens_details"]) as? [String: Any]
            let image = int(details, "image_tokens") ?? 0
            u.inputImageTokens = image
            u.inputTextTokens = int(details, "text_tokens") ?? max(input - image, 0)
            u.cachedInputTokens = int(details, "cached_tokens") ?? 0
        }
        if let imagesOutput = int(usage, "output_tokens") {
            let details = usage["output_tokens_details"] as? [String: Any]
            let text = int(details, "text_tokens") ?? 0
            u.outputTextTokens = text
            u.outputImageTokens = int(details, "image_tokens") ?? max(imagesOutput - text, 0)
        } else if let completion = int(usage, "completion_tokens") {
            u.outputTextTokens = completion
        }
        return u
    }
}

/// Seed per-million-token prices (USD) used only to estimate live spend in Phase 0.
/// Values from architecture.md §7.10; SP-2 checks them. Unknown models use the gpt-image-2.5-sunburst row
/// for image models and `gpt-6-luna`'s for text.
public struct SpikePrice: Sendable, Equatable {
    public var textIn: Double, imageIn: Double, cachedIn: Double, textOut: Double, imageOut: Double
    public init(textIn: Double, imageIn: Double, cachedIn: Double, textOut: Double, imageOut: Double) {
        self.textIn = textIn; self.imageIn = imageIn; self.cachedIn = cachedIn; self.textOut = textOut; self.imageOut = imageOut
    }
    public static func forModel(_ model: String) -> SpikePrice {
        let image = SpikePrice(textIn: 5, imageIn: 8, cachedIn: 2, textOut: 10, imageOut: 30)
        let luna = SpikePrice(textIn: 1.25, imageIn: 1.25, cachedIn: 0.125, textOut: 10, imageOut: 0)
        let terra = SpikePrice(textIn: 2.5, imageIn: 2.5, cachedIn: 0.25, textOut: 15, imageOut: 0)
        let m = model.lowercased()
        if m == "gpt-6-luna" { return luna }
        if m == "gpt-6.1-terra" { return terra }
        return m.contains("image") ? image : luna
    }
    /// Cached tokens are a subset of the input tokens: they are charged at `cachedIn` (attributed to text
    /// first) and the rest of the input at the normal rates.
    public func cost(of usage: Usage) -> Double {
        let cached = max(usage.cachedInputTokens, 0)
        let cachedText = min(cached, usage.inputTextTokens)
        let cachedImage = min(cached - cachedText, usage.inputImageTokens)
        let perMillion = Double(cachedText + cachedImage) * cachedIn
            + Double(usage.inputTextTokens - cachedText) * textIn
            + Double(usage.inputImageTokens - cachedImage) * imageIn
            + Double(usage.outputTextTokens) * textOut
            + Double(usage.outputImageTokens) * imageOut
        return perMillion / 1_000_000
    }
}

public enum LiveSpendError: Error, Sendable, CustomStringConvertible {
    case overBudget(spentUSD: Double, budgetUSD: Double)
    public var description: String {
        switch self {
        case .overBudget(let spent, let budget):
            "live spend budget reached: $\(String(format: "%.4f", spent)) of $\(String(format: "%.2f", budget))"
        }
    }
}

/// Append-only spend log at `~/Library/Caches/BookBook-dev/live-spend.jsonl` (override the directory with
/// `BOOKBOOK_SPEND_LOG_DIR`, used by offline tests). One JSON line per live call:
/// `{at, spike, provider, model, usd, basis: "usage"|"estimate"|"zero", usage?}`. Never any key or prompt text.
public enum LiveSpendGuard {
    /// `BOOKBOOK_LIVE_BUDGET`, default 10.
    public static var budgetUSD: Double {
        if let raw = ProcessInfo.processInfo.environment["BOOKBOOK_LIVE_BUDGET"],
           let v = Double(raw.trimmingCharacters(in: .whitespaces)), v.isFinite, v >= 0 { return v }
        return 10
    }
    /// Sum of `usd` over the log (0 if no log).
    public static func totalSpentUSD() -> Double { totalSpentUSD(logURL: defaultLogURL()) }
    public static func isUnderBudget() -> Bool { totalSpentUSD() < budgetUSD }
    /// Call before every live request. Throws once the total has reached the budget.
    public static func requireBudget() throws(LiveSpendError) {
        let spent = totalSpentUSD(), budget = budgetUSD
        if spent >= budget { throw .overBudget(spentUSD: spent, budgetUSD: budget) }
    }
    /// Records one call. If `usage` is present it is priced with `SpikePrice.forModel(model)` (basis "usage");
    /// otherwise `estimateUSD` is recorded (basis "estimate", or "zero" when it is 0, e.g. 4xx responses).
    /// Returns the USD recorded.
    @discardableResult
    public static func record(spike: String, provider: Provider, model: String, usage: Usage?,
                              estimateUSD: Double) -> Double {
        record(spike: spike, provider: provider, model: model, usage: usage, estimateUSD: estimateUSD,
               logURL: defaultLogURL())
    }
}

// MARK: - Fixtures

public enum FixtureRecorderError: Error, Sendable, CustomStringConvertible {
    case containsKey(file: String)
    case writeFailed(file: String)
    public var description: String {
        switch self {
        case .containsKey(let file): "refusing to write \(file): content contains an API key or secret-shaped string"
        case .writeFailed(let file): "could not write fixture \(file)"
        }
    }
}

/// Writes fixtures to `Spikes/Fixtures/<provider>/<spike>/` (root found from `#filePath`), only when
/// `LiveEnvironment.isRecording`; otherwise every call is a no-op.
/// For each `record` it writes `<name>.json` (the response body, transformed below) and
/// `<name>.meta.json` (`{status, durationMs, headers}` with only allow-listed response headers).
/// Transformations, in order: base64 images in `data[].b64_json` (OpenAI) and `inlineData.data` (Gemini) are
/// replaced with a 64 px placeholder PNG unless `keepRealImage`; `org-…` and `proj_…` IDs become
/// `org-PLACEHOLDER` / `proj_PLACEHOLDER`. Then, in memory, each file's bytes are checked with
/// `APIKey.occurs(in:)` and against the secret-scan patterns; if either matches nothing is written and it throws.
public struct FixtureRecorder: Sendable {
    /// content-type, retry-after, x-request-id, and every x-ratelimit-* header.
    public static func isAllowedHeader(_ lowercasedName: String) -> Bool {
        ["content-type", "retry-after", "x-request-id"].contains(lowercasedName)
            || lowercasedName.hasPrefix("x-ratelimit-")
    }

    let provider: Provider
    let spike: String
    let key: APIKey
    let root: URL
    let recording: Bool

    public init(provider: Provider, spike: String, key: APIKey, root: URL? = nil) {
        self.init(provider: provider, spike: spike, key: key, root: root, forceRecording: false)
    }

    /// Internal seam so offline tests can record into a temp directory.
    init(provider: Provider, spike: String, key: APIKey, root: URL?, forceRecording: Bool) {
        self.provider = provider; self.spike = spike; self.key = key
        self.root = root ?? Self.defaultRoot()
        self.recording = forceRecording || LiveEnvironment.isRecording
    }

    public func record(_ response: HTTPResponse, name: String, keepRealImage: Bool = false) throws(FixtureRecorderError) {
        guard recording else { return }
        try write(response, name: name, keepRealImage: keepRealImage)
    }
}

// MARK: - Test images

public struct RGB: Sendable, Equatable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    /// Euclidean distance in RGB space.
    public func distance(to other: RGB) -> Double {
        let dr = Double(r) - Double(other.r), dg = Double(g) - Double(other.g), db = Double(b) - Double(other.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

public enum Quadrant: String, Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Decoded 8-bit RGBA image, origin top-left.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]  // RGBA, row-major
    public init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }
    public func pixel(x: Int, y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(pixels[i], pixels[i + 1], pixels[i + 2])
    }
    public func alpha(x: Int, y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }

    /// Pixel bounds of a quadrant with `inset` (fraction of the quadrant's size) removed at its edges.
    private func bounds(of quadrant: Quadrant, inset: Double) -> (x: Range<Int>, y: Range<Int>) {
        let halfW = width / 2, halfH = height / 2
        let left = quadrant == .topLeft || quadrant == .bottomLeft
        let top = quadrant == .topLeft || quadrant == .topRight
        let x0 = left ? 0 : halfW, x1 = left ? halfW : width
        let y0 = top ? 0 : halfH, y1 = top ? halfH : height
        let clamped = min(max(inset, 0), 0.5)
        let ix = Int((Double(x1 - x0) * clamped).rounded()), iy = Int((Double(y1 - y0) * clamped).rounded())
        return ((x0 + ix)..<max(x0 + ix, x1 - ix), (y0 + iy)..<max(y0 + iy, y1 - iy))
    }

    /// Mean colour of a quadrant, ignoring a `inset` fraction (0…0.5) at the quadrant's edges.
    public func meanColor(of quadrant: Quadrant, inset: Double = 0.1) -> RGB {
        let b = bounds(of: quadrant, inset: inset)
        var r = 0.0, g = 0.0, bl = 0.0, n = 0.0
        for y in b.y {
            for x in b.x {
                let p = pixel(x: x, y: y)
                r += Double(p.r); g += Double(p.g); bl += Double(p.b); n += 1
            }
        }
        guard n > 0 else { return RGB(0, 0, 0) }
        return RGB(UInt8((r / n).rounded()), UInt8((g / n).rounded()), UInt8((bl / n).rounded()))
    }

    /// Fraction (0…1) of pixels in `quadrant` whose colour is within `tolerance` of `color`.
    public func fraction(of quadrant: Quadrant, near color: RGB, tolerance: Double) -> Double {
        let b = bounds(of: quadrant, inset: 0)
        var hits = 0, n = 0
        for y in b.y {
            for x in b.x {
                n += 1
                if pixel(x: x, y: y).distance(to: color) <= tolerance { hits += 1 }
            }
        }
        return n == 0 ? 0 : Double(hits) / Double(n)
    }
}

public enum TestImages {
    /// Opaque PNG: four solid quadrants in `colors` order (topLeft, topRight, bottomLeft, bottomRight).
    public static func quadrants(size: Int, colors: [RGB]) -> Data {
        precondition(colors.count == 4, "quadrants needs exactly four colours")
        return makePNG(width: size, height: size, hasAlpha: false) { x, y in
            let col = x < size / 2 ? 0 : 1, row = y < size / 2 ? 0 : 1
            let c = colors[row * 2 + col]
            return (c.r, c.g, c.b, 255)
        }
    }
    /// PNG with alpha: `transparent` quadrants have alpha 0, the rest alpha 255 (black).
    public static func mask(size: Int, transparent: Set<Quadrant>) -> Data {
        makePNG(width: size, height: size, hasAlpha: true) { x, y in
            let left = x < size / 2, top = y < size / 2
            let q: Quadrant = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
            return (0, 0, 0, transparent.contains(q) ? 0 : 255)
        }
    }
    /// Opaque PNG of one solid colour.
    public static func solid(width: Int, height: Int, color: RGB) -> Data {
        makePNG(width: width, height: height, hasAlpha: false) { _, _ in (color.r, color.g, color.b, 255) }
    }
    /// Opaque PNG of pseudo-random noise (incompressible), deterministic for a seed.
    public static func noise(width: Int, height: Int, seed: UInt64) -> Data {
        var rng = SplitMix64(state: seed)
        return makePNG(width: width, height: height, hasAlpha: false) { _, _ in
            let v = rng.next()
            return (UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), 255)
        }
    }
    /// The 64×64 placeholder PNG the fixture recorder substitutes for images.
    public static func placeholder() -> Data {
        quadrants(size: 64, colors: [RGB(200, 200, 200), RGB(150, 150, 150), RGB(100, 100, 100), RGB(50, 50, 50)])
    }
    /// Decodes PNG/JPEG/WebP bytes, or nil.
    public static func decode(_ data: Data) -> RGBAImage? { decodeImage(data) }
}
