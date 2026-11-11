import BBAI
import BBAICore
import BBModel
import BBStore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BBUI

/// Phase 10 asset commands, asset deletion, deliveries into asset sessions, Mark as OK with
/// asset revisions, and the document's usage index under edits and undo.
@MainActor
struct AssetCommandTests {
    struct Setup {
        var document: BookDocument
        var undo: UndoManager
        var url: URL
    }

    func makeDocument(pages: Int = 2) throws -> Setup {
        let content = Fixtures.book(pages: pages)
        let url = FileManager.default.temporaryDirectory.appending(path: "Assets-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url, debounce: .milliseconds(20)))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        return Setup(document: document, undo: undo, url: url)
    }

    @discardableResult
    func perform(_ s: Setup, _ command: BookCommand) -> Bool {
        s.undo.beginUndoGrouping()
        let ok = s.document.perform(command)
        s.undo.endUndoGrouping()
        return ok
    }

    func addPip(_ s: Setup) -> Asset {
        let pip = Asset.makeNew(type: .character, name: "Pip")
        #expect(perform(s, .addAsset(pip)))
        return s.document.content.assets[pip.id]!
    }

    func version(provenance: Provenance? = nil) -> Version {
        Version(image: Fixtures.ref, pixelSize: PixelSize(width: 1024, height: 1024),
                source: provenance == nil ? .imported : .generated, createdAt: Fixtures.date, provenance: provenance)
    }

    /// Appends a version to a session irreversibly (as a delivery would, without choosing).
    func append(_ version: Version, to session: SessionID, in doc: BookDocument) {
        doc.performIrreversible { content in
            content.sessions[session]?.versions.append(version)
            return DirtySet(sessions: [session])
        }
    }

    // MARK: addAsset

    @Test func addAsset_createsItsSession_andUndoRedo() throws {
        let s = try makeDocument()
        let pip = addPip(s)
        #expect(s.document.content.sessions[pip.sessionID]?.owner == .asset(pip.id))
        #expect(s.undo.undoActionName == "New Asset")

        s.undo.undo()
        #expect(s.document.content.assets[pip.id] == nil)
        // The session stays behind as an orphan (created irreversibly).
        #expect(s.document.content.sessions[pip.sessionID] != nil)
        s.undo.redo()
        #expect(s.document.content.assets[pip.id] == pip)
        // Adding the same ID again is ignored.
        #expect(!s.document.perform(.addAsset(pip)))
    }

    @Test func addAsset_isSaved() async throws {
        let s = try makeDocument()
        let pip = addPip(s)
        await s.document.flush()
        let loaded = try await BookStore(packageURL: s.url).load()
        #expect(loaded.assets[pip.id] == pip)
    }

    // MARK: updateAsset

    @Test func updateAsset_renameDoesNotBumpRevision_undoRedo() throws {
        let s = try makeDocument()
        var pip = addPip(s)
        pip.name = "Pippa"
        #expect(perform(s, .updateAsset(pip, actionName: "Rename Asset")))
        #expect(s.undo.undoActionName == "Rename Asset")
        #expect(s.document.content.assets[pip.id]?.name == "Pippa")
        #expect(s.document.content.assets[pip.id]?.revision == 1)
        s.undo.undo()
        #expect(s.document.content.assets[pip.id]?.name == "Pip")
        s.undo.redo()
        #expect(s.document.content.assets[pip.id]?.name == "Pippa")
        // No change: no undo step.
        #expect(!s.document.perform(.updateAsset(s.document.content.assets[pip.id]!, actionName: "Rename Asset")))
    }

    @Test func updateAsset_descriptionBumpsRevision_undoRestores_highWaterKept() throws {
        let s = try makeDocument()
        var pip = addPip(s)
        pip.description = "A small red fox"
        perform(s, .updateAsset(pip, actionName: "Edit Description"))
        #expect(s.document.content.assets[pip.id]?.revision == 2)

        s.undo.undo()
        let restored = try #require(s.document.content.assets[pip.id])
        #expect(restored.revision == 1)
        #expect(restored.description == "")
        #expect(restored.revisionHighWater == 2)

        s.undo.redo()
        #expect(s.document.content.assets[pip.id]?.revision == 2)
        s.undo.undo()

        // A different edit after the undo never reuses revision 2.
        var other = try #require(s.document.content.assets[pip.id])
        other.description = "A sleepy fox"
        perform(s, .updateAsset(other, actionName: "Edit Description"))
        #expect(s.document.content.assets[pip.id]?.revision == 3)
    }

    @Test func updateAsset_ignoresTypeAndSessionChange() throws {
        let s = try makeDocument()
        var pip = addPip(s)
        pip.type = .object
        pip.name = "Pip the fox"
        pip.sessionID = SessionID()
        perform(s, .updateAsset(pip, actionName: "Edit Asset"))
        let stored = try #require(s.document.content.assets[pip.id])
        #expect(stored.type == .character)
        #expect(stored.name == "Pip the fox")
        #expect(stored.sessionID == s.document.content.assets[pip.id]?.sessionID)
        #expect(s.document.content.sessions[stored.sessionID]?.owner == .asset(pip.id))
    }

    @Test func legacyAssetWithoutSession_getsOneOnEditMessageOrImport() async throws {
        // A legacy book: the asset decodes with a sessionID that has no session behind it.
        var content = Fixtures.book(pages: 1)
        let pip = Asset.makeNew(type: .character, name: "Pip")
        content.assets[pip.id] = pip
        let url = FileManager.default.temporaryDirectory.appending(path: "Legacy-\(UUID().uuidString).bookbook")
        try BookStore.create(content, at: url)
        let document = BookDocument(content: content, store: BookStore(packageURL: url, debounce: .milliseconds(20)))
        #expect(document.content.sessions[pip.sessionID] == nil)
        #expect(document.session(for: pip.owner) == nil)

        // The first prompt creates it.
        let item = pending(.asset(pip.id), in: document)
        let session = try #require(document.content.sessions[pip.sessionID])
        #expect(session.owner == .asset(pip.id))
        #expect(session.messages.first?.queueItemID == item.id)

        // An import into a second legacy asset creates it too.
        let wood = Asset.makeNew(type: .place, name: "Wood")
        document.performIrreversible { content in
            content.assets[wood.id] = wood
            return DirtySet(assets: [wood.id])
        }
        let file = try writeJPEG(camera: false)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = try await document.importAssetImage(from: file, owner: wood.owner, depictsRealPerson: false)
        #expect(document.content.sessions[wood.sessionID]?.version(id) != nil)
        #expect(document.content.assets[wood.id]?.chosen == id)

        // And an undoable edit of a third.
        let hat = Asset.makeNew(type: .object, name: "Hat")
        document.performIrreversible { content in
            content.assets[hat.id] = hat
            return DirtySet(assets: [hat.id])
        }
        var renamed = hat
        renamed.name = "Top Hat"
        #expect(document.perform(.updateAsset(renamed, actionName: "Rename Asset")))
        #expect(document.content.sessions[hat.sessionID]?.owner == .asset(hat.id))
    }

    @Test func chooseAssetImage_isUndoable_andBumpsRevision() throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let v1 = version(), v2 = version()
        append(v1, to: pip.sessionID, in: s.document)
        append(v2, to: pip.sessionID, in: s.document)

        s.undo.beginUndoGrouping()
        #expect(s.document.chooseAssetImage(v1.id, for: pip.id))
        s.undo.endUndoGrouping()
        #expect(s.undo.undoActionName == "Choose Image")
        #expect(s.document.content.assets[pip.id]?.chosen == v1.id)
        #expect(s.document.content.assets[pip.id]?.revision == 2)
        #expect(s.document.chosenVersion(for: pip.owner) == v1.id)
        #expect(SessionPanelState.placedVersion(for: pip.owner, in: s.document.content) == v1.id)
        // Choosing it again is no change; a version from elsewhere is refused.
        #expect(!s.document.chooseAssetImage(v1.id, for: pip.id))
        #expect(!s.document.chooseAssetImage(VersionID(), for: pip.id))

        s.undo.beginUndoGrouping()
        #expect(s.document.chooseAssetImage(v2.id, for: pip.id))
        s.undo.endUndoGrouping()
        #expect(s.document.content.assets[pip.id]?.chosen == v2.id)
        #expect(s.document.content.assets[pip.id]?.revision == 3)

        s.undo.undo()
        #expect(s.document.content.assets[pip.id]?.chosen == v1.id)
        #expect(s.document.content.assets[pip.id]?.revision == 2)
        s.undo.undo()
        #expect(s.document.content.assets[pip.id]?.chosen == nil)
        #expect(s.document.content.assets[pip.id]?.revision == 1)
        #expect(s.document.content.assets[pip.id]?.revisionHighWater == 3)
        s.undo.redo()
        #expect(s.document.content.assets[pip.id]?.chosen == v1.id)
        #expect(s.document.content.assets[pip.id]?.revision == 2)
    }

