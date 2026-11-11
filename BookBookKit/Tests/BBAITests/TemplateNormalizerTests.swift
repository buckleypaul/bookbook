import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct TemplateNormalizerTests {
    /// 576 x 576 pt trim with 36 pt margins: margin lines at 0.0625 and 0.9375.
    static let setup = PageSetup(trimSize: PointSize(width: 576, height: 576), orientation: .square,
                                 margins: EdgeInsetsPt(all: 36), bleedEnabled: true)

    static func image(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DraftBox {
        DraftBox(kind: .image, x: x, y: y, width: w, height: h)
    }

    static func text(_ x: Double, _ y: Double, _ w: Double, _ h: Double, alignment: DraftBox.Alignment? = nil,
                     radius: Double? = nil, background: String? = nil) -> DraftBox {
        DraftBox(kind: .text, x: x, y: y, width: w, height: h, textAlignment: alignment, cornerRadius: radius,
                 backgroundColor: background)
    }

    static func normalize(_ boxes: [DraftBox], kind: TemplateKind = .single, name: String = "L") throws -> Template {
        try TemplateNormalizer.template(from: TemplateDraft(name: name, boxes: boxes), kind: kind, pageSetup: setup)
    }

    // MARK: Validity

    private static func assertValid(_ template: Template, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!template.boxes.isEmpty, sourceLocation: sourceLocation)
        for box in template.boxes {
            let f = box.frame
            #expect(f.x >= 0 && f.y >= 0 && f.maxX <= 1 + 1e-9 && f.maxY <= 1 + 1e-9, sourceLocation: sourceLocation)
            #expect(f.width >= 0.02 - 1e-9 && f.height >= 0.02 - 1e-9, sourceLocation: sourceLocation)
            #expect(box.cornerRadius >= 0 && box.cornerRadius.isFinite, sourceLocation: sourceLocation)
        }
    }

    @Test func fuzzedDraftsNeverCrashAndStayValid() {
        var generator = SplitMix(seed: 42)
        let specials: [Double] = [.nan, .infinity, -.infinity, -1, -0.0, 0, 0.001, 0.02, 0.5, 1, 1.0000001, 7, 1e300, -1e300]
        let hexes: [String?] = [nil, "#FFF", "#GGGGGG", "", "red", "#12345678", "#a1B2c3", "123456", "#12 456", "ＦＦＦＦＦＦ"]
        func value() -> Double {
            generator.next() % 3 == 0 ? specials[Int(generator.next() % UInt64(specials.count))]
                : Double(generator.next() % 20_000) / 10_000 - 0.5
        }
        for round in 0..<400 {
            let count = Int(generator.next() % 6)
            let boxes = (0..<count).map { _ in
                DraftBox(kind: generator.next() % 2 == 0 ? .image : .text, x: value(), y: value(), width: value(),
                         height: value(), textAlignment: nil,
                         cornerRadius: generator.next() % 2 == 0 ? value() : nil,
                         backgroundColor: hexes[Int(generator.next() % UInt64(hexes.count))])
            }
            let kind: TemplateKind = round % 2 == 0 ? .single : .spread
            do {
                Self.assertValid(try Self.normalize(boxes, kind: kind, name: round % 3 == 0 ? "  " : "Fuzz"))
            } catch {
                #expect((error as? TemplateDraftError) == .noBoxes)
            }
        }
    }

    @Test func emptyAndAllBadBoxesThrowNoBoxes() {
        #expect(throws: TemplateDraftError.noBoxes) { try Self.normalize([]) }
        #expect(throws: TemplateDraftError.noBoxes) {
            try Self.normalize([Self.image(.nan, 0, 0.5, 0.5), Self.image(0, 0, 0, 0.5), Self.image(0.2, 0.2, -0.3, 0.3),
                                Self.image(2, 2, 0.5, 0.5), Self.image(0.1, 0.1, 0.01, 0.5), Self.image(0, 0, .infinity, 1)])
        }
    }

    @Test func degenerateBoxesDropButOthersSurvive() throws {
        let template = try Self.normalize([Self.image(0.3, 0.3, 0, 0.4), Self.image(0.3, 0.3, 0.4, 0.4)])
        #expect(template.boxes.count == 1)
    }

    @Test func nameIsTrimmedWithFallback() throws {
        #expect(try Self.normalize([Self.image(0.2, 0.2, 0.5, 0.5)], name: "  Hero  ").name == "Hero")
        #expect(try Self.normalize([Self.image(0.2, 0.2, 0.5, 0.5)], name: " \n").name == "AI Layout")
    }

    @Test func freshIDsEachTime() throws {
        let boxes = [Self.image(0.2, 0.2, 0.5, 0.5)]
        let a = try Self.normalize(boxes), b = try Self.normalize(boxes)
        #expect(a.id != b.id)
        #expect(a.boxes[0].id != b.boxes[0].id)
    }

    // MARK: Clamp and snap

    @Test func clampsToTheUnitSquare() throws {
        let template = try Self.normalize([Self.image(-0.5, 0.3, 3, 0.4)])
        let f = template.boxes[0].frame
        #expect(f.x == 0 && f.width == 1)
    }

    @Test func snapsToMarginLines() throws {
        let template = try Self.normalize([Self.image(0.07, 0.075, 0.86, 0.5)])
        let f = template.boxes[0].frame
        #expect(f.x == 0.0625)
        #expect(f.y == 0.0625)
        #expect(abs(f.maxX - 0.9375) < 1e-9)
    }

    @Test func snapsToTrimEdge() throws {
        let f = try Self.normalize([Self.image(0.015, 0.2, 0.97, 0.5)]).boxes[0].frame
        #expect(f.x == 0)
        #expect(abs(f.maxX - 1) < 1e-9)
    }

    @Test func doesNotSnapBeyondTwoPercent() throws {
        let f = try Self.normalize([Self.image(0.0625 + 0.03, 0.3, 0.4, 0.4)]).boxes[0].frame
        #expect(abs(f.x - 0.0925) < 1e-9)
    }

    @Test func nearestLineWinsWhenTwoAreInRange() throws {
        // 0.0625 (margin) and 0 (trim) are both within 2% of 0.03? No: only the margin is. Use 0.045.
        let f = try Self.normalize([Self.image(0.045, 0.3, 0.4, 0.4)]).boxes[0].frame
        #expect(f.x == 0.0625)
    }

    @Test func spreadMarginsSnapPerPage() throws {
        // Spread area is 1152 pt wide: left page margin at 36/1152, right page leading margin at (576+36)/1152.
        let f = try Self.normalize([Self.image(0.535, 0.3, 0.2, 0.3)], kind: .spread).boxes[0].frame
        #expect(abs(f.x - 612.0 / 1152.0) < 1e-3)
    }

    // MARK: Bleed

    @Test func fullBleedImageGetsAllEdges() throws {
        let box = try Self.normalize([Self.image(0, 0, 1, 1)]).boxes[0]
        #expect(box.bleedEdges == .all)
    }

    @Test func onlyTouchedEdgesBleed() throws {
        let box = try Self.normalize([Self.image(0, 0.3, 0.5, 0.7)]).boxes[0]
        #expect(box.bleedEdges == [.leading, .bottom])
        let inner = try Self.normalize([Self.image(0.2, 0.3, 0.5, 0.4)]).boxes[0]
        #expect(inner.bleedEdges.isEmpty)
    }

    @Test func spreadFoldIsNotATrimEdge() throws {
        let left = try Self.normalize([Self.image(0, 0, 0.5, 1)], kind: .spread).boxes[0]
        #expect(left.bleedEdges == [.top, .leading, .bottom])
        let right = try Self.normalize([Self.image(0.5, 0, 0.5, 1)], kind: .spread).boxes[0]
        #expect(right.bleedEdges == [.top, .trailing, .bottom])
        let across = try Self.normalize([Self.image(0, 0, 1, 1)], kind: .spread).boxes[0]
        #expect(across.bleedEdges == .all)
    }

    @Test func textWithoutBackgroundHasNoBleed() throws {
        let plain = try Self.normalize([Self.text(0, 0.7, 1, 0.3)]).boxes[0]
        #expect(plain.bleedEdges.isEmpty)
        let panel = try Self.normalize([Self.text(0, 0.7, 1, 0.3, background: "#FFEEDD")]).boxes[0]
        #expect(panel.bleedEdges == [.leading, .bottom, .trailing])
    }

    // MARK: Text styling

    @Test func textStyleFromDraft() throws {
        let box = try Self.normalize([Self.text(0.1, 0.7, 0.8, 0.2, alignment: .center, radius: 12, background: "#FFF5E1")]).boxes[0]
        guard case let .text(style) = box.content else { Issue.record("expected text"); return }
        #expect(style.alignment == .center)
        #expect(box.cornerRadius == 12)
        let bg = try #require(style.background)
        #expect(abs(bg.red - 1) < 1e-9 && abs(bg.green - 245.0 / 255) < 1e-9 && abs(bg.blue - 225.0 / 255) < 1e-9 && bg.alpha == 1)
    }

    @Test func badHexIsNil() throws {
        for hex in ["#FFF", "nope", "#GG0000", "", "#1234567"] {
            let box = try Self.normalize([Self.text(0.1, 0.1, 0.5, 0.2, background: hex)]).boxes[0]
            guard case let .text(style) = box.content else { Issue.record("expected text"); return }
            #expect(style.background == nil, "hex \(hex)")
        }
    }

    @Test func cornerRadiusIsClamped() throws {
        // 0.2 x 0.1 of 576 pt = 115.2 x 57.6: half the short side is 28.8.
        let huge = try Self.normalize([Self.image(0.3, 0.3, 0.2, 0.1)].map { var b = $0; b.cornerRadius = 1e9; return b }).boxes[0]
        #expect(abs(huge.cornerRadius - 28.8) < 1e-6)
        let negative = try Self.normalize([Self.text(0.3, 0.3, 0.2, 0.1, radius: -5)]).boxes[0]
        #expect(negative.cornerRadius == 0)
    }

    @Test func imageBoxesIgnoreTextStyling() throws {
        var raw = Self.image(0.2, 0.2, 0.5, 0.5)
        raw.backgroundColor = "#FF0000"
        raw.textAlignment = .center
        let box = try Self.normalize([raw]).boxes[0]
        #expect(box.content == .image)
    }

    // MARK: Round trip

    @Test func presetRoundTripsThroughDraft() throws {
        let preset = Template(name: "Overlay", kind: .single, boxes: [
            Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), bleedEdges: .all, content: .image),
            Box(frame: NormalizedRect(x: 0.0625, y: 0.7, width: 0.875, height: 0.22), cornerRadius: 10,
                content: .text(TextBoxStyle(padding: 12, background: RGBA(red: 1, green: 245.0 / 255, blue: 225.0 / 255),
                                            alignment: .leading))),
        ])
        let draft = LayoutPrompt.draft(from: preset, pageSetup: Self.setup)
        #expect(draft.boxes.count == 2)
        #expect(draft.boxes[1].backgroundColor == "#FFF5E1")
        #expect(draft.boxes[0].cornerRadius == nil)
        let back = try TemplateNormalizer.template(from: draft, kind: .single, pageSetup: Self.setup)
        #expect(back.name == "Overlay")
        for (a, b) in zip(preset.boxes, back.boxes) {
            #expect(abs(a.frame.x - b.frame.x) < 0.001 && abs(a.frame.y - b.frame.y) < 0.021)
            #expect(abs(a.frame.width - b.frame.width) < 0.001 && abs(a.frame.height - b.frame.height) < 0.021)
            #expect(a.bleedEdges == b.bleedEdges || b.bleedEdges.isEmpty == a.bleedEdges.isEmpty)
            #expect(a.cornerRadius == b.cornerRadius)
        }
        #expect(back.boxes[0].bleedEdges == .all)
        #expect(back.boxes[1].content == preset.boxes[1].content)
    }
}

