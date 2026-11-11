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

    @MainActor @Test func deletingTheSelectedAssetClearsTheSelection() {
        var content = Fixtures.book(pages: 1)
        let wood = Asset.makeNew(type: .place, name: "Wood")
        content.assets[wood.id] = wood
        let model = AssetsModel()
        model.select(wood)
        #expect(model.selectedAsset == wood.id)
        content.assets[wood.id] = nil
        model.validate(content)
        #expect(model.selectedAsset == nil)
    }

    @Test func descriptionHelpNamesTheAsset() {
        let pip = Asset.makeNew(type: .character, name: "Pip")
        #expect(AssetEditing.descriptionHelp(for: pip).contains("Pip"))
        #expect(AssetEditing.emptyImageMessage(for: pip).contains("Generate"))
    }

    // MARK: Generate from the description

    @Test func generateTitleAndPrompt() {
        #expect(AssetGeneration.buttonTitle(hasImage: false) == "Generate")
        #expect(AssetGeneration.buttonTitle(hasImage: true) == "Regenerate")
        #expect(AssetGeneration.prompt(from: "  a green frog \n") == "a green frog")
        #expect(AssetGeneration.prompt(from: " \n ").isEmpty)
    }

    @Test func generateIsAlwaysAFreshImage() {
        let base = GenerationIntent(messageText: "a frog", refines: VersionID(),
                                    attachedReferences: [VersionRef(sessionID: SessionID(), versionID: VersionID())],
                                    provider: .openai, model: "m", quality: .draft, includeStoryText: true,
                                    checkConsistency: true)
        let intent = AssetGeneration.intent(base)
        #expect(intent.refines == nil)
        #expect(intent.attachedReferences.isEmpty)
        #expect(intent.includeStoryText == false)
        #expect(intent.checkConsistency == false)
        #expect(intent.messageText == "a frog" && intent.quality == .draft && intent.model == "m")
    }

    @Test func latestRequestAndBusy() {
        let pip = Asset.makeNew(type: .character, name: "Pip")
        #expect(AssetGeneration.latestRequest(in: nil) == nil)
        let old = Message(role: .user, text: "first", createdAt: Fixtures.date)
        let new = Message(role: .user, text: "second", createdAt: Fixtures.date)
        let session = Session(id: pip.sessionID, owner: pip.owner, messages: [old, new])
        #expect(AssetGeneration.latestRequest(in: session)?.id == new.id)
        #expect(AssetGeneration.isBusy(.waiting))
        #expect(AssetGeneration.isBusy(.running(startedAt: Fixtures.date, typicalSeconds: nil)))
        #expect(!AssetGeneration.isBusy(.none))
        #expect(!AssetGeneration.isBusy(.produced(VersionID())))
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
