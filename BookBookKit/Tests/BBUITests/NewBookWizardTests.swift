import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

@MainActor
struct NewBookWizardTests {
    private func makeApp() throws -> (AppModel, UserDefaults, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bbui-wizard-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: "bbui-tests-\(UUID().uuidString)"))
        let app = AppModel(providers: [:], libraryRoot: dir.appending(path: "Library", directoryHint: .isDirectory),
                           keychainService: "app.bookbook.tests-\(UUID())",
                           indexCacheURL: dir.appending(path: "library-index.json"), userDefaults: defaults,
                           thumbnails: ThumbnailCache(root: dir.appending(path: "Caches")),
                           appSupport: AppSupportFiles(folderURL: dir.appending(path: "AppSupport")))
        return (app, defaults, dir)
    }

    @Test func stepsMoveForwardAndBack() {
        let model = NewBookWizardModel(presets: [])
        #expect(model.step == .title && model.isFirst)
        model.next(); model.next(); model.next(); model.next()
        #expect(model.step == .story && model.isLast)
        model.next()
        #expect(model.step == .story)
        model.back()
        #expect(model.step == .character)
    }

    @Test func skippingEveryStepGivesTheDefaultSpec() {
        let model = NewBookWizardModel(importStory: false, presets: [])
        model.title = "Changed"
        for _ in NewBookWizardModel.Step.allCases { model.skip() }
        #expect(model.spec == NewBookSpec(title: ""), "resolvedTitle supplies Untitled")
    }

    @Test func choicesBuildTheSpec() {
        let model = NewBookWizardModel(importStory: true, presets: [])
        model.title = "Wizard"
        model.author = "Me"
        model.pageSize = .a5
        model.orientation = .landscape
        model.stylePresetID = "crayon"
        model.characterName = "Pip"
        model.characterDescription = "A frog."
        let spec = model.spec
        #expect(spec.title == "Wizard" && spec.author == "Me")
        #expect(spec.pageSize == .a5 && spec.orientation == .landscape)
        #expect(spec.stylePresetID == "crayon")
        #expect(spec.mainCharacter == .init(name: "Pip", description: "A frog."))
        #expect(spec.importStoryAfter)
        model.pageSize = .square8
        #expect(model.spec.orientation == .portrait, "square sizes ignore the orientation choice")
        model.characterName = " "
        model.characterDescription = ""
        #expect(model.spec.mainCharacter == nil)
    }

    @Test func tenByEightComesOutLandscapeAndKeepsItsSize() {
        let model = NewBookWizardModel(presets: [])
        model.pageSize = .tenByEight
        #expect(model.orientation == .landscape, "10 × 8 in is landscape by name")
        let spec = model.spec
        #expect(spec.pageSize == .tenByEight && spec.orientation == .landscape)
        let setup = PageSetup.letterPortrait.applying(preset: .tenByEight, orientation: spec.orientation ?? .portrait)
        #expect(setup.trimSize == PointSize(width: 720, height: 576))

        model.pageSize = .eightByTen
        #expect(model.orientation == .portrait)
        model.pageSize = .usLetter
        #expect(model.spec == NewBookSpec(title: ""), "Letter portrait is the default, sent as no choice")
        model.pageSize = .a5
        model.orientation = .landscape
        model.pageSize = .a5
        #expect(model.orientation == .landscape, "choosing the same size again keeps the orientation")
    }

    @Test func landscapeSurvivesAChangeToA4() {
        let model = NewBookWizardModel(presets: [])
        model.orientation = .landscape
        model.pageSize = .a4
        #expect(model.orientation == .landscape)
        #expect(model.spec.orientation == .landscape)
    }

    @Test func titleStartsEmptyAndResolvesToUntitled() {
        let model = NewBookWizardModel(presets: [])
        #expect(model.title.isEmpty)
        #expect(model.spec.resolvedTitle == "Untitled")
    }

    @Test func createBookFromSpecLandsInTheModelAndQueuesStoryImport() async throws {
        let (app, defaults, dir) = try makeApp()
        defer {
            defaults.removePersistentDomain(forName: "unused")
            try? FileManager.default.removeItem(at: dir)
        }
        await app.start()
        let presetID = try #require(try Presets.stylePresets().first).id
        let spec = NewBookSpec(title: "Wizard", author: "Me", pageSize: .a5, orientation: .landscape,
                               stylePresetID: presetID, mainCharacter: .init(name: "Pip", description: "A frog."),
                               importStoryAfter: true)
        let entry = try await app.createBook(spec: spec)
        #expect(app.takePendingStoryImport(for: entry.id))
        let plain = try await app.createBook(spec: NewBookSpec(title: "Plain"))
        #expect(!app.takePendingStoryImport(for: plain.id))

        let document = try await app.openBook(entry.id)
        let content = document.content
        #expect(content.book.title == "Wizard" && content.book.author == "Me")
        #expect(content.style.pageSetup.sizePreset == .a5)
        #expect(content.style.pageSetup.orientation == .landscape)
        #expect(content.style.presetID == presetID)
        let asset = try #require(content.assets.values.first)
        #expect(asset.type == .character && asset.name == "Pip" && asset.description == "A frog.")
        #expect(content.sessions[asset.sessionID]?.owner == asset.owner)
        let undo = UndoManager()
        document.undoManager = undo
        #expect(!undo.canUndo, "creation is not an undoable edit")
    }

    @Test func sampleBookOpensWithoutKeyAndSecondOpenReusesTheCopy() async throws {
        let (app, defaults, dir) = try makeApp()
        defer { try? FileManager.default.removeItem(at: dir); _ = defaults }
        await app.start()
        #expect(!app.hasOpenAIKey)
        let first = try await app.sampleBookEntry()
        let second = try await app.sampleBookEntry()
        #expect(first.id == second.id)
        #expect(app.libraryEntries.filter { $0.id == first.id }.count == 1)
        let document = try await app.openBook(first.id)
        #expect(document.content.book.pageOrder.count >= 6)

        // If the copy is deleted, the next open copies again (a new book).
        try FileManager.default.removeItem(at: first.url)
        await app.refreshLibrary()
        let third = try await app.sampleBookEntry()
        #expect(third.id != first.id)
        #expect(app.entry(for: third.id) != nil)
    }
}
