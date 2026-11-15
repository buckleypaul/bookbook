import BBModel
import Foundation
import Testing
@testable import BBUI

/// The session panels' selected version (PD §8.6): what Version details and refinement use.
@Suite struct SessionVersionSelectionTests {
    private static func version() -> Version {
        Version(image: Fixtures.ref, pixelSize: PixelSize(width: 64, height: 48), source: .generated,
                createdAt: Fixtures.date)
    }

    private let v1 = Self.version()
    private let v2 = Self.version()

    private func session(resetEpoch: Int = 0) -> Session {
        Session(owner: .pageBox(PageID(), BoxID()), versions: [v1, v2], resetEpoch: resetEpoch)
    }

    @Test func baseIsThePlacedVersionUntilOneIsChosen() {
        var selection = SessionVersionSelection()
        #expect(selection.base(in: session(), placed: v1.id) == v1.id)
        #expect(selection.base(in: session(), placed: nil) == nil)
        selection.choose(v2.id)
        #expect(selection.base(in: session(), placed: v1.id) == v2.id)
    }

    @Test func noBaseWithoutASessionOrForAVersionThatIsGone() {
        var selection = SessionVersionSelection()
        #expect(selection.base(in: nil, placed: v1.id) == nil)
        // A placed version the session doesn't hold isn't a base.
        #expect(selection.base(in: session(), placed: VersionID()) == nil)
        // A selection that's gone falls back to the placed version.
        selection.choose(VersionID())
        #expect(selection.base(in: session(), placed: v1.id) == v1.id)
    }

    @Test func placedChangedClearsTheSelection() {
        var selection = SessionVersionSelection()
        selection.choose(v2.id)
        selection.placedChanged()
        #expect(selection == SessionVersionSelection())
        #expect(selection.base(in: session(), placed: v1.id) == v1.id)
    }

    @Test func deletedClearsOnlyThatSelection() {
        var selection = SessionVersionSelection()
        selection.choose(v2.id)
        selection.deleted(v1.id)
        #expect(selection.selected == v2.id)
        selection.deleted(v2.id)
        #expect(selection.selected == nil)
    }

    @Test func resetKeepingVersionsLeavesNoBaseUntilAClick() {
        var selection = SessionVersionSelection()
        selection.choose(v2.id)
        let before = session(resetEpoch: 3)
        selection.reset(keepVersions: true, session: before)
        #expect(selection.selected == nil)
        #expect(selection.freshEpoch == 4)
        // The reset session (epoch 4) still places v1, but the thread starts fresh.
        let after = session(resetEpoch: 4)
        #expect(selection.base(in: after, placed: v1.id) == nil)
        // Details still show a version: the newest.
        #expect(selection.detailsVersion(in: after, placed: v1.id)?.id == v2.id)
        // A click picks the base again, placed or not.
        selection.choose(v1.id)
        #expect(selection.freshEpoch == nil)
        #expect(selection.base(in: after, placed: v1.id) == v1.id)
    }

    @Test func resetKeepingVersionsEndsWhenThePlacementMovesOrTheSessionResetsAgain() {
        var selection = SessionVersionSelection()
        selection.reset(keepVersions: true, session: session(resetEpoch: 0))
        #expect(selection.base(in: session(resetEpoch: 1), placed: v1.id) == nil)
        // A later epoch (another reset, made elsewhere) no longer matches.
        #expect(selection.base(in: session(resetEpoch: 2), placed: v1.id) == v1.id)
        selection.placedChanged()
        #expect(selection.base(in: session(resetEpoch: 1), placed: v2.id) == v2.id)
    }

    @Test func resetDiscardingVersionsOrWithoutASessionSetsNoFreshEpoch() {
        var selection = SessionVersionSelection()
        selection.choose(v1.id)
        selection.reset(keepVersions: false, session: session(resetEpoch: 3))
        #expect(selection == SessionVersionSelection())
        selection.reset(keepVersions: true, session: nil)
        #expect(selection == SessionVersionSelection())
    }

    @Test func detailsVersionIsTheBaseElseTheNewest() {
        var selection = SessionVersionSelection()
        #expect(selection.detailsVersion(in: session(), placed: v1.id)?.id == v1.id)
        #expect(selection.detailsVersion(in: session(), placed: nil)?.id == v2.id)
        selection.choose(v2.id)
        #expect(selection.detailsVersion(in: session(), placed: v1.id)?.id == v2.id)
        let empty = Session(owner: .pageBox(PageID(), BoxID()))
        #expect(selection.detailsVersion(in: empty, placed: nil) == nil)
    }

    @Test func deleteTitleNamesTheVersionNumber() {
        #expect(SessionPanelState.deleteTitle(v2.id, in: session()) == "Delete version 2?")
        #expect(SessionPanelState.deleteTitle(VersionID(), in: session()) == "Delete this version?")
        #expect(SessionPanelState.deleteTitle(nil, in: session()) == "Delete this version?")
        #expect(SessionPanelState.deleteTitle(v1.id, in: nil) == "Delete this version?")
    }
}
