import BBAICore
import BBModel
import BBNet
import Foundation
import ImageIO

/// OpenAI GPT Image adapter. Phase 2 implements `POST /v1/images/generations` only; edits
/// (references, base image, masks) arrive in Phase 8 (architecture.md §7.6).
public struct OpenAIImageProvider: ImageProvider {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    public var id: ProviderID { .openai }

    private let http: any HTTPClient
    private let apiKey: @Sendable () async -> APIKey?
    private let baseURL: URL

    public init(http: any HTTPClient, apiKey: @escaping @Sendable () async -> APIKey?,
                baseURL: URL = OpenAIImageProvider.defaultBaseURL) {
        self.http = http
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func generate(
        _ request: ImageRequest,
        progress: @escaping @Sendable (GenerationProgress) -> Void
    ) async throws(ProviderError) -> ImageResult {
        guard request.references.isEmpty, request.baseImage == nil else {
            throw .invalidRequest(param: "references", nil)
        }
        let parameters = try Self.parameters(for: request)

        guard let key = await apiKey() else { throw .missingKey }

        var body: [String: Any] = parameters
        body["prompt"] = request.instruction.rendered
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw .invalidRequest(param: nil, nil)
        }
        let httpRequest = HTTPRequest(
            method: "POST",
            url: baseURL.appending(path: "images/generations"),
            headers: ["Authorization": "Bearer \(key.revealForTransport())", "Content-Type": "application/json"],
            body: bodyData)

        progress(.sent)
        let response: HTTPResponse
        do {
            response = try await http.send(httpRequest)
        } catch {
            switch error {
            case .offline: throw .offline
            case .timedOut: throw .timeout
            case .cancelled: throw .cancelled
            case .transport: throw .transient(nil)
            }
        }
        progress(.receiving)

        guard (200..<300).contains(response.status) else {
            throw OpenAIErrorMapper.map(response, key: key)
        }
        return try Self.decode(response, parametersSent: parameters.mapValues { "\($0)" }, key: key)
    }

    // MARK: Request

    /// Every JSON field except `prompt`.
    static func parameters(for request: ImageRequest) throws(ProviderError) -> [String: Any] {
        let size: PixelSize
        if let exact = request.output.exactSize {
            size = exact
        } else {
            switch AspectFitter.fit(boxAspect: request.output.boxAspect, model: request.model, quality: request.quality) {
            case .pixels(let pixels): size = pixels
            case .ratio: throw .invalidRequest(param: "size", nil)
            }
        }
        guard let quality = request.model.image.quality[request.quality]?.param else {
            throw .invalidRequest(param: "quality", nil)
        }
        return [
            "model": request.model.id,
            "size": "\(size.width)x\(size.height)",
            "quality": quality,
            "output_format": "png",
            "n": 1,
            "moderation": "auto",
        ]
    }

    // MARK: Response

    private static func decode(_ response: HTTPResponse, parametersSent: [String: String],
                               key: APIKey) throws(ProviderError) -> ImageResult {
        let raw = OpenAIErrorMapper.raw(response, code: nil, key: key)
        guard let root = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw .unknown(raw)
        }
        guard let first = (root["data"] as? [[String: Any]])?.first,
              let b64 = first["b64_json"] as? String, !b64.isEmpty else {
            throw .noImage(raw)
        }
        guard let png = Data(base64Encoded: b64), let size = pixelSize(of: png) else {
            throw .unknown(ProviderErrorRaw(status: response.status, code: nil, body: "image could not be decoded"))
        }
        let revised = (first["revised_prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ImageResult(imageData: png, contentType: "public.png", pixelSize: size,
                           usage: OpenAIUsage.parse(root["usage"]), revisedPrompt: revised,
                           parametersSent: parametersSent)
    }

    static func pixelSize(of data: Data) -> PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return PixelSize(width: width, height: height)
    }
}

/// `usage` from an Images API response (`input_tokens_details`, `output_tokens_details`) or a
/// Chat Completions body (`prompt_tokens`, `completion_tokens`).
enum OpenAIUsage {
    static func parse(_ value: Any?) -> TokenUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        func int(_ dict: [String: Any]?, _ key: String) -> Int? { (dict?[key] as? NSNumber)?.intValue }
        var result = TokenUsage()
        if let input = int(usage, "input_tokens") ?? int(usage, "prompt_tokens") {
            let details = (usage["input_tokens_details"] ?? usage["prompt_tokens_details"]) as? [String: Any]
            let image = int(details, "image_tokens") ?? 0
            result.inputImageTokens = image
            result.inputTextTokens = int(details, "text_tokens") ?? max(input - image, 0)
            result.cachedInputTokens = int(details, "cached_tokens") ?? 0
        }
        if let output = int(usage, "output_tokens") {
            let details = usage["output_tokens_details"] as? [String: Any]
            let text = int(details, "text_tokens") ?? 0
            result.outputTextTokens = text
            result.outputImageTokens = int(details, "image_tokens") ?? max(output - text, 0)
        } else if let completion = int(usage, "completion_tokens") {
            result.outputTextTokens = completion
        }
        return result
    }
}
