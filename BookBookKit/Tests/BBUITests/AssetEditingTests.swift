import BBModel
import Foundation
import Testing
@testable import BBUI

struct AssetEditingTests {
    @Test func imageIsTheChosenVersion() {
        var content = Fixtures.book(pages: 1)
        var pip = Asset.makeNew(type: .character, name: "Pip")
        content.assets[pip.id] = pip
        #expect(AssetEditing.image(of: pip, in: content) == nil, "no session yet")
        let version = Version(image: Fixtures.ref, pixelSize: PixelSize(width: 8, height: 8), source: .generated,
                              createdAt: Fixtures.date)
        content.sessions[pip.sessionID] = Session(id: pip.sessionID, owner: pip.owner, versions: [version])
        #expect(AssetEditing.thumbnail(of: pip, in: content) == nil, "nothing chosen")
        pip.chosen = version.id
        #expect(AssetEditing.image(of: pip, in: content) == Fixtures.ref)
        #expect(AssetEditing.thumbnail(of: pip, in: content) == Fixtures.ref)
        pip.chosen = VersionID()
        #expect(AssetEditing.image(of: pip, in: content) == nil, "a gone version shows the placeholder")
        #expect(AssetEditing.emptyImageMessage(for: pip).contains("Pip"))
    }

    @MainActor @Test func selectingAnAssetShowsItsSession() {
        var content = Fixtures.book(pages: 1)
        let pip = Asset.makeNew(type: .character, name: "Pip")
        let wood = Asset.makeNew(type: .place, name: "Wood")
        content.assets[pip.id] = pip
        content.assets[wood.id] = wood
        let model = AssetsModel()
        #expect(model.sessionOwner(in: content) == nil, "no asset selected: the empty state")
        model.requestImport()
        #expect(model.importRequest == nil)

        model.select(pip)
        #expect(model.sessionOwner(in: content) == .asset(pip.id))
        model.requestImport()
        #expect(model.importRequest == .asset(pip.id))
        model.select(wood)
        #expect(model.sessionOwner(in: content) == .asset(wood.id))
        #expect(model.importRequest == nil, "a pending import doesn't follow the selection")

        content.assets[wood.id] = nil
        #expect(model.sessionOwner(in: content) == nil)
        model.validate(content)
        #expect(model.selectedAsset == nil)
    }

    @Test func panelCopesWithAMissingAssetSession() {
        var content = Fixtures.book(pages: 1)
        let pip = Asset.makeNew(type: .character, name: "Pip")
        content.assets[pip.id] = pip
        // A legacy asset: its sessionID has no session behind it.
        let stand = SessionPanelState.session(for: pip.owner, in: content)
        #expect(stand?.id == pip.sessionID && stand?.owner == pip.owner && stand?.versions.isEmpty == true)
        #expect(SessionPanelState.placedVersion(for: pip.owner, in: content) == nil)
        // A gone asset or box has no session.
        #expect(SessionPanelState.session(for: .asset(AssetID()), in: content) == nil)
        #expect(SessionPanelState.session(for: .pageBox(PageID(), BoxID()), in: content) == nil)
    }

    @Test func tags() {
        #expect(AssetEditing.parseTags(" fox, red ,, Fox,small") == ["fox", "red", "small"])
        #expect(AssetEditing.tagsText(["a", "b"]) == "a, b")
    }

    @Test func listSortedAndFiltered() {
        var content = Fixtures.book(pages: 1)
        for (t, n) in [(AssetType.place, "Wood"), (.character, "pip"), (.character, "Ann")] {
            let a = Asset.makeNew(type: t, name: n)
            content.assets[a.id] = a
        }
        #expect(AssetEditing.list(content, type: nil).map(\.name) == ["Ann", "pip", "Wood"])
        #expect(AssetEditing.list(content, type: .character).map(\.name) == ["Ann", "pip"])
    }

    @Test func whereUsedLabels() {
        let content = Fixtures.book(pages: 2)
        let cover = content.book.coverPageID
        let p2 = content.book.pageOrder[1]
        #expect(WhereUsedText.pageLabel(cover, in: content) == "Cover")
        #expect(WhereUsedText.pageLabel(p2, in: content) == "Page 2")
        let box = content.pages[p2]!.images.keys.first!
        let site = UsageSite(page: p2, box: box, reasons: [.mention, .checklist])
        #expect(WhereUsedText.siteLabel(site, in: content) == "Page 2, image box")
        #expect(WhereUsedText.reasons(site.reasons) == "in the page's asset list, mentioned in a prompt")
        #expect(WhereUsedText.summary([], in: content) == "Not used on any page.")
        #expect(WhereUsedText.summary([site, UsageSite(page: p2, box: nil, reasons: [.checklist])], in: content)
            == "Used on Page 2.")
    }
}
