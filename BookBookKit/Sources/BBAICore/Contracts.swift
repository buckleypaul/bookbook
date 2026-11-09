import BBModel
import Foundation

// Phase 2 contract (main thread): provider protocols and request/response types
// shared by BBAI and the adapters (architecture.md §7.2, §7.11).

// MARK: - Catalog model

/// One image model from `ModelCatalog.json`, with `copyCapabilitiesFrom` already resolved
/// by `BBAI.ModelCatalog` (A §7.1).
public struct CatalogModel: Hashable, Codable, Sendable {
    public var provider: ProviderID
    public var id: String
    public var displayName: String
    public var status: ModelStatus
    public var successor: String?
    /// Typical seconds per quality level, for the elapsed-time display.
    public var typicalDurationSeconds: [QualityLevel: Double]
    public var image: ImageCapabilities
    /// Phase 9: for a custom model ID (A §7.1 item 3), the catalog model whose capabilities and
    /// prices it copies. Price lookups use `pricingModelID`. nil for bundled models.
    public var copiesFrom: String?

    public var pricingModelID: String { copiesFrom ?? id }

    public init(provider: ProviderID, id: String, displayName: String, status: ModelStatus = .current,
                successor: String? = nil, typicalDurationSeconds: [QualityLevel: Double] = [:],
                image: ImageCapabilities, copiesFrom: String? = nil) {
        self.copiesFrom = copiesFrom
        self.provider = provider
        self.id = id
        self.displayName = displayName
        self.status = status
        self.successor = successor
        self.typicalDurationSeconds = typicalDurationSeconds
        self.image = image
    }
}

public enum ModelStatus: String, Codable, Sendable {
    case current, deprecated, retired
}

public struct ImageCapabilities: Hashable, Codable, Sendable {
    public var maxReferenceImages: Int
    /// Per-image upload cap (OpenAI: 50 MB, SP-5).
    public var maxImageBytes: Int
    public var maxRequestBytes: Int
    public var supportsMask: Bool
    public var nativeMultiTurn: Bool
    public var aspect: AspectRule
    /// Provider parameters per quality level.
    public var quality: [QualityLevel: QualityMapping]

    public init(maxReferenceImages: Int, maxImageBytes: Int, maxRequestBytes: Int, supportsMask: Bool,
                nativeMultiTurn: Bool, aspect: AspectRule, quality: [QualityLevel: QualityMapping]) {
        self.maxReferenceImages = maxReferenceImages
        self.maxImageBytes = maxImageBytes
        self.maxRequestBytes = maxRequestBytes
        self.supportsMask = supportsMask
        self.nativeMultiTurn = nativeMultiTurn
        self.aspect = aspect
        self.quality = quality
    }
}

public enum AspectRule: Hashable, Codable, Sendable {
    /// Free-size models (OpenAI). Sides are multiples of `multipleOf`.
    case free(minRatio: Double, maxRatio: Double, multipleOf: Int, minPixels: Int, maxPixels: Int,
              experimentalAbovePixels: Int?)
    /// Fixed-ratio models (Gemini), e.g. ["1:1", "2:3"].
    case fixed(ratios: [String])
}

public struct QualityMapping: Hashable, Codable, Sendable {
    /// OpenAI `quality` value (`low`/`medium`/`high`).
    public var param: String?
    /// Target pixel count for free-size models.
    public var targetPixels: Int?
    /// Gemini `imageSize` (`1K`/`2K`/`4K`) and thinking level.
    public var imageSize: String?
    public var thinkingLevel: String?

    public init(param: String? = nil, targetPixels: Int? = nil, imageSize: String? = nil, thinkingLevel: String? = nil) {
        self.param = param
        self.targetPixels = targetPixels
        self.imageSize = imageSize
        self.thinkingLevel = thinkingLevel
    }
}

// MARK: - Request / result

/// Structured prompt sections (A §7.3), rendered per provider.
public struct ComposedPrompt: Hashable, Codable, Sendable {
    public struct Section: Hashable, Codable, Sendable {
        /// Stable key, e.g. `role`, `style`, `avoid`, `composition`, `story`, `request`.
        public var key: String
        public var text: String
        public init(key: String, text: String) {
            self.key = key
            self.text = text
        }
    }

    public var sections: [Section]
    public init(sections: [Section]) { self.sections = sections }

