import BBModel
import Foundation

// Phase 12 contract (main thread): text (layout) and vision (consistency) providers,
// architecture.md §7.2, §7.7, §7.8. Wire formats stay in the adapters.

// MARK: - Catalog

public enum TextModelKind: String, Codable, Sendable {
    /// Structured-output text model (template generation).
    case text
    /// Vision model (consistency check).
    case vision
}

/// A text or vision model from `ModelCatalog.json` (`kind: text | vision`).
public struct CatalogTextModel: Hashable, Codable, Sendable {
    public var provider: ProviderID
    public var id: String
    public var displayName: String
    public var kind: TextModelKind
    public var status: ModelStatus
    public var successor: String?
    /// Typical seconds per request (the catalog's `typicalDurationSeconds.default`).
    public var typicalDurationSeconds: Double?
    /// Vision models: the image detail level to send (`"low"` for OpenAI). nil for text models.
    public var imageDetail: String?
    /// Vision models: the warning thresholds (`consistency` in the catalog). nil for text models.
    public var consistency: ConsistencyThresholds?

    public init(provider: ProviderID, id: String, displayName: String, kind: TextModelKind,
                status: ModelStatus = .current, successor: String? = nil, typicalDurationSeconds: Double? = nil,
                imageDetail: String? = nil, consistency: ConsistencyThresholds? = nil) {
        self.provider = provider
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.status = status
        self.successor = successor
        self.typicalDurationSeconds = typicalDurationSeconds
        self.imageDetail = imageDetail
        self.consistency = consistency
    }
}

/// A §7.8: warn on at least `warnOnMajor` major differences, or at least `warnOnMinor` minor ones.
public struct ConsistencyThresholds: Hashable, Codable, Sendable {
    public var warnOnMajor: Int
    public var warnOnMinor: Int

    public init(warnOnMajor: Int = 1, warnOnMinor: Int = 3) {
        self.warnOnMajor = warnOnMajor
        self.warnOnMinor = warnOnMinor
    }

    public static let standard = ConsistencyThresholds()

    public func warns(_ differences: [ConsistencyDifference]) -> Bool {
        let major = differences.filter { $0.severity == .major }.count
        let minor = differences.count - major
        return major >= warnOnMajor || minor >= warnOnMinor
    }
}

// MARK: - Template generation (A §7.7)

/// The structured output of a layout request. Coordinates are fractions (0…1) of the
/// template's trim area (both pages for a spread), origin top-left. Validated and normalized
/// locally by `BBAI.TemplateNormalizer`; raw values may be out of range.
public struct TemplateDraft: Hashable, Codable, Sendable {
    public var name: String
    public var boxes: [DraftBox]

    public init(name: String, boxes: [DraftBox]) {
        self.name = name
        self.boxes = boxes
    }
}

public struct DraftBox: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, text }
    public enum Alignment: String, Codable, Sendable { case leading, center, trailing, justified }

    public var kind: Kind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Text boxes only; nil = the style guide's alignment.
    public var textAlignment: Alignment?
    /// Points; nil = square corners.
    public var cornerRadius: Double?
    /// Text boxes only: background panel colour as `#RRGGBB`; nil = none.
    public var backgroundColor: String?

    public init(kind: Kind, x: Double, y: Double, width: Double, height: Double, textAlignment: Alignment? = nil,
                cornerRadius: Double? = nil, backgroundColor: String? = nil) {
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.textAlignment = textAlignment
        self.cornerRadius = cornerRadius
        self.backgroundColor = backgroundColor
    }
}

/// The JSON Schemas sent as structured output, written to the intersection of OpenAI strict
/// mode and Gemini's supported keywords (A §7.7). Shared by every adapter.
public enum StructuredSchemas {
    public static let templateDraftName = "template_draft"
    public static let templateDraft = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["name", "boxes"],
      "properties": {
        "name": {"type": "string"},
        "boxes": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["kind", "x", "y", "width", "height", "textAlignment", "cornerRadius", "backgroundColor"],
            "properties": {
              "kind": {"type": "string", "enum": ["image", "text"]},
              "x": {"type": "number"},
              "y": {"type": "number"},
              "width": {"type": "number"},
              "height": {"type": "number"},
              "textAlignment": {"type": ["string", "null"], "enum": ["leading", "center", "trailing", "justified", null]},
              "cornerRadius": {"type": ["number", "null"]},
              "backgroundColor": {"type": ["string", "null"]}
            }
          }
        }
      }
    }
    """#

    public static let consistencyName = "consistency_result"
    public static let consistency = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["consistent", "differences"],
      "properties": {
        "consistent": {"type": "boolean"},
        "differences": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["asset", "aspect", "observed", "expected", "severity"],
            "properties": {
              "asset": {"type": ["string", "null"]},
              "aspect": {"type": "string"},
              "observed": {"type": "string"},
              "expected": {"type": "string"},
              "severity": {"type": "string", "enum": ["minor", "major"]}
            }
          }
        }
      }
    }
    """#
}

/// A provider-neutral layout request. `system` and `user` are fully rendered by BBAI
/// (`LayoutPrompt`), including the page setup and the few-shot preset examples.
public struct LayoutRequest: Hashable, Sendable {
    public var model: CatalogTextModel
    public var system: String
    public var user: String

    public init(model: CatalogTextModel, system: String, user: String) {
        self.model = model
        self.system = system
        self.user = user
    }
}

public struct LayoutResult: Hashable, Sendable {
    public var draft: TemplateDraft
    public var usage: TokenUsage?
    /// Wire parameters sent besides the prompt (e.g. `model`, `store`, `response_format`).
    public var parametersSent: [String: String]

