import BBAICore
import BBModel
import Foundation

// Phase 12. A §7.7.

public enum TemplateDraftError: Error, Hashable, Sendable {
    /// No usable box survived normalization.
    case noBoxes
}

public enum TemplateNormalizer {
    /// Edges within this fraction of an axis snap to a margin line or the trim edge.
    static let snapTolerance = 0.02
    /// Boxes narrower or shorter than this fraction of the area are dropped.
    static let minimumSide = 0.02
    static let fallbackName = "AI Layout"

    /// Validates and normalizes a draft into a new `Template` (A §7.7): clamp to 0…1, snap edges
    /// within 2% of a margin or the trim edge to it, mark boxes touching the trim edge as bleed
    /// boxes, drop degenerate boxes, ensure at least one box. `kind` is `.single` or `.spread`.
    public static func template(from draft: TemplateDraft, kind: TemplateKind,
                                pageSetup: PageSetup) throws(TemplateDraftError) -> Template {
        let area = layoutArea(kind: kind, pageSetup: pageSetup)
        let lines = snapLines(kind: kind, pageSetup: pageSetup)
        var boxes: [Box] = []
        for raw in draft.boxes {
            if let box = normalize(raw, area: area, xLines: lines.x, yLines: lines.y) { boxes.append(box) }
        }
        guard !boxes.isEmpty else { throw .noBoxes }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Template(name: trimmed.isEmpty ? fallbackName : trimmed, kind: kind, boxes: boxes)
    }

    /// Applies a revised draft (Layouts chat) to `current`, normalized as in `template(from:)`.
    /// The template keeps its ID, kind, name and page role. Boxes are matched by kind in order
    /// (the n-th image box of the draft is the n-th image box of `current`, likewise for text),
    /// so a matched box keeps its ID (pages keep their text and pictures), rotation and role,
    /// and a text box keeps its font size and colour overrides; frame, bleed edges, corner
    /// radius, alignment and background panel come from the draft. Unmatched draft boxes are
    /// new; unmatched current boxes are removed.
    public static func revise(_ current: Template, with draft: TemplateDraft,
                              pageSetup: PageSetup) throws(TemplateDraftError) -> Template {
        let revised = try template(from: draft, kind: current.kind, pageSetup: pageSetup)
        func isImage(_ box: Box) -> Bool { if case .image = box.content { true } else { false } }
        var images = current.boxes.filter(isImage)[...]
        var texts = current.boxes.filter { !isImage($0) }[...]
        var result = current
        result.boxes = revised.boxes.map { new in
            guard let old = isImage(new) ? images.popFirst() : texts.popFirst() else { return new }
            var box = new
            box.id = old.id
            box.rotationDegrees = old.rotationDegrees
            box.role = old.role
            if case let .text(oldStyle) = old.content, case let .text(newStyle) = new.content {
                var style = oldStyle
                style.alignment = newStyle.alignment
                style.background = newStyle.background
                if oldStyle.background == nil, newStyle.background != nil, oldStyle.padding == 0 {
                    style.padding = newStyle.padding
                }
                box.content = .text(style)
            }
            return box
        }
        return result
    }

    /// The layout area in points: the trim, or two trims side by side for a spread.
    static func layoutArea(kind: TemplateKind, pageSetup: PageSetup) -> PointSize {
        let w = pageSetup.trimSize.width, h = pageSetup.trimSize.height
        return PointSize(width: (w.isFinite && w > 0 ? w : 1) * (kind == .spread ? 2 : 1),
                         height: h.isFinite && h > 0 ? h : 1)
    }

    /// Margin lines (trim edges included) as fractions of the layout area.
    static func snapLines(kind: TemplateKind, pageSetup: PageSetup) -> (x: [Double], y: [Double]) {
        let area = layoutArea(kind: kind, pageSetup: pageSetup)
        let page = kind == .spread ? area.width / 2 : area.width
        let m = pageSetup.margins
        func usable(_ points: Double, of total: Double) -> Bool { points.isFinite && points > 0 && points < total }
        var xs: [Double] = [0, 1]
        var ys: [Double] = [0, 1]
        for index in 0..<(kind == .spread ? 2 : 1) {
            let origin = Double(index) * page
            if usable(m.leading, of: page) { xs.append((origin + m.leading) / area.width) }
            if usable(m.trailing, of: page) { xs.append((origin + page - m.trailing) / area.width) }
        }
        if usable(m.top, of: area.height) { ys.append(m.top / area.height) }
        if usable(m.bottom, of: area.height) { ys.append(1 - m.bottom / area.height) }
        return (xs, ys)
    }

    private static func snap(_ value: Double, to lines: [Double]) -> Double {
        var best = value
        var distance = snapTolerance
        for line in lines where abs(line - value) <= distance {
            distance = abs(line - value)
            best = line
        }
        return best
    }

    private static func normalize(_ raw: DraftBox, area: PointSize, xLines: [Double], yLines: [Double]) -> Box? {
        guard raw.x.isFinite, raw.y.isFinite, raw.width.isFinite, raw.height.isFinite else { return nil }
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        let x0 = snap(clamp(raw.x), to: xLines), x1 = snap(clamp(raw.x + raw.width), to: xLines)
        let y0 = snap(clamp(raw.y), to: yLines), y1 = snap(clamp(raw.y + raw.height), to: yLines)
        guard x1 - x0 >= minimumSide, y1 - y0 >= minimumSide else { return nil }

        var edges: EdgeSet = []
        let eps = 1e-9
        if y0 <= eps { edges.insert(.top) }
        if x0 <= eps { edges.insert(.leading) }
        if y1 >= 1 - eps { edges.insert(.bottom) }
        if x1 >= 1 - eps { edges.insert(.trailing) }

        func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        // Round the edges, not the sizes, so a box can never round past the trim edge.
        let frame = NormalizedRect(x: round4(x0), y: round4(y0), width: round4(x1) - round4(x0), height: round4(y1) - round4(y0))

        var radius = raw.cornerRadius ?? 0
        if !radius.isFinite { radius = 0 }
        let shortSide = min(frame.width * area.width, frame.height * area.height)
        radius = min(max(0, radius), shortSide / 2)

        switch raw.kind {
        case .image:
            return Box(frame: frame, cornerRadius: radius, bleedEdges: edges, content: .image)
        case .text:
            let background = raw.backgroundColor.flatMap(parseHex)
            let style = TextBoxStyle(padding: background == nil ? 0 : 12, background: background,
                                     alignment: raw.textAlignment.flatMap { TextAlignment(rawValue: $0.rawValue) })
            // Bleed only matters for text boxes that paint a background.
            return Box(frame: frame, cornerRadius: radius, bleedEdges: background == nil ? [] : edges,
                       content: .text(style))
        }
    }

    /// `#RRGGBB` (the `#` optional); anything else is nil.
    static func parseHex(_ text: String) -> RGBA? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.utf8.count == 6, s.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }),
              let value = UInt32(s, radix: 16) else { return nil }
        return RGBA(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                    blue: Double(value & 0xFF) / 255)
    }

    static func hex(_ color: RGBA) -> String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v.isFinite ? v : 0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }
}
