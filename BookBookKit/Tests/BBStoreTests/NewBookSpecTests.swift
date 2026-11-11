import BBModel
import Foundation
import Testing
@testable import BBStore

struct NewBookSpecTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaultContent(title: String = "Untitled") throws -> BookContent {
        BookContent.makeNew(title: title, storyTemplate: try Presets.storyTemplate(),
                            coverTemplate: try Presets.coverTemplate(), storyPageCount: 1, now: now)
    }

    private func tempLibrary() -> (Library, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bbstore-newbook-\(UUID().uuidString)")
        return (Library(root: dir.appending(path: "Library", directoryHint: .isDirectory)), dir)
    }

    @Test func allSkippedSpecEqualsDefaultBook() throws {
        let base = try defaultContent()
        let applied = NewBookSpec(title: "Untitled").apply(to: base)
        #expect(applied == base)
        #expect(applied.style.pageSetup == StyleGuide().pageSetup)
        #expect(applied.assets.isEmpty)
    }

    @Test func titleAndAuthorLand() throws {
        let applied = NewBookSpec(title: "  The Fox  ", author: " Ann ").apply(to: try defaultContent())
        #expect(applied.book.title == "The Fox")
        #expect(applied.book.author == "Ann")
        #expect(NewBookSpec(title: "   ").apply(to: try defaultContent()).book.title == "Untitled")
    }

    @Test func pageSetupMatchesStyleTabTransform() throws {
        let base = try defaultContent()
        let spec = NewBookSpec(title: "T", pageSize: .a5, orientation: .landscape)
        let applied = spec.apply(to: base)
        #expect(applied.style.pageSetup == base.style.pageSetup.applying(preset: .a5, orientation: .landscape))
        #expect(applied.style.pageSetup.orientation == .landscape)
        // Templates are page-relative, so every page and template is untouched.
        #expect(applied.pages == base.pages)
        #expect(applied.templates == base.templates)

        let square = NewBookSpec(title: "T", pageSize: .square8, orientation: .landscape).apply(to: base)
        #expect(square.style.pageSetup.orientation == .square)
        #expect(square.style.pageSetup.trimSize.width == square.style.pageSetup.trimSize.height)
    }

    @Test func stylePresetFieldsLand() throws {
        let preset = try #require(try Presets.stylePresets().first)
        let base = try defaultContent()
        let applied = NewBookSpec(title: "T", stylePresetID: preset.id).apply(to: base)
        #expect(applied.style.presetID == preset.id)
        #expect(applied.style.visualDescription == preset.visualDescription)
        #expect(applied.style.negativeGuidance == (preset.negativeGuidance ?? StyleGuide.defaultNegativeGuidance))
        #expect(applied.style.visualRevision > base.style.visualRevision)
        // Unknown preset ids are ignored.
        let unknown = NewBookSpec(title: "T", stylePresetID: "nope").apply(to: base)
        #expect(unknown.style == base.style)
    }

    @Test func mainCharacterBecomesAssetWithSessions() throws {
        let spec = NewBookSpec(title: "T", mainCharacter: .init(name: "Pip", description: "A small green frog."))
        let applied = spec.apply(to: try defaultContent())
        let asset = try #require(applied.assets.values.first)
        #expect(applied.assets.count == 1)
        #expect(asset.type == .character)
        #expect(asset.name == "Pip")
        #expect(asset.description == "A small green frog.")
        #expect(asset.chosen == nil)
        #expect(applied.sessions[asset.sessionID]?.owner == .asset(asset.id))
        #expect(applied.sessions.values.filter { $0.owner.assetID != nil }.count == 1)
        let blank = NewBookSpec(title: "T", mainCharacter: .init(name: " ", description: ""))
        #expect(blank.apply(to: try defaultContent()).assets.isEmpty)
    }

    @Test func libraryCreateBookFromSpecRoundTrips() async throws {
        let (library, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = NewBookSpec(title: "Wizard", author: "Me", pageSize: .eightByTen, orientation: .portrait,
                               stylePresetID: try Presets.stylePresets()[0].id,
                               mainCharacter: .init(name: "Pip", description: "A frog."), importStoryAfter: true)
        let entry = try library.createBook(spec: spec, now: now)
        let loaded = try await BookStore(packageURL: entry.url).load()
        #expect(loaded.book.title == "Wizard")
        #expect(loaded.book.id == entry.id)
        #expect(loaded.style.pageSetup.sizePreset == .eightByTen)
        #expect(loaded.assets.count == 1)
        #expect(loaded.book.author == "Me")
        #expect(loaded.style.presetID == spec.stylePresetID)
        #expect(loaded.assets.values.first?.description == "A frog.")
        #expect(loaded.assets.values.first.map { loaded.sessions[$0.sessionID]?.owner == $0.owner } == true)
    }

    // MARK: Preset samples

    @Test func presetsDecodeWithoutSampleImages() throws {
        let presets = try Presets.stylePresets()
        #expect(!presets.isEmpty)
        for preset in presets where preset.sampleImage == nil { #expect(preset.sampleImageURL == nil) }
        #expect(StylePreset(id: "x", name: "X", visualDescription: "d", sampleImage: "missing.jpg").sampleImageURL == nil)
    }

    // MARK: Sample book

    @Test func sampleBookResourceExistsAndLoads() async throws {
        let url = try #require(SampleBook.bundledURL())
        // Load a copy: `load()` may recover/migrate, and the bundled package is read-only.
        let (library, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = try await BookStore(packageURL: library.installSample(from: url, now: now).url).load()
        #expect(content.book.pageOrder.count >= 6)
        #expect(content.assets.values.contains { $0.type == .character })
        #expect(content.style.presetID == "watercolour")
        // One image session per asset, in the new format (no slots, no sheet).
        let assetSessions = content.sessions.values.filter { $0.owner.assetID != nil }
        #expect(assetSessions.count == content.assets.count)
        for asset in content.assets.values { #expect(content.sessions[asset.sessionID]?.owner == asset.owner) }
        let assetFiles = try FileManager.default.contentsOfDirectory(at: url.appending(path: "assets"),
                                                                     includingPropertiesForKeys: nil)
        for file in assetFiles where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("references") && !text.contains("sheet") && text.contains("sessionID"))
        }
    }

    @Test func installSampleCopiesWithNewBookID() async throws {
        let (library, dir) = tempLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try #require(SampleBook.bundledURL())
        let sourceBook = try PackageCoding.decode(
            Book.self, from: Data(contentsOf: source.appending(path: PackageCoding.bookPath)), what: "book.json")
        let a = try library.installSample(from: source, now: now)
        let b = try library.installSample(from: source, now: now)
        #expect(a.id != sourceBook.id)
        #expect(a.id != b.id)
        #expect(a.url != b.url)
        let loaded = try await BookStore(packageURL: a.url).load()
        #expect(loaded.book.id == a.id)
        #expect(loaded.book.title == sourceBook.title)
        #expect(library.scan().contains { $0.id == a.id })
    }
}
