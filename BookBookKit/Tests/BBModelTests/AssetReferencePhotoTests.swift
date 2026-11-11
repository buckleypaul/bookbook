import Foundation
import Testing
@testable import BBModel

/// An asset's optional reference photo (PD §8.3, 2026-11-11).
struct AssetReferencePhotoTests {
    static let photo = AssetReferencePhoto(image: ImageRef(sha256: String(repeating: "cd", count: 32),
                                                           contentType: "public.jpeg"),
                                           pixelSize: PixelSize(width: 1536, height: 1024), depictsRealPerson: true)

    @Test func roundTripsAndIsOmittedWhenAbsent() throws {
        var asset = Asset.makeNew(type: .character, name: "Pip")
        let plain = try JSONEncoder().encode(asset)
        #expect(!String(decoding: plain, as: UTF8.self).contains("referencePhoto"))
        #expect(try JSONDecoder().decode(Asset.self, from: plain).referencePhoto == nil)
        asset.referencePhoto = Self.photo
        let decoded = try JSONDecoder().decode(Asset.self, from: JSONEncoder().encode(asset))
        #expect(decoded == asset)
        #expect(decoded.referencePhoto?.depictsRealPerson == true)
    }

    @Test func changingThePhotoDoesNotBumpTheRevision() {
        let old = Asset.makeNew(type: .character, name: "Pip")
        var edited = old
        edited.referencePhoto = Self.photo
        let stored = edited.revised(from: old)
        #expect(stored.revision == old.revision)
        #expect(stored.revisionHighWater == old.revisionHighWater)
        #expect(stored.referencePhoto == Self.photo)
    }
}
