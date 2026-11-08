import Foundation
import Testing
@testable import BBStore

@Suite struct AppSupportFilesTests {
    private func files() throws -> AppSupportFiles {
        // A folder that doesn't exist yet, to exercise directory creation.
        AppSupportFiles(folderURL: try makeTempDir().appending(path: "BookBook", directoryHint: .isDirectory))
    }

    @Test func missingFileReadsNil() throws {
        #expect(try files().read(AppSupportFiles.queueFileName) == nil)
    }

    @Test func writeThenRead() throws {
        let f = try files()
        try f.write(Data("one".utf8), to: AppSupportFiles.priceListFileName)
        #expect(f.read(AppSupportFiles.priceListFileName) == Data("one".utf8))
        try f.write(Data("two".utf8), to: AppSupportFiles.priceListFileName)
        #expect(f.read(AppSupportFiles.priceListFileName) == Data("two".utf8))
        #expect(f.read(AppSupportFiles.queueFileName) == nil)
    }

    @Test func removeIsIdempotent() throws {
        let f = try files()
        try f.remove(AppSupportFiles.queueFileName)  // missing: fine
        try f.write(Data("q".utf8), to: AppSupportFiles.queueFileName)
        try f.remove(AppSupportFiles.queueFileName)
        #expect(f.read(AppSupportFiles.queueFileName) == nil)
        try f.remove(AppSupportFiles.queueFileName)
    }

    @Test func urlsLiveInTheFolder() throws {
        let f = try files()
        #expect(f.url(for: "queue.json").deletingLastPathComponent().lastPathComponent == "BookBook")
    }
}
