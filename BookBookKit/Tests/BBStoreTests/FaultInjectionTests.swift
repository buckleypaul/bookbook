import BBModel
import Foundation
import Testing
@testable import BBStore

/// Runs a suite with `PackageCoding.fullSync` off. These suites simulate crashes, not power loss,
/// and `F_FULLFSYNC` flushes the whole drive, which would stall the timing-based autosave tests
/// running beside them.
struct CheapSync: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await PackageCoding.$fullSync.withValue(false) { try await function() }
    }
}

extension Trait where Self == CheapSync {
    static var cheapSync: CheapSync { CheapSync() }
}

/// Crash after each save step (A §5.2, steps 1-5) × three entity mixes. A reopened book is
/// always the before or the after state, never a mix, and the open leaves no `.journal` behind.
@Suite(.serialized, .cheapSync) struct FaultInjectionTests {
    enum Mix: String, CaseIterable, Sendable {
        /// The book plus the style only.
        case bookAndStyle
        /// Pages, including a deletion (and the book's page order).
        case pagesWithDeletion
        /// Sessions plus a new image.
        case sessionsAndImage
    }

    struct Edit {
        var after: BookContent
        var dirty: DirtySet
        var image: ImageRef?
    }

    /// Applies `mix` to `before`. For `.sessionsAndImage`, stores a new image first (step 1).
    private func edit(_ mix: Mix, _ before: BookContent, store: BookStore) async throws -> Edit {
        var after = before
        switch mix {
        case .bookAndStyle:
            after.book.title = "After"
            after.style.visualDescription = "Watercolour, after"
            return Edit(after: after, dirty: DirtySet(book: true, style: true))
        case .pagesWithDeletion:
            let editedID = before.book.pageOrder[0]
            let deletedID = before.book.pageOrder[1]
            let boxID = try #require(before.template(for: before.pages[editedID]!)?.textBoxes.first?.id)
            after.pages[editedID]!.text[boxID] = RichText(plain: "Once upon a time, after")
            after.pages[deletedID] = nil
            after.book.pageOrder.removeAll { $0 == deletedID }
            return Edit(after: after, dirty: DirtySet(book: true, pages: [editedID], deletedPages: [deletedID]))
        case .sessionsAndImage:
            let bytes = Data("png-\(UUID().uuidString)".utf8)
            let ref = try await store.storeImage(bytes, contentType: "public.png")
            let pageID = before.book.pageOrder[0]
            let session = Session(owner: .pageBox(pageID, BoxID()), versions: [
                BBModel.Version(image: ref, pixelSize: PixelSize(width: 64, height: 64), source: .imported,
                                createdAt: testNow),
            ])
            after.sessions[session.id] = session
            return Edit(after: after, dirty: DirtySet(sessions: [session.id]), image: ref)
        }
    }

    /// The step-4 operation counts to crash after: every partial point plus "all applied".
    private func renameCounts(_ edit: Edit) throws -> [Int?] {
        let ops = try PackageCoding.files(for: edit.after, dirty: edit.dirty).count + edit.dirty.deletedPages.count
        return Array(1...ops).map(Optional.some)
    }

    @Test(arguments: SaveStep.allCases, Mix.allCases)
    func crashAfterStepRecoversToBeforeOrAfter(step: SaveStep, mix: Mix) async throws {
        // Probe the operation count once, on a throwaway book.
        let probeDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let probeURL = probeDir.appending(path: "P.bookbook")
        let probeBefore = try sampleContent()
        try BookStore.create(probeBefore, at: probeURL)
        let probe = try await edit(mix, probeBefore, store: BookStore(packageURL: probeURL))
        let points: [Int?] = step == .renamed ? try renameCounts(probe) : [nil]

        for renames in points {
            try await runCrash(step: step, mix: mix, renames: renames)
        }
    }

    private func runCrash(step: SaveStep, mix: Mix, renames: Int?) async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        let before = try sampleContent(title: "Before")
        try BookStore.create(before, at: url)

        let store = BookStore(packageURL: url)
        #expect(try await store.acquireLock() == .acquired)
        #expect(try await store.load() == before)
        let change = try await edit(mix, before, store: store)
        await store.setSaveFaultHook { s, applied in
            if s == step, renames == nil || applied == renames { throw SimulatedCrash() }
        }
        await #expect(throws: StoreError.self) { try await store.save(change.after, dirty: change.dirty) }
        // The process "died": the lock it wrote is left behind; this process reopens it re-entrantly.

        let reopened = BookStore(packageURL: url)
        #expect(try await reopened.acquireLock() == .acquired)
        let loaded = try await reopened.load()
        let label = "\(step) \(mix) renames=\(renames.map(String.init) ?? "-")"
        // Before COMMIT the save is discarded; from COMMIT on it rolls forward.
        let expected = step.rawValue >= SaveStep.committed.rawValue ? change.after : before
        #expect(loaded == expected, "\(label)")
        #expect(loaded == before || loaded == change.after, "\(label)")
        #expect(!exists(url.appending(path: ".journal")), "\(label)")
        if let image = change.image {
            // A young orphan survives the open-time sweep, so a later retry still finds it.
            #expect(exists(reopened.imageURL(for: image)), "\(label)")
        }

        // The recovered book saves cleanly.
        var next = loaded
        next.book.title = "Next"
        try await reopened.save(next, dirty: DirtySet(book: true))
        #expect(try await BookStore(packageURL: url).load() == next)
        #expect(!exists(url.appending(path: ".journal")))
    }

    /// A crash while staging (before the manifest exists) is discarded too.
    @Test func crashMidStagingIsDiscarded() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        let before = try sampleContent()
        try BookStore.create(before, at: url)
        let tx = url.appending(path: ".journal/\(Journal.newTxid())/staged", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tx, withIntermediateDirectories: true)
        try Data("{\"half".utf8).write(to: tx.appending(path: "book.json"))
        #expect(try await BookStore(packageURL: url).load() == before)
        #expect(!exists(url.appending(path: ".journal")))
    }
}
