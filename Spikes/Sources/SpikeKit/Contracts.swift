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
    public func occurs(in data: Data) -> Bool { fatalError("WP-A") }
}

public enum LiveEnvironment {
    /// `BOOKBOOK_LIVE_TESTS == "1"`.
    public static var isLiveRun: Bool { fatalError("WP-A") }
    /// `BOOKBOOK_RECORD_FIXTURES == "1"` (set by scripts/record-fixtures.sh).
    public static var isRecording: Bool { fatalError("WP-A") }
    /// `OPENAI_API_KEY` / `GEMINI_API_KEY` from `ProcessInfo.environment`; nil if unset or empty.
    public static func apiKey(_ provider: Provider) -> APIKey? { fatalError("WP-A") }
    /// Live run + key present + `LiveSpendGuard.isUnderBudget()`. Use as `.enabled(if:)` trait.
    public static func isEnabled(_ provider: Provider) -> Bool { fatalError("WP-A") }
    /// Optional override from the environment (e.g. `SPIKE_IMAGE_MODEL`), else `fallback`.
    public static func string(_ name: String, default fallback: String) -> String { fatalError("WP-A") }
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
    public var json: [String: Any]? { fatalError("WP-A") }
}

/// Transport errors. Descriptions contain only the host and a URLError code; never headers or bodies.
public enum HTTPClientError: Error, Sendable, CustomStringConvertible {
    case transport(code: Int, host: String)
    case cancelled
    case timedOut(host: String)
    public var description: String { fatalError("WP-A") }
}

public protocol HTTPClient: Sendable {
    /// Honours Swift task cancellation (cancelling the calling Task cancels the URLSessionTask
    /// and throws `HTTPClientError.cancelled`).
    func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse
}

/// `URLSessionConfiguration.ephemeral`, `timeoutIntervalForRequest = 300`, `waitsForConnectivity = false`.
public struct URLSessionHTTPClient: HTTPClient {
    public init() { fatalError("WP-A") }
    public func send(_ request: HTTPRequest) async throws(HTTPClientError) -> HTTPResponse { fatalError("WP-A") }
}

/// Returns a copy with `authorization` and `x-goog-api-key` (any case) replaced by "<redacted>".
public func redactedHeaders(_ headers: [String: String]) -> [String: String] { fatalError("WP-A") }

public struct MultipartForm: Sendable {
    public init(boundary: String = "bookbook-\(UUID().uuidString)") { fatalError("WP-A") }
    public mutating func addField(name: String, value: String) { fatalError("WP-A") }
    public mutating func addFile(name: String, filename: String, mimeType: String, data: Data) { fatalError("WP-A") }
    /// `contentType` is `multipart/form-data; boundary=…`.
    public func encoded() -> (contentType: String, body: Data) { fatalError("WP-A") }
}

/// Thin OpenAI client. Sets `Authorization: Bearer <key>` itself; callers never see the key.
public struct OpenAIClient: Sendable {
    public init(key: APIKey, http: any HTTPClient = URLSessionHTTPClient(),
                baseURL: URL = URL(string: "https://api.openai.com/v1")!) { fatalError("WP-A") }
    public func get(_ path: String) async throws(HTTPClientError) -> HTTPResponse { fatalError("WP-A") }
    /// `json` must be a JSONSerialization-compatible object.
    public func postJSON(_ path: String, json: [String: any Sendable]) async throws(HTTPClientError) -> HTTPResponse { fatalError("WP-A") }
    public func postMultipart(_ path: String, form: MultipartForm) async throws(HTTPClientError) -> HTTPResponse { fatalError("WP-A") }
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
    public static func openAI(from body: Data) -> Usage? { fatalError("WP-A") }
}

/// Seed per-million-token prices (USD) used only to estimate live spend in Phase 0.
/// Values from architecture.md §7.10; SP-2 checks them. Unknown models use the gpt-image-2.5-sunburst row
/// for image models and `gpt-6-luna`'s for text.
public struct SpikePrice: Sendable, Equatable {
    public var textIn: Double, imageIn: Double, cachedIn: Double, textOut: Double, imageOut: Double
    public init(textIn: Double, imageIn: Double, cachedIn: Double, textOut: Double, imageOut: Double) {
        self.textIn = textIn; self.imageIn = imageIn; self.cachedIn = cachedIn; self.textOut = textOut; self.imageOut = imageOut
    }
    public static func forModel(_ model: String) -> SpikePrice { fatalError("WP-A") }
    public func cost(of usage: Usage) -> Double { fatalError("WP-A") }
}

