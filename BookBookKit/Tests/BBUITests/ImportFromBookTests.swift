import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

/// Phase 16 Import from Book: the `.importFromBook` command (undo/redo, independence) and the
/// sheet's model end to end between two real books on disk.
@MainActor
struct ImportFromBookTests {
    struct Books {
        var dir: URL
        var sourceURL: URL
        var sourceStore: BookStore
        var source: BookContent
        var document: BookDocument
        var undo: UndoManager
    }

    func makeBooks() async throws -> Books {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var source = Fixtures.book()
        let sourceURL = dir.appending(path: "Source.bookbook", directoryHint: .isDirectory)
        try BookStore.create(source, at: sourceURL)
        let sourceStore = BookStore(packageURL: sourceURL)

        var pip = Asset.makeNew(type: .character, name: "Pip")
        pip.description = "A small fox"
        let slot = try #require(pip.references.first { $0.isPrimary })
        var session = Session(id: slot.sessionID, owner: .assetReference(pip.id, slot.id))
        let ref = try await sourceStore.storeImage(Data("pip-image".utf8), contentType: "public.png")
        let version = Version(image: ref, pixelSize: PixelSize(width: 8, height: 8), source: .generated, createdAt: Fixtures.date)
        session.versions.append(version)
        if let i = pip.references.firstIndex(where: { $0.id == slot.id }) { pip.references[i].chosen = version.id }
        source.sessions[session.id] = session
        source.assets[pip.id] = pip
        var template = Fixtures.storyTemplate
        template.id = TemplateID()
        template.name = "Source Layout"
        source.templates[template.id] = template
        source.style.visualDescription = "soft watercolour"
        try await sourceStore.save(source, dirty: .all(source))

        let target = Fixtures.book()
        let targetURL = dir.appending(path: "Target.bookbook", directoryHint: .isDirectory)
        try BookStore.create(target, at: targetURL)
        let document = BookDocument(content: target, store: BookStore(packageURL: targetURL, debounce: .milliseconds(20)))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo
        undo.groupsByEvent = true
        return Books(dir: dir, sourceURL: sourceURL, sourceStore: sourceStore, source: source, document: document, undo: undo)
    }

    func perform(_ b: Books, _ command: BookCommand) -> Bool {
        b.undo.beginUndoGrouping()
        defer { b.undo.endUndoGrouping() }
        return b.document.perform(command)
    }

    @Test func commandAddsThenUndoRemovesAndRedoReadds() throws {
        var target = Fixtures.book()
        target.style.visualDescription = "old style"
        let setup = target.style.pageSetup
        let url = FileManager.default.temporaryDirectory.appending(path: "x-\(UUID().uuidString).bookbook")
        let document = BookDocument(content: target, store: BookStore(packageURL: url))
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManager = undo

        let pip = Asset.makeNew(type: .character, name: "Pip")
        let slot = try #require(pip.references.first)
        let imported = Session(id: slot.sessionID, owner: .assetReference(pip.id, slot.id))
        var template = Fixtures.storyTemplate
        template.id = TemplateID()
        var guide = Fixtures.book().style
        guide.visualDescription = "new style"
        guide.pageSetup.bleedAmount = 99
        let item = BookImport(assets: [pip], sessions: [imported], templates: [template], styleGuide: guide, images: [])

        let oldStyle = document.content.style
        undo.beginUndoGrouping()
        #expect(document.perform(.importFromBook(item)))
        undo.endUndoGrouping()
        #expect(document.content.assets[pip.id] != nil)
        #expect(document.content.sessions[slot.sessionID] != nil)
        #expect(document.content.templates[template.id] != nil)
        #expect(document.content.style.visualDescription == "new style")
        #expect(document.content.style.pageSetup == setup)
        #expect(document.content.style.visualRevision > oldStyle.visualRevision)
        #expect(undo.undoActionName == "Import from Book")

        undo.undo()
        #expect(document.content.assets[pip.id] == nil)
        #expect(document.content.templates[template.id] == nil)
        #expect(document.content.style == oldStyle)

        undo.redo()
        #expect(document.content.assets[pip.id] != nil)
        #expect(document.content.templates[template.id] != nil)
        #expect(document.content.style.visualDescription == "new style")
    }

    @Test func importIsAnIndependentCopy() async throws {
        let b = try await makeBooks()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let model = ImportFromBookModel(document: b.document)
        await model.loadSource(at: b.sourceURL)
        let pipID = try #require(b.source.assets.keys.first)
        model.selection = BookImportSelection(assets: [pipID], templates: [], styleGuide: false)
        await model.advance()
        #expect(model.isDone)
        let copy = try #require(b.document.content.assets.values.first { $0.name == "Pip" })
        #expect(copy.id != pipID)

        var edited = copy
        edited.description = "changed"
        #expect(perform(b, .updateAsset(edited, actionName: "Edit Description")))
        let reread = try await BookStore(packageURL: b.sourceURL).load()
        #expect(reread.assets[pipID]?.description == "A small fox")
        #expect(b.source.assets[pipID]?.description == "A small fox")
    }

    @Test func endToEndCopiesImagesOnceAndHandlesClashes() async throws {
        let b = try await makeBooks()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let model = ImportFromBookModel(document: b.document)
        await model.loadSource(at: b.sourceURL)
        let pipID = try #require(b.source.assets.keys.first)
        let templateID = try #require(b.source.templates.keys.first { b.source.templates[$0]?.name == "Source Layout" })
        model.selection = BookImportSelection(assets: [pipID], templates: [templateID], styleGuide: true)
        await model.advance()
        #expect(model.isDone)
        #expect(b.document.content.templates.values.contains { $0.name == "Source Layout" })
        #expect(b.document.content.style.visualDescription == "soft watercolour")
        let imagesDir = b.document.store.packageURL.appending(path: "images")
        let first = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path(percentEncoded: false))
        #expect(first.count == 1)

        // Second import: Pip clashes; rename prefilled "Pip 2"; same image bytes are not copied again.
        let again = ImportFromBookModel(document: b.document)
        await again.loadSource(at: b.sourceURL)
        again.selection = BookImportSelection(assets: [pipID])
        await again.advance()
        #expect(again.step == .rename)
        #expect(!again.isDone)
        #expect(again.renames[.asset(pipID)] == "Pip 2")
        #expect(again.canImport)
        again.renames[.asset(pipID)] = "pip"
        #expect(!again.canImport)
        #expect(again.remainingClashes.count == 1)
        again.renames[.asset(pipID)] = "Pip 3"
        #expect(again.canImport)
        await again.advance()
        #expect(again.isDone)
        #expect(b.document.content.assets.values.contains { $0.name == "Pip 3" })
        let second = try FileManager.default.contentsOfDirectory(atPath: imagesDir.path(percentEncoded: false))
        #expect(second.count == 1)
    }

    @Test func readOnlyTargetCannotImport() async throws {
        let b = try await makeBooks()
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let targetURL = b.document.store.packageURL
        let readOnly = try await BookDocument.open(at: targetURL, readOnly: true)
        let model = ImportFromBookModel(document: readOnly)
        await model.loadSource(at: b.sourceURL)
        model.selection = BookImportSelection(assets: Set(b.source.assets.keys))
        #expect(!model.canContinue)
    }
}
