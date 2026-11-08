import BBAICore
import BBModel
import Foundation
import Testing
@testable import BBAI

@Suite struct PriceListTests {
    @Test func bundledLoadsAndHasImageModel() throws {
        let list = try PriceList.bundled()
        #expect(!list.asOf.isEmpty)
        let entry = try #require(list.entry(provider: .openai, model: "gpt-image-2.5-sunburst"))
        #expect(entry.perMillionTokens["imageOut"] == 30)
        #expect(entry.estimation?.outputImageTokens?["low@1024x1024"] == 196)
    }

    @Test func bundledRoundTrips() throws {
        let list = try PriceList.bundled()
        let again = try PriceList(data: list.encoded())
        #expect(again == list)
        // Stable output: encoding twice gives identical bytes.
        #expect(try list.encoded() == again.encoded())
    }

    @Test func validUserCopyWins() throws {
        let bundled = try PriceList.bundled()
        var user = bundled
        user.asOf = "2030-01-01"
        let result = PriceList.resolved(bundled: bundled, userData: try user.encoded())
        #expect(result.list.asOf == "2030-01-01")
        #expect(result.userOverrideError == nil)
    }

    @Test func invalidUserCopyFallsBackWithError() throws {
        let bundled = try PriceList.bundled()
        let result = PriceList.resolved(bundled: bundled, userData: Data("{ not json".utf8))
        #expect(result.list == bundled)
        #expect(result.userOverrideError?.isEmpty == false)
    }

    @Test func noUserCopyUsesBundled() throws {
        let bundled = try PriceList.bundled()
        let result = PriceList.resolved(bundled: bundled, userData: nil)
        #expect(result.list == bundled)
        #expect(result.userOverrideError == nil)
    }

    @Test func malformedDataThrows() {
        #expect(throws: PriceListError.self) { try PriceList(data: Data("[]".utf8)) }
    }
}