public enum LiveSpendError: Error, Sendable, CustomStringConvertible {
    case overBudget(spentUSD: Double, budgetUSD: Double)
    public var description: String { fatalError("WP-A") }
}

/// Append-only spend log at `~/Library/Caches/BookBook-dev/live-spend.jsonl` (override the directory with
/// `BOOKBOOK_SPEND_LOG_DIR`, used by offline tests). One JSON line per live call:
/// `{at, spike, provider, model, usd, basis: "usage"|"estimate"|"zero", usage?}`. Never any key or prompt text.
public enum LiveSpendGuard {
    /// `BOOKBOOK_LIVE_BUDGET`, default 10.
    public static var budgetUSD: Double { fatalError("WP-A") }
    /// Sum of `usd` over the log (0 if no log).
    public static func totalSpentUSD() -> Double { fatalError("WP-A") }
    public static func isUnderBudget() -> Bool { fatalError("WP-A") }
    /// Call before every live request. Throws once the total has reached the budget.
    public static func requireBudget() throws(LiveSpendError) { fatalError("WP-A") }
    /// Records one call. If `usage` is present it is priced with `SpikePrice.forModel(model)` (basis "usage");
    /// otherwise `estimateUSD` is recorded (basis "estimate", or "zero" when it is 0, e.g. 4xx responses).
    /// Returns the USD recorded.
    @discardableResult
    public static func record(spike: String, provider: Provider, model: String, usage: Usage?,
                              estimateUSD: Double) -> Double { fatalError("WP-A") }
}

// MARK: - Fixtures

public enum FixtureRecorderError: Error, Sendable, CustomStringConvertible {
    case containsKey(file: String)
    case writeFailed(file: String)
    public var description: String { fatalError("WP-A") }
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
    public static func isAllowedHeader(_ lowercasedName: String) -> Bool { fatalError("WP-A") }
    public init(provider: Provider, spike: String, key: APIKey, root: URL? = nil) { fatalError("WP-A") }
    public func record(_ response: HTTPResponse, name: String, keepRealImage: Bool = false) throws(FixtureRecorderError) { fatalError("WP-A") }
}

// MARK: - Test images

public struct RGB: Sendable, Equatable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    /// Euclidean distance in RGB space.
    public func distance(to other: RGB) -> Double { fatalError("WP-A") }
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
    public func pixel(x: Int, y: Int) -> RGB { fatalError("WP-A") }
    public func alpha(x: Int, y: Int) -> UInt8 { fatalError("WP-A") }
    /// Mean colour of a quadrant, ignoring a `inset` fraction (0…0.5) at the quadrant's edges.
    public func meanColor(of quadrant: Quadrant, inset: Double = 0.1) -> RGB { fatalError("WP-A") }
    /// Fraction (0…1) of pixels in `quadrant` whose colour is within `tolerance` of `color`.
    public func fraction(of quadrant: Quadrant, near color: RGB, tolerance: Double) -> Double { fatalError("WP-A") }
}

public enum TestImages {
    /// Opaque PNG: four solid quadrants in `colors` order (topLeft, topRight, bottomLeft, bottomRight).
    public static func quadrants(size: Int, colors: [RGB]) -> Data { fatalError("WP-A") }
    /// PNG with alpha: `transparent` quadrants have alpha 0, the rest alpha 255 (black).
    public static func mask(size: Int, transparent: Set<Quadrant>) -> Data { fatalError("WP-A") }
    /// Opaque PNG of one solid colour.
    public static func solid(width: Int, height: Int, color: RGB) -> Data { fatalError("WP-A") }
    /// Opaque PNG of pseudo-random noise (incompressible), deterministic for a seed.
    public static func noise(width: Int, height: Int, seed: UInt64) -> Data { fatalError("WP-A") }
    /// The 64×64 placeholder PNG the fixture recorder substitutes for images.
    public static func placeholder() -> Data { fatalError("WP-A") }
    /// Decodes PNG/JPEG/WebP bytes, or nil.
    public static func decode(_ data: Data) -> RGBAImage? { fatalError("WP-A") }
}
