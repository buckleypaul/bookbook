import Foundation
import Testing
@testable import BBModel

@Test func BookID_codableRoundTrip() throws {
    let id = BookID(rawValue: UUID())
    let data = try JSONEncoder().encode(id)
    let decoded = try JSONDecoder().decode(BookID.self, from: data)
    #expect(decoded == id)
}
