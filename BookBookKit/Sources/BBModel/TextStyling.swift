import Foundation

// AI text styling (PD §8.6 "Styling a text box", A §7.13). A text box on one page can be styled
// with AI: a text model picks the typography and describes a decoration (frame, border,
// flourishes), and the image model paints that decoration on a transparent background. The
// decoration is drawn behind the real, editable text. Each page text box has its own session
// (`SessionOwner.textBox`); a version is the decoration image plus the typography, which lives
// in the version's `provenance.intent.textStyle`.

/// Typography a text style applies to one page's text box, layered over the template box's
/// `TextBoxStyle` (and under a run's own attributes, like the template overrides).
public struct TextStyling: Hashable, Codable, Sendable {
    /// The face to draw the box's text in (an installed or imported font). nil = unchanged.
    public var font: FontRef?
    /// Points. nil = unchanged.
    public var fontSize: Double?
    public var color: RGBA?
    public var alignment: TextAlignment?
    /// How far the text sits inside the box, as a fraction of the box's shorter side (0…0.35),
    /// so it clears a frame. The larger of this and the template's padding wins.
    public var insetFraction: Double
    /// A flat panel behind the text (and in front of the decoration), or nil for none. A styled
    /// box never draws the template's own panel.
    public var background: RGBA?

    public init(font: FontRef? = nil, fontSize: Double? = nil, color: RGBA? = nil, alignment: TextAlignment? = nil,
                insetFraction: Double = 0, background: RGBA? = nil) {
        self.font = font
        self.fontSize = fontSize
        self.color = color
        self.alignment = alignment
        self.insetFraction = insetFraction
        self.background = background
    }

    public static let maxInsetFraction = 0.35

    /// The text inset in points for a box `size` points large with the template's `padding`.
    public func inset(boxSize: PointSize, templatePadding: Double) -> Double {
        let fraction = min(max(insetFraction, 0), Self.maxInsetFraction)
        return max(templatePadding, fraction * min(boxSize.width, boxSize.height))
    }
}

extension Typography {
    /// `self` with a text style's overrides applied (font, size, colour, alignment).
    public func applying(_ styling: TextStyling) -> Typography {
        var copy = self
        if let font = styling.font { copy.bodyFont = font }
        if let size = styling.fontSize { copy.bodySize = size }
        if let color = styling.color { copy.color = color }
        if let alignment = styling.alignment { copy.alignment = alignment }
        return copy
    }
}

/// What was sent to the text model for a styling request, and what it cost (Version details).
public struct TextStyleCall: Hashable, Codable, Sendable {
    public var provider: ProviderID
    public var model: String
    public var system: String
    public var user: String
    public var parametersSent: [String: String]
    public var usage: TokenUsage?
    public var cost: CostRecordID?

    public init(provider: ProviderID, model: String, system: String, user: String,
                parametersSent: [String: String] = [:], usage: TokenUsage? = nil, cost: CostRecordID? = nil) {
        self.provider = provider
        self.model = model
        self.system = system
        self.user = user
        self.parametersSent = parametersSent
        self.usage = usage
        self.cost = cost
    }
}

/// The text model's answer for one styling request, fixed when the decoration is queued
/// (`GenerationIntent.textStyle`). Replayed by "Regenerate with same settings".
public struct TextStyleIntent: Hashable, Codable, Sendable {
    public var styling: TextStyling
    /// What the image model is asked to paint. nil = typography only (no image request; the
    /// version's image is a 1×1 transparent placeholder).
    public var decorationPrompt: String?
    /// The model's one-line summary of the design, shown in the thread.
    public var summary: String
    public var call: TextStyleCall

    public init(styling: TextStyling, decorationPrompt: String?, summary: String, call: TextStyleCall) {
        self.styling = styling
        self.decorationPrompt = decorationPrompt
        self.summary = summary
        self.call = call
    }
}

/// A page text box's styling session and the version shown (`Page.textStyles`).
public struct TextStyleSlot: Hashable, Codable, Sendable {
    public var sessionID: SessionID
    /// nil = unstyled (the template's own look).
    public var versionID: VersionID?

    public init(sessionID: SessionID, versionID: VersionID? = nil) {
        self.sessionID = sessionID
        self.versionID = versionID
    }
}

/// A text box's applied style, resolved for drawing.
public struct AppliedTextStyle: Hashable, Sendable {
    public var version: Version
    public var styling: TextStyling
    /// The decoration, or nil for a typography-only version.
    public var decoration: ImageRef?
}

extension Version {
    /// The typography a text-style version applies (nil for picture versions).
    public var textStyle: TextStyleIntent? { provenance?.intent.textStyle }
}

extension BookContent {
    /// The style shown on `page`'s text box `box`, if any.
    public func appliedTextStyle(page pageID: PageID, box boxID: BoxID) -> AppliedTextStyle? {
        guard let slot = pages[pageID]?.textStyles[boxID], let versionID = slot.versionID,
              let version = sessions[slot.sessionID]?.version(versionID),
              let intent = version.textStyle else { return nil }
        return AppliedTextStyle(version: version, styling: intent.styling,
                                decoration: intent.decorationPrompt == nil ? nil : version.image)
    }
}
