import BBModel
import Foundation
import Testing
@testable import BBStore

/// 2026-11-11 one-image-per-asset change: a book saved with reference slots and a character
/// sheet loads with one session per asset (the primary slot's); the others are dropped.
@Suite struct LegacyAssetLoadTests {
    struct LegacyBook {
        var dir: URL
        var url: URL
        var assetID: AssetID
        var primary: SessionID
        var primaryChosen: VersionID
        var otherSlot: SessionID
        var sheetItems: [SessionID]
        /// Used only by the dropped sessions (aged past the sweep's 24 h guard).
        var droppedImage: ImageRef
        /// Used by the primary and by a dropped session.
        var sharedImage: ImageRef
    }

    static func sessionPath(_ url: URL, _ id: SessionID) -> URL { url.appending(path: PackageCoding.sessionPath(id)) }

    /// Writes `session` with `owner` replaced by a legacy owner JSON object.
    static func writeLegacySession(_ session: Session, owner: [String: Any], to url: URL) throws {
        var json = try #require(try JSONSerialization.jsonObject(with: PackageCoding.encode(session)) as? [String: Any])
        json["owner"] = owner
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            .write(to: sessionPath(url, session.id))
    }

    static func makeLegacyBook() async throws -> LegacyBook {
        let dir = try makeTempDir()
        let url = dir.appending(path: "Legacy.bookbook", directoryHint: .isDirectory)
        try BookStore.create(try sampleContent(), at: url)
        let store = BookStore(packageURL: url)
        let shared = try await store.storeImage(Data("primary".utf8), contentType: "public.png")
        let dropped = try await store.storeImage(Data("dropped".utf8), contentType: "public.png")
        let old = Date().addingTimeInterval(-3 * 86_400)
        for ref in [shared, dropped] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: store.imageURL(for: ref).path(percentEncoded: false))
        }
        func version(_ ref: ImageRef) -> Version {
            Version(image: ref, pixelSize: PixelSize(width: 1, height: 1), source: .imported, createdAt: testNow)
        }

        let assetID = AssetID()
        let id = assetID.rawValue.uuidString
        let primarySlot = UUID(), otherSlot = UUID()
        let primary = Session(owner: .asset(assetID), versions: [version(shared)])
        let other = Session(owner: .asset(assetID), versions: [version(dropped), version(shared)])
        try writeLegacySession(primary, owner: ["assetReference": ["_0": id, "_1": primarySlot.uuidString]], to: url)
        try writeLegacySession(other, owner: ["assetReference": ["_0": id, "_1": otherSlot.uuidString]], to: url)
        var sheetItems: [SessionID] = []
        var sheetJSON: [[String: Any]] = []
        for view in ["threeQuarter", "side"] {
            let item = UUID()
            let session = Session(owner: .asset(assetID), versions: [version(dropped)])
            try writeLegacySession(session, owner: ["sheetItem": ["_0": id, "_1": item.uuidString]], to: url)
            sheetItems.append(session.id)
            sheetJSON.append(["id": item.uuidString, "kind": ["view": ["_0": view]], "locked": false,
                              "sessionID": session.id.rawValue.uuidString,
                              "chosen": session.versions[0].id.rawValue.uuidString])
        }
        // The other slot comes first and the primary isn't first, so the primary flag decides.
        let asset: [String: Any] = [
            "id": id, "type": "character", "name": "Pip", "description": "A frog", "tags": [String](),
            "revision": 2, "revisionHighWater": 2,
            "references": [
                ["id": otherSlot.uuidString, "label": "Side", "isPrimary": false,
                 "sessionID": other.id.rawValue.uuidString, "chosen": other.versions[0].id.rawValue.uuidString],
                ["id": primarySlot.uuidString, "label": "Primary", "isPrimary": true,
                 "sessionID": primary.id.rawValue.uuidString, "chosen": primary.versions[0].id.rawValue.uuidString],
            ],
            "sheet": ["items": sheetJSON],
        ]
        try JSONSerialization.data(withJSONObject: asset, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.appending(path: PackageCoding.assetPath(assetID)))
        return LegacyBook(dir: dir, url: url, assetID: assetID, primary: primary.id,
                          primaryChosen: primary.versions[0].id, otherSlot: other.id, sheetItems: sheetItems,
                          droppedImage: dropped, sharedImage: shared)
    }

    @Test func legacyBookLoadsWithOnlyThePrimarySession() async throws {
        let legacy = try await Self.makeLegacyBook()
        defer { try? FileManager.default.removeItem(at: legacy.dir) }
        let store = BookStore(packageURL: legacy.url)
        let content = try await store.load()

        let asset = try #require(content.assets[legacy.assetID])
        #expect(asset.sessionID == legacy.primary)
        #expect(asset.chosen == legacy.primaryChosen)
        let assetSessions = content.sessions.values.filter { $0.owner.assetID != nil }
        #expect(assetSessions.map(\.id) == [legacy.primary])
        #expect(content.sessions[legacy.primary]?.owner == .asset(legacy.assetID))
        #expect(content.sessions[legacy.primary]?.versions.map(\.id) == [legacy.primaryChosen])

        // The dropped sessions' files are gone, and the sweep freed the image only they used.
        for id in [legacy.otherSlot] + legacy.sheetItems { #expect(!exists(Self.sessionPath(legacy.url, id))) }
        #expect(exists(Self.sessionPath(legacy.url, legacy.primary)))
        #expect(!exists(store.imageURL(for: legacy.droppedImage)))
        #expect(exists(store.imageURL(for: legacy.sharedImage)))

        // Reopening (and saving the asset in the new format) gives the same content.
        try await store.save(content, dirty: DirtySet(sessions: [legacy.primary], assets: [legacy.assetID]))
        #expect(try await BookStore(packageURL: legacy.url).load() == content)
    }

    @Test func readOnlyLoadDropsInMemoryButLeavesFiles() async throws {
        let legacy = try await Self.makeLegacyBook()
        defer { try? FileManager.default.removeItem(at: legacy.dir) }
        let store = BookStore(packageURL: legacy.url)
        await store.setReadOnly()
        let content = try await store.load()
        #expect(content.sessions.values.filter { $0.owner.assetID != nil }.map(\.id) == [legacy.primary])
        for id in [legacy.otherSlot] + legacy.sheetItems { #expect(exists(Self.sessionPath(legacy.url, id))) }
        #expect(exists(store.imageURL(for: legacy.droppedImage)))
    }

    @Test func sessionsOfDeletedAssetsStay() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook", directoryHint: .isDirectory)
        var content = try sampleContent()
        let gone = Session(owner: .asset(AssetID()))
        content.sessions[gone.id] = gone
        try BookStore.create(content, at: url)
        #expect(try await BookStore(packageURL: url).load().sessions[gone.id] == gone)
    }

    @Test func otherCorruptSessionStillFailsTheOpen() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook", directoryHint: .isDirectory)
        try BookStore.create(try sampleContent(), at: url)
        try Data(#"{"owner": {"nope": {}}}"#.utf8).write(to: Self.sessionPath(url, SessionID()))
        await #expect(throws: StoreError.self) { try await BookStore(packageURL: url).load() }
    }
}