/// Deterministic generator for fuzzing.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: Revise (Layouts chat)

extension TemplateNormalizerTests {
    @Test func revise_matchesBoxesByKindInOrder_keepingIDsAndOverrides() throws {
        let picture = Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5), rotationDegrees: 5, content: .image)
        let caption = Box(frame: NormalizedRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3),
                          content: .text(TextBoxStyle(fontSize: 30, alignment: .leading, color: RGBA(red: 1, green: 0, blue: 0, alpha: 1))),
                          role: .title)
        let current = Template(name: "Mine", kind: .single, boxes: [picture, caption], pageRole: .titlePage)
        let draft = TemplateDraft(name: "Other", boxes: [
            Self.text(0.1, 0.1, 0.8, 0.2, alignment: .center, background: "#FFFFFF"),
            Self.image(0, 0.4, 1, 0.6),
            Self.image(0.2, 0.2, 0.1, 0.1),
        ])

        let revised = try TemplateNormalizer.revise(current, with: draft, pageSetup: Self.setup)

        #expect(revised.id == current.id && revised.name == "Mine" && revised.kind == .single)
        #expect(revised.pageRole == .titlePage)
        #expect(revised.boxes.count == 3)
        // Draft order is layer order; IDs follow kind order.
        #expect(revised.boxes[0].id == caption.id)
        #expect(revised.boxes[1].id == picture.id)
        #expect(revised.boxes[2].id != picture.id && revised.boxes[2].id != caption.id)
        #expect(revised.boxes[1].rotationDegrees == 5)
        #expect(revised.boxes[1].frame.y == 0.4)
        #expect(revised.boxes[0].role == .title)
        guard case let .text(style) = revised.boxes[0].content else { Issue.record("not text"); return }
        #expect(style.fontSize == 30 && style.color == RGBA(red: 1, green: 0, blue: 0, alpha: 1))
        #expect(style.alignment == .center)
        #expect(style.background != nil && style.padding == 12)
    }

    @Test func revise_dropsUnmatchedBoxes_andRejectsEmptyDrafts() throws {
        let current = Template(name: "Two", kind: .single, boxes: [
            Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5), content: .image),
            Box(frame: NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5), content: .image),
        ])
        let revised = try TemplateNormalizer.revise(current, with: TemplateDraft(name: "", boxes: [Self.image(0, 0, 1, 1)]),
                                                    pageSetup: Self.setup)
        #expect(revised.boxes.map(\.id) == [current.boxes[0].id])
        #expect(throws: TemplateDraftError.noBoxes) {
            try TemplateNormalizer.revise(current, with: TemplateDraft(name: "", boxes: []), pageSetup: Self.setup)
        }
    }
}
