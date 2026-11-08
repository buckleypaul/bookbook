import BBModel
import Foundation
import Synchronization
import Testing
@testable import BBStore

private func copyFixture() throws -> URL {
    let src = try #require(Bundle.module.url(forResource: "Fixtures/SchemaV1.bookbook", withExtension: nil))
    let dest = try makeTempDir().appending(path: "Fixture.bookbook", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: src, to: dest)
    return dest
}

/// Relative path -> bytes for every regular file in the package.
private func snapshot(_ root: URL) throws -> [String: Data] {
    var out: [String: Data] = [:]
    let e = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let url as URL in e where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
        let full = url.path(percentEncoded: false)
        let marker = try #require(full.range(of: "/" + root.lastPathComponent + "/"))
        out[String(full[marker.upperBound...])] = try Data(contentsOf: url)
    }
    return out
}

private func setSchemaVersion(_ data: Data, _ v: Int) throws -> Data {
    guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StoreError.corrupt("json") }
    obj["schemaVersion"] = v
    return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
}

private let renamedSession = "sessions/00000000-0000-4000-8000-0000000000AA.json"

private func v2Step() -> Migrator.Step {
    Migrator.Step(from: 1) { files in
        guard let book = files["book.json"] else { throw StoreError.corrupt("no book") }
        guard var obj = try JSONSerialization.jsonObject(with: book) as? [String: Any] else { throw StoreError.corrupt("book") }
        obj["subtitle"] = "added in v2"
        files["book.json"] = try setSchemaVersion(JSONSerialization.data(withJSONObject: obj), 2)
        guard let old = files.keys.filter({ $0.hasPrefix("sessions/") }).sorted().first else { throw StoreError.corrupt("session") }
        files[renamedSession] = files.removeValue(forKey: old)
    }
}

private final class Calls: Sendable {
    let log = Mutex<[(URL, Int)]>([])
}

@Suite struct MigratorTests {
    @Test func standardIsNoOpOnCurrentVersion() throws {
        let pkg = try copyFixture()
        let before = try snapshot(pkg)
        #expect(try Migrator.standard.migrateIfNeeded(packageURL: pkg) == nil)
        #expect(try snapshot(pkg) == before)
    }

    @Test func fixtureLoads() async throws {
        let content = try await BookStore(packageURL: copyFixture()).load()
        #expect(content.book.schemaVersion == 1)
    }

    @Test func migratesV1ToV2() throws {
        let pkg = try copyFixture()
        let before = try snapshot(pkg)
        let calls = Calls()
        let m = Migrator(steps: [v2Step()], currentVersion: 2) { url, v in calls.log.withLock { $0.append((url, v)) } }
        #expect(try m.migrateIfNeeded(packageURL: pkg) == 1)
        let log = calls.log.withLock { $0 }
        #expect(log.count == 1)
        #expect(log.first?.0 == pkg)
        #expect(log.first?.1 == 1)

        let after = try snapshot(pkg)
        let oldSession = try #require(before.keys.filter { $0.hasPrefix("sessions/") }.sorted().first)
        #expect(after[oldSession] == nil)
        #expect(after[renamedSession] == before[oldSession])
        #expect(after["style.json"] == before["style.json"])
        let bookData = try #require(after["book.json"])
        let book = try #require(JSONSerialization.jsonObject(with: bookData) as? [String: Any])
        #expect(book["schemaVersion"] as? Int == 2)
        #expect(book["subtitle"] as? String == "added in v2")
        // Untouched files are byte-identical, and no journal is left behind.
        for (path, data) in before where path != "book.json" && path != oldSession {
            #expect(after[path] == data)
        }
        #expect(!after.keys.contains { $0.hasPrefix(".journal") })
        // Second run is a no-op.
        #expect(try m.migrateIfNeeded(packageURL: pkg) == nil)
    }

    @Test func schemaTooNew() throws {
        let pkg = try copyFixture()
        let m = Migrator(steps: [], currentVersion: 0) { _, _ in }
        #expect(throws: StoreError.schemaTooNew(1)) { try m.migrateIfNeeded(packageURL: pkg) }
        var files: [String: Data] = [:]
        #expect(throws: StoreError.schemaTooNew(5)) { try m.migrate(&files, from: 5) }
    }

    @Test func missingStepIsCorrupt() throws {
        let pkg = try copyFixture()
        let before = try snapshot(pkg)
        let m = Migrator(steps: [], currentVersion: 2) { _, _ in }
        #expect(throws: StoreError.self) { try m.migrateIfNeeded(packageURL: pkg) }
        do { try m.migrateIfNeeded(packageURL: pkg) } catch {
            guard case .corrupt = error else { Issue.record("expected corrupt, got \(error)"); return }
        }
        #expect(try snapshot(pkg) == before)
    }

    @Test func failingStepLeavesPackageUntouched() throws {
        let pkg = try copyFixture()
        let before = try snapshot(pkg)
        struct Boom: Error {}
        let bad = Migrator.Step(from: 1) { files in
            files["book.json"] = Data("{}".utf8)
            throw Boom()
        }
        let calls = Calls()
        let m = Migrator(steps: [bad], currentVersion: 2) { url, v in calls.log.withLock { $0.append((url, v)) } }
        do { try m.migrateIfNeeded(packageURL: pkg); Issue.record("should throw") } catch {
            guard case .corrupt = error else { Issue.record("expected corrupt, got \(error)"); return }
        }
        #expect(try snapshot(pkg) == before)
    }
}