    public init(draft: TemplateDraft, usage: TokenUsage? = nil, parametersSent: [String: String] = [:]) {
        self.draft = draft
        self.usage = usage
        self.parametersSent = parametersSent
    }
}

// MARK: - Consistency check (A §7.8)

/// An image sent to the vision model with the label the prompt refers to it by.
public struct LabeledImage: Hashable, Sendable {
    public var label: String
    /// Already downscaled to a 1024 px long edge by BBAI.
    public var payload: ImagePayload

    public init(label: String, payload: ImagePayload) {
        self.label = label
        self.payload = payload
    }
}

/// `image` is the version being checked; `references` are the assets' chosen images, then up
/// to two style references (A §7.8).
public struct ConsistencyRequest: Hashable, Sendable {
    public var model: CatalogTextModel
    public var system: String
    public var user: String
    public var image: LabeledImage
    public var references: [LabeledImage]

    public init(model: CatalogTextModel, system: String, user: String, image: LabeledImage, references: [LabeledImage]) {
        self.model = model
        self.system = system
        self.user = user
        self.image = image
        self.references = references
    }
}

public struct ConsistencyResult: Hashable, Sendable {
    public var consistent: Bool
    public var differences: [ConsistencyDifference]
    public var usage: TokenUsage?
    public var parametersSent: [String: String]

    public init(consistent: Bool, differences: [ConsistencyDifference], usage: TokenUsage? = nil,
                parametersSent: [String: String] = [:]) {
        self.consistent = consistent
        self.differences = differences
        self.usage = usage
        self.parametersSent = parametersSent
    }
}

// MARK: - Protocols (A §7.2)

/// Refusals (`message.refusal`, `finish_reason: content_filter`) map to `.refused`; a reply
/// that doesn't decode to the schema maps to `.invalidRequest(param: "response_format")`.
public protocol LayoutProvider: Sendable {
    var id: ProviderID { get }
    func generateLayout(_ request: LayoutRequest) async throws(ProviderError) -> LayoutResult
}

public protocol VisionProvider: Sendable {
    var id: ProviderID { get }
    func checkConsistency(_ request: ConsistencyRequest) async throws(ProviderError) -> ConsistencyResult
}

// MARK: - AI text styling (A §7.13)

/// The structured output of a text-styling request: typography for one text box plus a
/// description of the decoration to paint around it. Validated locally by
/// `BBAI.TextStyleNormalizer` (font checked against the allowed list, numbers clamped, colours
/// parsed); raw values may be out of range.
public struct TextStyleDraft: Hashable, Codable, Sendable {
    /// One of the font families listed in the prompt; nil = keep the current font.
    public var fontFamily: String?
    /// Points; nil = keep the current size.
    public var fontSize: Double?
    /// `#RRGGBB`; nil = keep the current colour.
    public var textColor: String?
    /// nil = keep the current alignment.
    public var alignment: DraftBox.Alignment?
    /// Fraction of the box's shorter side (0…0.35) to keep the text inside a frame.
    public var textInset: Double
    /// Flat panel behind the text, `#RRGGBB`; nil = none.
    public var panelColor: String?
    /// What to paint around and behind the text, for the image model; nil = typography only.
    public var decoration: String?
    /// One short sentence describing the design, for the user.
    public var summary: String

    public init(fontFamily: String? = nil, fontSize: Double? = nil, textColor: String? = nil,
                alignment: DraftBox.Alignment? = nil, textInset: Double = 0, panelColor: String? = nil,
                decoration: String? = nil, summary: String) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.textColor = textColor
        self.alignment = alignment
        self.textInset = textInset
        self.panelColor = panelColor
        self.decoration = decoration
        self.summary = summary
    }
}

extension StructuredSchemas {
    public static let textStyleName = "text_style"
    public static let textStyle = #"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["fontFamily", "fontSize", "textColor", "alignment", "textInset", "panelColor", "decoration", "summary"],
      "properties": {
        "fontFamily": {"type": ["string", "null"]},
        "fontSize": {"type": ["number", "null"]},
        "textColor": {"type": ["string", "null"]},
        "alignment": {"type": ["string", "null"], "enum": ["leading", "center", "trailing", "justified", null]},
        "textInset": {"type": "number"},
        "panelColor": {"type": ["string", "null"]},
        "decoration": {"type": ["string", "null"]},
        "summary": {"type": "string"}
      }
    }
    """#
}

/// A provider-neutral text-styling request. `system` and `user` are fully rendered by BBAI
/// (`TextStylePrompt`), including the allowed font families and the box's current look.
public struct TextStyleRequest: Hashable, Sendable {
    public var model: CatalogTextModel
    public var system: String
    public var user: String

    public init(model: CatalogTextModel, system: String, user: String) {
        self.model = model
        self.system = system
        self.user = user
    }
}

public struct TextStyleResult: Hashable, Sendable {
    public var draft: TextStyleDraft
    public var usage: TokenUsage?
    public var parametersSent: [String: String]

    public init(draft: TextStyleDraft, usage: TokenUsage? = nil, parametersSent: [String: String] = [:]) {
        self.draft = draft
        self.usage = usage
        self.parametersSent = parametersSent
    }
}

/// Same error mapping as `LayoutProvider`.
public protocol TextStyleProvider: Sendable {
    var id: ProviderID { get }
    func styleText(_ request: TextStyleRequest) async throws(ProviderError) -> TextStyleResult
}