    @Test func undoRename_keepsAChoiceADeliveryMadeSince() throws {
        let s = try makeDocument()
        var pip = addPip(s)
        pip.name = "Pippa"
        perform(s, .updateAsset(pip, actionName: "Rename Asset"))
        // A delivery arrives and chooses the image (irreversible).
        let delivered = version()
        s.document.performIrreversible { content in
            content.sessions[pip.sessionID]?.versions.append(delivered)
            _ = BookMutations.chooseIfUnset(delivered.id, session: pip.sessionID, in: &content)
            return DirtySet(sessions: [pip.sessionID], assets: [pip.id])
        }
        #expect(s.document.content.assets[pip.id]?.revision == 2)
        s.undo.undo()
        let after = try #require(s.document.content.assets[pip.id])
        #expect(after.name == "Pip")
        #expect(after.chosen == delivered.id)
        #expect(after.revision == 2)
    }

    // MARK: setAssetChecklist

    @Test func setAssetChecklist_undoRedo_dropsUnknownAndDuplicates() throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let oak = Asset.makeNew(type: .place, name: "Granny Oak")
        perform(s, .addAsset(oak))
        let page = Fixtures.firstPage(s.document.content)
        #expect(perform(s, .setAssetChecklist(page: page, [oak.id, AssetID(), pip.id, oak.id])))
        #expect(s.document.content.pages[page]?.assetChecklist == [oak.id, pip.id])
        #expect(s.undo.undoActionName == "Change Asset Checklist")
        #expect(!s.document.perform(.setAssetChecklist(page: page, [oak.id, pip.id])))
        s.undo.undo()
        #expect(s.document.content.pages[page]?.assetChecklist == [])
        s.undo.redo()
        #expect(s.document.content.pages[page]?.assetChecklist == [oak.id, pip.id])
    }

    // MARK: deleteAsset

    @Test func deleteAsset_clearsChecklists_mentionsBecomeNames_fileRemoved_sessionsKept() async throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let page = Fixtures.firstPage(s.document.content)
        perform(s, .setAssetChecklist(page: page, [pip.id]))
        let boxSession = try #require(s.document.content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        let message = Message(role: .user, text: "\(MentionText.token(for: pip.id)) yawning by the fire",
                              createdAt: Fixtures.date)
        s.document.performIrreversible { content in
            content.sessions[boxSession]?.messages.append(message)
            return DirtySet(sessions: [boxSession])
        }
        await s.document.flush()
        #expect(try await BookStore(packageURL: s.url).load().assets[pip.id] != nil)

        #expect(s.document.deleteAsset(pip.id))
        let content = s.document.content
        #expect(content.assets[pip.id] == nil)
        #expect(content.pages[page]?.assetChecklist == [])
        #expect(content.sessions[boxSession]?.messages.first?.text == "Pip yawning by the fire")
        #expect(content.sessions[pip.sessionID] != nil)
        #expect(s.document.usageSites(of: pip.id).isEmpty)

        await s.document.flush()
        #expect(try await BookStore(packageURL: s.url).load().assets[pip.id] == nil)

        // Undo can't resurrect it or its checklist entry.
        s.undo.undo() // the checklist edit
        #expect(s.document.content.pages[page]?.assetChecklist == [])
        s.undo.undo() // the add
        #expect(s.document.content.assets[pip.id] == nil)
        #expect(!s.document.deleteAsset(pip.id))
    }

    @Test func deleteAsset_rewritesProvenanceIntents_andSendTextKeepsTheName() async throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let page = Fixtures.firstPage(s.document.content)
        let boxSession = try #require(s.document.content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        let text = "\(MentionText.token(for: pip.id)) yawning"
        let intent = GenerationIntent(messageText: text, provider: .openai, model: "gpt-image-2.5-sunburst", quality: .draft)
        var provenance = Fixtures.provenance()
        provenance.intent = intent
        append(version(provenance: provenance), to: boxSession, in: s.document)
        // A queued item: its message is pending in the session, its intent still holds the token.
        let target = GenerationTarget.pageBox(page, Fixtures.imageBox.id)
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: s.document.id, target: target,
                                                           now: Fixtures.date)
        s.document.performIrreversible { BookMutations.appendPendingMessage(message, target: target, to: &$0) }

        #expect(s.document.deleteAsset(pip.id))
        let content = s.document.content
        let stored = try #require(content.sessions[boxSession]?.versions.last?.provenance?.intent.messageText)
        #expect(stored == "Pip yawning")
        #expect(!stored.contains(MentionText.token(for: pip.id)))
        // The queued intent still has the token, but the send text keeps the name.
        #expect(item.intent.messageText == text)
        let shown = ContextAssembler.requestDisplayText(intent: item.intent, messageID: item.messageID, content: content)
        #expect(shown == "Pip yawning")
        // Without the answered message there is nothing to fall back to.
        #expect(ContextAssembler.requestDisplayText(intent: item.intent, messageID: nil, content: content) == " yawning")
    }

    @Test func queueThenDeleteThenDeliver_provenanceKeepsTheNameNotTheToken() throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let page = Fixtures.firstPage(s.document.content)
        let target = GenerationTarget.pageBox(page, Fixtures.imageBox.id)
        let intent = GenerationIntent(messageText: "\(MentionText.token(for: pip.id)) in the park", provider: .openai,
                                      model: "gpt-image-2.5-sunburst", quality: .draft)
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: s.document.id, target: target,
                                                           now: Fixtures.date)
        s.document.performIrreversible { BookMutations.appendPendingMessage(message, target: target, to: &$0) }
        #expect(s.document.deleteAsset(pip.id))

        var provenance = Fixtures.provenance()
        provenance.intent = item.intent
        let result = ImageResult(imageData: Data([1]), contentType: "public.png",
                                 pixelSize: PixelSize(width: 1024, height: 1024))
        s.document.performIrreversible { content in
            BookMutations.applyDelivery(
                GenerationDelivery(item: item, outcome: .success(result: result, provenance: provenance)),
                storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        }
        let session = try #require(s.document.content.session(containing: item.messageID))
        let text = try #require(session.versions.last?.provenance?.intent.messageText)
        #expect(text == "Pip in the park")
        #expect(MentionText.mentionedAssets(in: text).isEmpty)
    }

    // MARK: Deliveries into asset sessions

    func pending(_ target: GenerationTarget, in doc: BookDocument) -> QueueItem {
        let intent = GenerationIntent(messageText: "Reference image of Pip", provider: .openai,
                                      model: "gpt-image-2.5-sunburst", quality: .draft)
        let (message, item) = BookMutations.makeGeneration(intent: intent, bookID: doc.id, target: target,
                                                           now: Fixtures.date)
        doc.performIrreversible { BookMutations.appendPendingMessage(message, target: target, to: &$0) }
        return item
    }

    @Test func delivery_writesVersionIntoAssetSession_andChoosesWhenUnset() throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let item = pending(.asset(pip.id), in: s.document)
        #expect(s.document.content.sessions[pip.sessionID]?.messages.first?.queueItemID == item.id)

        let first = VersionID()
        s.document.performIrreversible { content in
            BookMutations.applyDelivery(GenerationDelivery(item: item, outcome: .success(result: Fixtures.result(),
                                                                                         provenance: Fixtures.provenance())),
                                        storedImage: Fixtures.ref, to: &content, versionID: first, now: Fixtures.date)
        }
        var asset = try #require(s.document.content.assets[pip.id])
        let session = try #require(s.document.content.sessions[pip.sessionID])
        #expect(session.versions.map(\.id) == [first])
        #expect(session.messages.first?.producedVersion == first)
        #expect(session.messages.first?.queueItemID == nil)
        #expect(asset.chosen == first)
        #expect(asset.revision == 2)

        // A second delivery doesn't replace the choice.
        let item2 = pending(.asset(pip.id), in: s.document)
        s.document.performIrreversible { content in
            BookMutations.applyDelivery(GenerationDelivery(item: item2, outcome: .success(result: Fixtures.result(),
                                                                                          provenance: Fixtures.provenance())),
                                        storedImage: Fixtures.ref, to: &content, now: Fixtures.date)
        }
        asset = try #require(s.document.content.assets[pip.id])
        #expect(asset.chosen == first)
        #expect(asset.revision == 2)
        #expect(s.document.content.sessions[pip.sessionID]?.versions.count == 2)
    }

    @Test func failedDelivery_clearsPendingOnly() throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let failed = pending(.asset(pip.id), in: s.document)
        s.document.performIrreversible { content in
            BookMutations.applyDelivery(GenerationDelivery(item: failed, outcome: .failure(.offline)),
                                        storedImage: nil, to: &content, now: Fixtures.date)
        }
        #expect(s.document.content.sessions[pip.sessionID]?.messages.first?.queueItemID == nil)
        #expect(s.document.content.sessions[pip.sessionID]?.versions.isEmpty == true)
        #expect(s.document.content.assets[pip.id]?.chosen == nil)
        #expect(s.document.content.assets[pip.id]?.revision == 1)
    }

    @Test func deletingTheChosenVersion_clearsTheChoice() throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let v = version()
        s.document.performIrreversible { content in
            content.sessions[pip.sessionID]?.versions.append(v)
            _ = BookMutations.chooseIfUnset(v.id, session: pip.sessionID, in: &content)
            return DirtySet(sessions: [pip.sessionID], assets: [pip.id])
        }
        #expect(s.document.deleteVersion(v.id, owner: pip.owner))
        #expect(s.document.content.assets[pip.id]?.chosen == nil)
        #expect(s.document.content.assets[pip.id]?.revision == 3)
    }

    // MARK: Mark as OK

    @Test func markFlagsOK_acknowledgesCurrentAssetRevisions() throws {
        let s = try makeDocument()
        var pip = addPip(s)
        let page = Fixtures.firstPage(s.document.content)
        var provenance = Fixtures.provenance()
        provenance.assetRevisions = [pip.id: 1]
        let v = version(provenance: provenance)
        let sessionID = try #require(s.document.content.pages[page]?.images[Fixtures.imageBox.id]?.sessionID)
        append(v, to: sessionID, in: s.document)
        perform(s, .chooseVersion(page: page, box: Fixtures.imageBox.id, version: v.id))
        #expect(!s.document.content.imageFlags(page: page, box: Fixtures.imageBox.id).contains(.assetChanged))

        pip.description = "Now with a scarf"
        perform(s, .updateAsset(pip, actionName: "Edit Description"))
        #expect(s.document.content.imageFlags(page: page, box: Fixtures.imageBox.id).contains(.assetChanged))

        #expect(perform(s, .markFlagsOK(page: page, box: Fixtures.imageBox.id)))
        #expect(s.document.content.pages[page]?.images[Fixtures.imageBox.id]?.acknowledged.assetRevisions == [pip.id: 2])
        #expect(!s.document.content.imageFlags(page: page, box: Fixtures.imageBox.id).contains(.assetChanged))
        s.undo.undo()
        #expect(s.document.content.imageFlags(page: page, box: Fixtures.imageBox.id).contains(.assetChanged))
    }

    // MARK: Usage index

    @Test func usageIndex_followsChecklistMentionsPlacementAndUndo() throws {
        let s = try makeDocument(pages: 2)
        let pip = addPip(s)
        let content = s.document.content
        let page1 = content.book.pageOrder[0], page2 = content.book.pageOrder[1]
        #expect(s.document.usageSites(of: pip.id).isEmpty)

        perform(s, .setAssetChecklist(page: page2, [pip.id]))
        #expect(s.document.usageSites(of: pip.id) == [UsageSite(page: page2, box: nil, reasons: [.checklist])])

        // A mention in a box session (as a Generate press appends it).
        let box = Fixtures.imageBox.id
        let message = Message(role: .user, text: "\(MentionText.token(for: pip.id)) by the fire", createdAt: Fixtures.date)
        s.document.performIrreversible { BookMutations.appendPendingMessage(message, target: .pageBox(page1, box), to: &$0) }
        #expect(s.document.usageSites(of: pip.id).map(\.page) == [page1, page2])
        #expect(s.document.usageSites(of: pip.id).first == UsageSite(page: page1, box: box, reasons: [.mention]))

        // Deleting the page drops its sites; undo brings them back.
        perform(s, .deletePage(page1))
        #expect(s.document.usageSites(of: pip.id).map(\.page) == [page2])
        s.undo.undo()
        #expect(s.document.usageSites(of: pip.id).map(\.page) == [page1, page2])

        // Undoing the checklist edit drops the page-level site.
        s.undo.undo()
        #expect(s.document.usageSites(of: pip.id).map(\.page) == [page1])
        // Matches a freshly built index.
        #expect(s.document.usageIndex == UsageIndex(content: s.document.content))

        // Resetting the session hides the mention.
        s.document.resetSession(page: page1, box: box, keepVersions: true)
        #expect(s.document.usageSites(of: pip.id).isEmpty)
    }

    // MARK: Import into asset sessions

    @Test func importAssetImage_storesTheAnswer_andChoosesWhenUnset() async throws {
        let s = try makeDocument()
        let pip = addPip(s)
        let file = try writeJPEG(camera: false)
        let photo = try writeJPEG(camera: true)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: photo)
        }

        let id = try await s.document.importAssetImage(from: file, owner: pip.owner, depictsRealPerson: true)
        let v = try #require(s.document.content.sessions[pip.sessionID]?.version(id))
        #expect(v.depictsRealPerson == true)
        #expect(v.source == .imported)
        #expect(s.document.content.assets[pip.id]?.chosen == id)
        #expect(await BookDocument.looksCameraOriginated(file) == false)
        #expect(await BookDocument.looksCameraOriginated(photo) == true)

        await #expect(throws: ImageImportFailure.assetGone) {
            try await s.document.importAssetImage(from: file, owner: .asset(AssetID()), depictsRealPerson: false)
        }
    }

    /// A small JPEG, with a camera make and model in its metadata when `camera`.
    func writeJPEG(camera: Bool) throws -> URL {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = camera
            ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"]]
            : [:]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let url = FileManager.default.temporaryDirectory.appending(path: "asset-\(UUID().uuidString).jpg")
        try (data as Data).write(to: url)
        return url
    }

    @Test func looksCameraOriginated_readsMakeModelOrCaptureDate() {
        typealias P = [CFString: Any]
        #expect(!BookDocument.looksCameraOriginated(properties: [:]))
        #expect(BookDocument.looksCameraOriginated(properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple"] as P]))
        #expect(BookDocument.looksCameraOriginated(properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 17"] as P]))
        #expect(BookDocument.looksCameraOriginated(properties: [kCGImagePropertyExifDictionary:
                                                                    [kCGImagePropertyExifDateTimeOriginal: "2026:05:01 10:00:00"] as P]))
        #expect(!BookDocument.looksCameraOriginated(properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: " "] as P]))
    }
}
