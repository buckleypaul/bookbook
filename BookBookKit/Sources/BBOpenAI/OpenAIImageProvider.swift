import BBAICore
import BBModel
import BBNet
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// OpenAI GPT Image adapter: `/images/generations`, or `/images/edits` (multipart) when a base
/// image or references are present (architecture.md §7.6). Masks arrive in Phase 11.
public struct OpenAIImageProvider: ImageProvider {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    public var id: ProviderID { .openai }

    private let http: any HTTPClient
    private let apiKey: @Sendable () async -> APIKey?
    private let baseURL: URL
    private let boundary: @Sendable () -> String

    /// `boundary` is injectable so tests can golden the multipart body.
    public init(http: any HTTPClient, apiKey: @escaping @Sendable () async -> APIKey?,
                baseURL: URL = OpenAIImageProvider.defaultBaseURL,
                boundary: @escaping @Sendable () -> String = { "bookbook-\(UUID().uuidString)" }) {
        self.http = http
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.boundary = boundary
    }

    public func generate(
        _ request: ImageRequest,
        progress: @escaping @Sendable (GenerationProgress) -> Void
    ) async throws(ProviderError) -> ImageResult {
        let images = [request.baseImage].compactMap { $0 } + request.references.map(\.payload)
        let isEdit = !images.isEmpty
        let parameters = try Self.parameters(for: request)
        if isEdit {
            try Self.validate(images, limit: request.model.image.maxImageBytes)
            // Edits send the request's size (`exactSize`, snapped to the model's rules by the assembler),
            // never the raw base image size, which may be invalid for the model.
        }

        guard let key = await apiKey() else { throw .missingKey }

        let prompt = request.instruction.rendered
        let url: URL
        let contentType: String
        let bodyData: Data
        if isEdit {
            var form = MultipartForm(boundary: boundary())
            for (index, image) in images.enumerated() {
                guard let type = Self.imageType(image.contentType) else { throw .invalidRequest(param: "image", nil) }
                form.addFile(name: "image[]", filename: "image\(index + 1).\(type.ext)", mimeType: type.mime, data: image.data)
            }
            form.addField(name: "prompt", value: prompt)
            for (name, value) in parameters.sorted(by: { $0.key < $1.key }) { form.addField(name: name, value: "\(value)") }
            let encoded = form.encoded()
            url = baseURL.appending(path: "images/edits")
            contentType = encoded.contentType
            bodyData = encoded.body
        } else {
            var body: [String: Any] = parameters
            body["prompt"] = prompt
            guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
                throw .invalidRequest(param: nil, nil)
            }
            url = baseURL.appending(path: "images/generations")
            contentType = "application/json"
            bodyData = data
        }
        let httpRequest = HTTPRequest(
            method: "POST", url: url,
            headers: ["Authorization": "Bearer \(key.revealForTransport())", "Content-Type": contentType],
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

    static let maxEditImages = 16

    /// Accepted upload formats. HEIC and the rest must be normalised by the caller.
    static func imageType(_ identifier: String) -> (mime: String, ext: String)? {
        guard let type = UTType(identifier) else { return nil }
        if type.conforms(to: .png) { return ("image/png", "png") }
        if type.conforms(to: .jpeg) { return ("image/jpeg", "jpg") }
        if type.conforms(to: .webP) { return ("image/webp", "webp") }
        return nil
    }

    /// Count, format and per-file size checks, before any network call.
    static func validate(_ images: [ImagePayload], limit: Int) throws(ProviderError) {
        guard images.count <= maxEditImages else { throw .invalidRequest(param: "image", nil) }
        for (index, image) in images.enumerated() {
            guard imageType(image.contentType) != nil else { throw .invalidRequest(param: "image[\(index)]", nil) }
            guard image.data.count <= limit else {
                throw .invalidRequest(param: "image[\(index)]", ProviderErrorRaw(
                    status: nil, code: "file_above_max_size",
                    body: "image[\(index)] is \(image.data.count) bytes; the limit is \(limit)."))
            }
        }
    }

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
