import Foundation
import Testing
@testable import BBStore

/// Phase 16b: `moveAside` (#34b) and the `undelivered/` spool folder (#42a).
@Suite struct Phase16bAppSupportTests {
    private func files() throws -> AppSupportFiles {
        AppSupportFiles(folderURL: try makeTempDir().appending(path: "BookBook", directoryHint: .isDirectory))
    }

    @Test func moveAsideKeepsTheBytesUnderATimestampedName() throws {
        let f = try files()
        try f.write(Data("old".utf8), to: AppSupportFiles.queueFileName)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let name = try f.moveAside(AppSupportFiles.queueFileName, now: at)
        #expect(name == "queue-unreadable-20270115T080000Z.json")
        #expect(f.read(name) == Data("old".utf8))
        #expect(f.read(AppSupportFiles.queueFileName) == nil)

        // The same second again: a number is added rather than overwriting.
        try f.write(Data("newer".utf8), to: AppSupportFiles.queueFileName)
        let second = try f.moveAside(AppSupportFiles.queueFileName, now: at)
        #expect(second == "queue-unreadable-20270115T080000Z-2.json")
        #expect(f.read(second) == Data("newer".utf8))
        #expect(f.read(name) == Data("old".utf8))
    }

    @Test func moveAsideOfAMissingFileThrows() throws {
        #expect(throws: StoreError.self) { try files().moveAside(AppSupportFiles.queueFileName) }
    }

    @Test func spoolSubfolderIsCreatedAndListed() throws {
        let f = try files()
        #expect(f.fileNames(in: AppSupportFiles.undeliveredFolderName).isEmpty)
        try f.write(Data([1]), to: "\(AppSupportFiles.undeliveredFolderName)/b.png")
        try f.write(Data([2]), to: "\(AppSupportFiles.undeliveredFolderName)/a.png")
        #expect(f.fileNames(in: AppSupportFiles.undeliveredFolderName) == ["a.png", "b.png"])
        #expect(f.exists("\(AppSupportFiles.undeliveredFolderName)/a.png"))
        try f.remove("\(AppSupportFiles.undeliveredFolderName)/a.png")
        #expect(f.fileNames(in: AppSupportFiles.undeliveredFolderName) == ["b.png"])
        #expect(!f.exists("\(AppSupportFiles.undeliveredFolderName)/a.png"))
    }
}
