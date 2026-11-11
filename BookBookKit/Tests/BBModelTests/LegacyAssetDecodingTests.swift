import Foundation
import Testing
@testable import BBModel

/// 2026-11-11 one-image-per-asset change: legacy asset, owner and target JSON still decode.
struct LegacyAssetDecodingTests {
    static let assetID = "FEDEE77C-7D18-4196-AA43-6C4A6D39B9D5"
    static let sessionA = "E0CB979A-9C4C-4D92-B5C1-AC4CB6D963E0"
    static let sessionB = "41B7B120-C5B6-4680-B4EF-3886A940C1CD"
    static let versionB = "09B2762C-83B4-4F34-A373-C30D7118629B"
    static let slotID = "2A844796-40DC-4E9D-8613-CE503D260592"

    /// The synthesized `Codable` format the old enums used, for checking the custom coding matches it.
    enum SynthesizedOwner: Codable, Equatable {
        case pageBox(PageID, BoxID)
        case asset(AssetID)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func legacyAsset(slots: String, sheet: Bool) -> String {
        let sheetJSON = sheet ? """
        , "sheet": {"items": [{"id": "D0F38A50-83EF-41BB-8348-5E4CDB02F4E9", "kind": {"view": {"_0": "side"}},
          "locked": false, "sessionID": "\(sessionB)"}]}
        """ : ""
        return """
        {"id": "\(assetID)", "type": "character", "name": "Pip", "description": "A frog", "tags": ["green"],
         "revision": 3, "revisionHighWater": 4, "references": [\(slots)]\(sheetJSON)}
        """
    }

    static func slot(_ session: String, primary: Bool, chosen: String? = nil) -> String {
        let chosenJSON = chosen.map { #", "chosen": "\#($0)""# } ?? ""
        return #"{"id": "\#(UUID().uuidString)", "label": "L", "isPrimary": \#(primary), "sessionID": "\#(session)"\#(chosenJSON)}"#
    }

    // MARK: Asset

    @Test func legacyAssetKeepsPrimarySlotAndIgnoresSheet() throws {
        let json = Self.legacyAsset(slots: [Self.slot(Self.sessionA, primary: false),
                                            Self.slot(Self.sessionB, primary: true, chosen: Self.versionB)]
            .joined(separator: ","), sheet: true)
        let asset = try Self.decode(Asset.self, json)
        #expect(asset.id == AssetID(Self.assetID))
        #expect(asset.type == .character && asset.name == "Pip" && asset.description == "A frog")
        #expect(asset.sessionID == SessionID(Self.sessionB))
        #expect(asset.chosen == VersionID(Self.versionB))
        #expect(asset.revision == 3 && asset.revisionHighWater == 4)
    }

    @Test func legacyAssetWithoutPrimaryFallsBackToFirstSlot() throws {
        let json = Self.legacyAsset(slots: [Self.slot(Self.sessionA, primary: false, chosen: Self.versionB),
                                            Self.slot(Self.sessionB, primary: false)]
            .joined(separator: ","), sheet: false)
        let asset = try Self.decode(Asset.self, json)
        #expect(asset.sessionID == SessionID(Self.sessionA))
        #expect(asset.chosen == VersionID(Self.versionB))
    }

    @Test func newAssetFormatRoundTripsWithoutLegacyKeys() throws {
        var asset = Asset.makeNew(type: .object, name: "Lamp")
        asset.chosen = VersionID()
        let data = try JSONEncoder().encode(asset)
        #expect(try JSONDecoder().decode(Asset.self, from: data) == asset)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(!keys.contains("references") && !keys.contains("sheet"))
        #expect(keys.contains("sessionID") && keys.contains("chosen"))
    }

    // MARK: SessionOwner / GenerationTarget

    @Test func ownerAndTargetMatchSynthesizedFormat() throws {
        let page = PageID(), box = BoxID(), asset = AssetID()
        let pairs: [(SessionOwner, SynthesizedOwner)] = [(.pageBox(page, box), .pageBox(page, box)),
                                                         (.asset(asset), .asset(asset))]
        for (owner, synthesized) in pairs {
            let ownerData = try JSONEncoder().encode(owner)
            let synthesizedData = try JSONEncoder().encode(synthesized)
            #expect(try JSONDecoder().decode(SynthesizedOwner.self, from: ownerData) == synthesized)
            #expect(try JSONDecoder().decode(SessionOwner.self, from: synthesizedData) == owner)
            #expect(try JSONDecoder().decode(SessionOwner.self, from: ownerData) == owner)

            let target = GenerationTarget(owner: owner)
            #expect(target.owner == owner)
            let targetData = try JSONEncoder().encode(target)
            #expect(try JSONDecoder().decode(SynthesizedOwner.self, from: targetData) == synthesized)
            #expect(try JSONDecoder().decode(GenerationTarget.self, from: synthesizedData) == target)
        }
        #expect(try Self.decode(SessionOwner.self, #"{"asset": {"_0": "\#(Self.assetID)"}}"#)
            == .asset(AssetID(Self.assetID)))
    }

    @Test func legacyAssetReferenceDecodesAsAsset() throws {
        let json = #"{"assetReference": {"_0": "\#(Self.assetID)", "_1": "\#(Self.slotID)"}}"#
        #expect(try Self.decode(SessionOwner.self, json) == .asset(AssetID(Self.assetID)))
        #expect(try Self.decode(GenerationTarget.self, json) == .asset(AssetID(Self.assetID)))
    }

    @Test func legacySheetItemThrows() {
        let json = #"{"sheetItem": {"_0": "\#(Self.assetID)", "_1": "\#(Self.slotID)"}}"#
        let expected = LegacySheetItemError(asset: AssetID(Self.assetID))
        #expect(throws: expected) { try Self.decode(SessionOwner.self, json) }
        #expect(throws: expected) { try Self.decode(GenerationTarget.self, json) }
        let session = #"{"id": "\#(Self.sessionB)", "owner": \#(json), "messages": [], "versions": [], "resetEpoch": 0}"#
        #expect(throws: expected) { try Self.decode(Session.self, session) }
    }

    @Test func malformedOwnerIsADecodingError() {
        #expect(throws: DecodingError.self) { try Self.decode(SessionOwner.self, "{}") }
        #expect(throws: DecodingError.self) { try Self.decode(SessionOwner.self, #"{"other": {"_0": "x"}}"#) }
    }
}
