import BBModel
import Foundation
import Testing
@testable import BBStore

@Suite struct CleanUpTests {
    /// A book with: cover placement, story placement, starred, asset chosen, and
    /// 5 loose versions (one shares its image with a placed version), all in real files.
    private struct Fixture {
        var book: DiskBook
        var coverV: Version, storyV: Version, starredV: Version, refV: Version
        var loose: [Version]
        var sharedLoose: Version
    }

    private func makeFixture() async throws -> Fixture {
        var book = try DiskBook.make(title: "Clean")
        let cover = try #require(book.content.coverPage)
        let (coverBox, coverSlot) = try #require(cover.images.first)
        let coverV = try await book.addVersion("cover", to: coverSlot.sessionID)
        book.content.pages[cover.id]?.images[coverBox]?.placement = ImagePlacement(versionID: coverV.id, boxAspectWhenPlaced: 1)

        let storyID = try #require(book.content.book.pageOrder.first)
        let story = try #require(book.content.pages[storyID])
        let (storyBox, storySlot) = try #require(story.images.first)
        let storyV = try await book.addVersion("story", to: storySlot.sessionID)
        book.content.pages[storyID]?.images[storyBox]?.placement = ImagePlacement(versionID: storyV.id, boxAspectWhenPlaced: 1)
        let starredV = try await book.addVersion("starred", to: storySlot.sessionID, starred: true)
        var loose: [Version] = []
        for i in 0..<4 { loose.append(try await book.addVersion("loose-\(i)", to: storySlot.sessionID)) }
        // Same bytes as the placed story version: file must survive.
        let sharedLoose = try await book.addVersion("story", to: coverSlot.sessionID)

        let asset = try await book.addAsset(name: "Pip", primaryBytes: "ref")
        let chosen = try #require(asset.chosen)
        let refV = try #require(book.content.sessions[asset.sessionID]?.version(chosen))
        return Fixture(book: book, coverV: coverV, storyV: storyV, starredV: starredV, refV: refV,
                       loose: loose, sharedLoose: sharedLoose)
    }

    @Test func deletableSetKeepsPlacedStarredAndChosen() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.book.dir) }
        let plan = CleanUp.plan(for: f.book.content) { f.book.store.imageFileSize($0) }
        let keep = [f.coverV, f.storyV, f.starredV, f.refV].map(\.id)
        for id in keep { #expect(!plan.versionIDs.contains(id)) }
        // Loose versions, the shared-image duplicate, and the unchosen "extra-Pip" asset version.
        #expect(plan.versionIDs.isSuperset(of: f.loose.map(\.id) + [f.sharedLoose.id]))
        #expect(plan.versionIDs.count == 6)
        #expect(!plan.isEmpty)
    }

    @Test func bytesFreedOnlyCountsFilesUsedSolelyByDeletedVersions() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.book.dir) }
        let plan = CleanUp.plan(for: f.book.content) { f.book.store.imageFileSize($0) }
        // 4 loose + "extra-Pip" files go; the shared "story" file stays.
        #expect(plan.fileNames.count == 5)
        #expect(!plan.fileNames.contains(f.storyV.image.fileName))
        #expect(!plan.fileNames.contains(f.sharedLoose.image.fileName))
        let expected = plan.fileNames.reduce(Int64(0)) { $0 + (f.book.store.imageFileSize($1) ?? 0) }
        #expect(plan.bytesFreed == expected && plan.bytesFreed > 0)
        // A missing file counts as zero.
        #expect(CleanUp.plan(for: f.book.content) { _ in nil }.bytesFreed == 0)
    }

    @Test func keepsAncestorsOfPlacedVersion() async throws {
        var f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.book.dir) }
        let storyID = try #require(f.book.content.book.pageOrder.first)
        let (box, slot) = try #require(f.book.content.pages[storyID]?.images.first)
        let v1 = try await f.book.addVersion("v1", to: slot.sessionID)
        var v2 = try await f.book.addVersion("v2", to: slot.sessionID)
        var v3 = try await f.book.addVersion("v3", to: slot.sessionID)
        v2.parent = v1.id
        v3.parent = v2.id
        f.book.content.sessions[slot.sessionID]?.versions.removeAll { $0.id == v2.id || $0.id == v3.id }
        f.book.content.sessions[slot.sessionID]?.versions.append(contentsOf: [v2, v3])
        f.book.content.pages[storyID]?.images[box]?.placement = ImagePlacement(versionID: v3.id, boxAspectWhenPlaced: 1)
        let plan = CleanUp.plan(for: f.book.content) { f.book.store.imageFileSize($0) }
        #expect(!plan.versionIDs.contains(v1.id))
        #expect(!plan.versionIDs.contains(v2.id))
        #expect(!plan.versionIDs.contains(v3.id))
        #expect(plan.versionIDs.isSuperset(of: f.loose.map(\.id)))
    }

    @Test func emptyWhenNothingToClean() throws {
        let content = try sampleContent()
        #expect(CleanUp.plan(for: content) { _ in 1 }.isEmpty)
    }

    @Test func applyThenDeleteShrinksPackageAndKeepsKeptImages() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.book.dir) }
        try await f.book.store.save(f.book.content, dirty: .all(f.book.content))
        let before = f.book.store.sizeOnDisk()
        let plan = CleanUp.plan(for: f.book.content) { f.book.store.imageFileSize($0) }

        var cleaned = f.book.content
        CleanUp.apply(plan, to: &cleaned)
        let affected = CleanUp.affectedSessions(plan, in: f.book.content)
        #expect(!affected.isEmpty)
        for id in plan.versionIDs { #expect(cleaned.sessions.values.allSatisfy { $0.version(id) == nil }) }
        #expect(CleanUp.plan(for: cleaned) { _ in 1 }.isEmpty)

        try await f.book.store.save(cleaned, dirty: DirtySet(sessions: affected))
        let removed = try await f.book.store.deleteImages(named: plan.fileNames)
        #expect(removed == plan.fileNames.count)
        let after = f.book.store.sizeOnDisk()
        #expect(after < before)
        #expect(before - after >= plan.bytesFreed)

        let reloaded = try await BookStore(packageURL: f.book.url).load()
        #expect(reloaded.sessions.values.flatMap(\.versions).count == 4)
        for v in [f.coverV, f.storyV, f.starredV, f.refV] { #expect(exists(f.book.store.imageURL(for: v.image))) }
        #expect(f.book.fileNames().count == 4)
    }

    @Test func deleteImagesIgnoresPathsAndMissingFiles() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.book.dir) }
        let removed = try await f.book.store.deleteImages(named: ["../book.json", "nope.png", ""])
        #expect(removed == 0)
        #expect(exists(f.book.url.appending(path: "book.json")))
    }
}
