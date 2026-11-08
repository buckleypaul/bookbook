import Foundation

// Small value types shared by the model (architecture.md §4.1). Foundation only.

/// A content-addressed image: the lowercase hex SHA-256 of the file's bytes plus its UTType
/// identifier. The file lives at `images/<sha256>.<fileExtension>` in the book package.
public struct ImageRef: Hashable, Codable, Sendable {
    public var sha256: String
    /// UTType identifier, e.g. `public.png`, `public.jpeg`.
    public var contentType: String

    public init(sha256: String, contentType: String) {
        self.sha256 = sha256
        self.contentType = contentType
    }

    public var fileExtension: String {
        switch contentType {
        case "public.png": "png"
        case "public.jpeg": "jpg"
        case "org.webmproject.webp": "webp"
        case "public.heic": "heic"
        default: "bin"
        }
    }

    /// File name inside `images/`.
    public var fileName: String { "\(sha256).\(fileExtension)" }
}

/// A rectangle normalized to the template's trim area: 0…1 on each axis, origin at the
/// **top-left** of the trim, y increasing downward. (Renderers flip for Core Graphics.)
public struct NormalizedRect: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// The overlapping part of two rects, or nil if they don't overlap.
    public func intersection(_ other: NormalizedRect) -> NormalizedRect? {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// A point in normalized coordinates (0…1), origin top-left.
public struct NormalizedPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = NormalizedPoint(x: 0.5, y: 0.5)
}

/// A size in points (1/72 in).
public struct PointSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Insets in points.
public struct EdgeInsetsPt: Hashable, Codable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public init(all value: Double) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }
}

/// A size in pixels.
public struct PixelSize: Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var aspect: Double { Double(width) / Double(height) }
    public var pixelCount: Int { width * height }
    /// `1024x1536` form, as used by the OpenAI `size` parameter and the price list keys.
    public var description: String { "\(width)x\(height)" }
}

/// sRGB colour, components 0…1.
public struct RGBA: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBA(red: 0, green: 0, blue: 0)
    public static let white = RGBA(red: 1, green: 1, blue: 1)
}

/// Edges of a box (used for bleed).
public struct EdgeSet: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let top = EdgeSet(rawValue: 1 << 0)
    public static let leading = EdgeSet(rawValue: 1 << 1)
    public static let bottom = EdgeSet(rawValue: 1 << 2)
    public static let trailing = EdgeSet(rawValue: 1 << 3)
    public static let all: EdgeSet = [.top, .leading, .bottom, .trailing]
}

/// Text alignment.
public enum TextAlignment: String, Codable, Sendable, CaseIterable {
    case leading, center, trailing, justified
}

/// A provider identifier (`openai`, `gemini`).
public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let openai = ProviderID(rawValue: "openai")
    public static let gemini = ProviderID(rawValue: "gemini")

    public var description: String { rawValue }
}

/// The product's three quality levels (PD §5). Each provider maps them differently (A §7.1).
public enum QualityLevel: String, Codable, Sendable, CaseIterable {
    case draft, standard, high
}

/// Token usage reported by a provider, by modality.
public struct TokenUsage: Hashable, Codable, Sendable {
    public var inputTextTokens: Int
    public var inputImageTokens: Int
    public var cachedInputTokens: Int
    public var outputTextTokens: Int
    public var outputImageTokens: Int

    public init(inputTextTokens: Int = 0, inputImageTokens: Int = 0, cachedInputTokens: Int = 0,
                outputTextTokens: Int = 0, outputImageTokens: Int = 0) {
        self.inputTextTokens = inputTextTokens
        self.inputImageTokens = inputImageTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTextTokens = outputTextTokens
        self.outputImageTokens = outputImageTokens
    }
}

/// A secret API key. Never printed, reflected or encoded: `description`, `debugDescription`
/// and `dump()` all show `<redacted>`, and it is deliberately not `Codable`.
/// The only way to read it is `revealForTransport()`, which provider adapters call to set
/// the auth header and nothing else may call.
public struct APIKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.value = trimmed
    }

    /// For the auth header only. Never log, store or interpolate the result.
    public func revealForTransport() -> String { value }

    /// True if the key's bytes appear in `data` (fixture recorder and redaction checks).
    public func occurs(in data: Data) -> Bool {
        data.range(of: Data(value.utf8)) != nil
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
