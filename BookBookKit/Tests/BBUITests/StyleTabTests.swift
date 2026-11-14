import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// The Style tab's model: one command per field edit, inch conversion, preset fill.
@MainActor
struct StyleTabTests {
    final class Sink {
        var content: BookContent
        var commands: [BookCommand] = []
        init(_ content: BookContent) { self.content = content }
    }

    static let watercolour = StylePreset(id: "watercolour", name: "Watercolour",
                                         visualDescription: "Soft washes", negativeGuidance: "no photos")
    static let plain = StylePreset(id: "plain", name: "Plain", visualDescription: "Flat colour")

    func make() -> (StyleTabModel, Sink) {
        let sink = Sink(Fixtures.book())
        let model = StyleTabModel(content: { sink.content }, perform: { sink.commands.append($0) },
                                  presets: [Self.watercolour, Self.plain])
        return (model, sink)
    }

    @Test func inchConversion() {
        #expect(StyleTabModel.points(0.125) == 9)
        #expect(StyleTabModel.inches(612) == 8.5)
        #expect(StyleTabModel.inches(StyleTabModel.points(3.3)) == 3.3)
    }

    @Test func choosingPresetFillsFieldsAndKeepsReferences() {
        let (model, sink) = make()
        sink.content.style.styleReferences = [Fixtures.ref]
        model.choosePreset(Self.watercolour)
        guard case let .setStyleVisual(v)? = sink.commands.first else { Issue.record("no command"); return }
        #expect(v.presetID == "watercolour")
        #expect(v.visualDescription == "Soft washes")
        #expect(v.negativeGuidance == "no photos")
        #expect(v.styleReferences == [Fixtures.ref])
    }

    @Test func presetWithoutNegativeGuidanceUsesDefault() {
        let (model, sink) = make()
        sink.content.style.negativeGuidance = "custom"
        model.choosePreset(Self.plain)
        guard case let .setStyleVisual(v)? = sink.commands.first else { Issue.record("no command"); return }
        #expect(v.negativeGuidance == StyleGuide.defaultNegativeGuidance)
    }

    @Test func descriptionAndNegativeGuidanceEmitOneCommandEach() {
        let (model, sink) = make()
        model.setDescription("Ink and wash")
        model.setNegativeGuidance("no borders")
        #expect(sink.commands == [
            .setStyleVisual(StyleVisual(presetID: nil, visualDescription: "Ink and wash",
                                        styleReferences: [], negativeGuidance: StyleGuide.defaultNegativeGuidance)),
            .setStyleVisual(StyleVisual(presetID: nil, visualDescription: "",
                                        styleReferences: [], negativeGuidance: "no borders")),
        ])
    }

    @Test func unchangedTextEmitsNothing() {
        let (model, sink) = make()
        model.setDescription(sink.content.style.visualDescription)
        model.setNegativeGuidance(sink.content.style.negativeGuidance)
        #expect(sink.commands.isEmpty)
    }

    @Test func addAndRemoveReferences() {
        let (model, sink) = make()
        model.addReferences([Fixtures.ref])
        guard case let .setStyleVisual(v)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(v.styleReferences == [Fixtures.ref])
        sink.content.style.styleReferences = [Fixtures.ref]
        model.addReferences([Fixtures.ref])  // already there
        #expect(sink.commands.count == 1)
        model.removeReference(Fixtures.ref)
        guard case let .setStyleVisual(w)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(w.styleReferences.isEmpty)
    }

    @Test func marginsAreSetInInchesOnAllEdges() {
        let (model, sink) = make()
        model.setMargins(inches: 0.75)
        guard case let .setPageSetup(setup)? = sink.commands.first else { Issue.record("no command"); return }
        #expect(setup.margins == EdgeInsetsPt(all: 54))
        #expect(setup.trimSize == sink.content.style.pageSetup.trimSize)
    }

    @Test func marginsAreCapped() {
        let (model, sink) = make()
        model.setMargins(inches: 100)
        guard case let .setPageSetup(setup)? = sink.commands.first else { Issue.record("no command"); return }
        #expect(setup.margins.top == 612 / 3)
    }

    @Test func bleedToggleAndAmount() {
        let (model, sink) = make()
        model.setBleedEnabled(true)
        guard case let .setPageSetup(on)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(on.bleedEnabled)
        sink.content.style.pageSetup = on
        model.setBleedAmount(inches: 0.25)
        guard case let .setPageSetup(amount)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(amount.bleedAmount == 18)
        model.setBleedAmount(inches: 0)  // ignored
        model.setBleedEnabled(true)  // unchanged
        #expect(sink.commands.count == 2)
    }


    @Test(.enabled(if: styleModelReady)) func namedOrientationPresetsKeepTheirOrientation() {
        let (model, sink) = make()
        model.setSizePreset(.tenByEight)
        guard case let .setPageSetup(wide)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(wide.orientation == .landscape)
        #expect(wide.trimSize == PointSize(width: 720, height: 576))
        sink.content.style.pageSetup = wide
        model.setSizePreset(.eightByTen)
        guard case let .setPageSetup(tall)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(tall.orientation == .portrait)
        #expect(tall.trimSize == PointSize(width: 576, height: 720))
    }

    @Test func emptyAssetListTitlesFollowTheFilter() {
        #expect(AssetEditing.emptyListTitle(filter: nil) == "No Assets")
        #expect(AssetEditing.emptyListTitle(filter: .character) == "No Characters")
        #expect(AssetEditing.emptyListTitle(filter: .place) == "No Places")
    }

    @Test(.enabled(if: styleModelReady)) func sizePresetAndOrientation() {
        let (model, sink) = make()
        model.setSizePreset(.square8)
        guard case let .setPageSetup(sq)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(sq.sizePreset == .square8)
        #expect(sq.orientation == .square)
        sink.content.style.pageSetup = sq
        #expect(model.isSquare)
        model.setOrientation(.landscape)  // not allowed for squares
        #expect(sink.commands.count == 1)

        sink.content.style.pageSetup = PageSetup.letterPortrait
        model.setOrientation(.landscape)
        guard case let .setPageSetup(land)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(land.orientation == .landscape)
        #expect(land.trimSize == PointSize(width: 792, height: 612))
    }

    @Test(.enabled(if: styleModelReady)) func customSizeInInches() {
        let (model, sink) = make()
        model.setSizePreset(.custom)
        guard case let .setPageSetup(custom)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(custom.sizePreset == .custom)
        sink.content.style.pageSetup = custom
        model.setCustomSize(widthInches: 7)
        guard case let .setPageSetup(seven)? = sink.commands.last else { Issue.record("no command"); return }
        #expect(seven.trimSize == PointSize(width: 504, height: 792))
    }
}

/// The size tests go through `PageSetup.applying`, which the model lane implements.
private let styleModelReady = PageSizePreset.usLetter.baseSize != nil