    /// Non-empty sections joined with a blank line. This is the exact text OpenAI receives.
    public var rendered: String {
        sections.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// The requested output shape: the box aspect. The adapter picks the concrete size with
/// `AspectFitter`, unless `exactSize` is set (refinements send the base image's size).
public struct OutputShape: Hashable, Codable, Sendable {
    /// width / height of the image box.
    public var boxAspect: Double
    public var exactSize: PixelSize?
    public init(boxAspect: Double, exactSize: PixelSize? = nil) {
        self.boxAspect = boxAspect
        self.exactSize = exactSize
    }
}

/// An image to upload (base image or reference).
public struct ImagePayload: Hashable, Sendable {
    public var data: Data
    /// UTType identifier.
    public var contentType: String
    public var ref: ImageRef?
    /// The image's pixel size when known (Phase 8). For a base image, the OpenAI adapter sends it
    /// as the explicit `size` of an edit (A §7.6: `size: auto` misbehaves on `/images/edits`).
    public var pixelSize: PixelSize?
    public init(data: Data, contentType: String, ref: ImageRef? = nil, pixelSize: PixelSize? = nil) {
        self.data = data
        self.contentType = contentType
        self.ref = ref
        self.pixelSize = pixelSize
    }
}

public struct ReferenceImage: Hashable, Sendable {
    public var payload: ImagePayload
    public var sent: SentReference
    public init(payload: ImagePayload, sent: SentReference) {
        self.payload = payload
        self.sent = sent
    }
}

/// A region-edit mask (A §7.6, Phase 11), already encoded for the wire: a PNG with alpha at the
/// base image's exact pixel size, **transparent (alpha 0) where the provider may edit** and opaque
/// elsewhere (SP-4 polarity). Only sent when the model's `supportsMask` is true.
public struct MaskPayload: Hashable, Sendable {
    /// PNG bytes (RGBA). Must match `ImageRequest.baseImage.pixelSize` exactly.
    public var pngData: Data
    public var pixelSize: PixelSize
    /// The stored mask image in the book (the user's 8-bit mask, white = edit area), if any.
    public var ref: ImageRef?
    public init(pngData: Data, pixelSize: PixelSize, ref: ImageRef? = nil) {
        self.pngData = pngData
        self.pixelSize = pixelSize
        self.ref = ref
    }
}

/// Provider-neutral image request (A §7.2). Phase 11 adds `mask`; `history` comes with Gemini.
public struct ImageRequest: Sendable {
    public var model: CatalogModel
    public var quality: QualityLevel
    public var output: OutputShape
    public var instruction: ComposedPrompt
    public var baseImage: ImagePayload?
    public var references: [ReferenceImage]
    /// Region edit only (requires `baseImage`). nil for every other request.
    public var mask: MaskPayload?

    public init(model: CatalogModel, quality: QualityLevel, output: OutputShape, instruction: ComposedPrompt,
                baseImage: ImagePayload? = nil, references: [ReferenceImage] = [], mask: MaskPayload? = nil) {
        self.model = model
        self.quality = quality
        self.output = output
        self.instruction = instruction
        self.baseImage = baseImage
        self.references = references
        self.mask = mask
    }
}

public struct ImageResult: Sendable {
    public var imageData: Data
    /// UTType identifier of `imageData` (`public.png` for OpenAI with `output_format: png`).
    public var contentType: String
    public var pixelSize: PixelSize
    public var usage: TokenUsage?
    public var revisedPrompt: String?
    /// Every wire parameter sent besides the prompt and images (for Provenance / Version details).
    public var parametersSent: [String: String]

    public init(imageData: Data, contentType: String, pixelSize: PixelSize, usage: TokenUsage? = nil,
                revisedPrompt: String? = nil, parametersSent: [String: String] = [:]) {
        self.imageData = imageData
        self.contentType = contentType
        self.pixelSize = pixelSize
        self.usage = usage
        self.revisedPrompt = revisedPrompt
        self.parametersSent = parametersSent
    }
}

public enum GenerationProgress: Sendable, Equatable {
    /// The request has been handed to the network.
    case sent
    /// The response arrived and is being decoded.
    case receiving
}

// MARK: - Protocols

/// Phase 9: the provider's list-models endpoint, called with the stored key by "Test
/// connection" and when Settings opens (A §7.1 "model churn"). Sends no book data.
public protocol ModelLister: Sendable {
    var id: ProviderID { get }
    /// The model IDs the key can use. Throws `.missingKey`, `.invalidKey`, `.offline`, ….
    func listModelIDs() async throws(ProviderError) -> Set<String>
}

public protocol ImageProvider: Sendable {
    var id: ProviderID { get }
    func generate(_ request: ImageRequest,
                  progress: @escaping @Sendable (GenerationProgress) -> Void) async throws(ProviderError) -> ImageResult
}

// MARK: - Errors (A §7.11)

/// The raw provider response, kept for the Details disclosure. The adapter redacts any key
/// echo (e.g. `Redaction.redactMaskedKeys`) before building this; it never holds the key.
public struct ProviderErrorRaw: Hashable, Codable, Sendable {
    public var status: Int?
    public var code: String?
    public var body: String
    public init(status: Int?, code: String?, body: String) {
        self.status = status
        self.code = code
        self.body = body
    }
}

public enum RefusalStage: String, Codable, Sendable {
    case input, output, unknown
}

public enum ProviderError: Error, Hashable, Codable, Sendable {
    case invalidKey(ProviderErrorRaw?)
    /// No key is stored for the provider.
    case missingKey
    case verificationRequired(ProviderErrorRaw?)
    case regionUnsupported(ProviderErrorRaw?)
    case billing(ProviderErrorRaw?)
    case rateLimited(retryAfter: Double?, ProviderErrorRaw?)
    case refused(stage: RefusalStage, categories: [String], ProviderErrorRaw?)
    case noImage(ProviderErrorRaw?)
    case invalidRequest(param: String?, ProviderErrorRaw?)
    case modelUnavailable(ProviderErrorRaw?)
    case transient(ProviderErrorRaw?)
    case offline
    case timeout
    case cancelled
    /// Anything unmapped.
    case unknown(ProviderErrorRaw?)

    /// A rate limit or a transient server/transport failure. Informational: the queue's retries
    /// are decided by `QueueRetryPolicy` (BBAI), which also retries `.offline` and `.noImage`.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .transient: true
        default: false
        }
    }
}
