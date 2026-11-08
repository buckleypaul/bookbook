import Foundation
import Testing
@testable import BBStore

private struct Rec: Codable, Equatable {
    var id: Int
    var note: String
    var at: Date
}

private func rec(_ i: Int) -> Rec {
    Rec(id: i, note: "line\nbreak \(i)", at: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
}

private func ledger() throws -> CostLedger {
    CostLedger(packageURL: try makeTempDir())
}

private func appendRaw(_ ledger: CostLedger, _ s: String) throws {
    let h = try FileHandle(forWritingTo: ledger.fileURL)
    try h.seekToEnd()
    try h.write(contentsOf: Data(s.utf8))
    try h.close()
}

@Suite struct CostLedgerTests {
    @Test func roundTrip() throws {
        let l = try ledger()
        for i in 1...3 { try l.append(rec(i)) }
        #expect(try l.records(Rec.self) == [rec(1), rec(2), rec(3)])
        let text = try String(contentsOf: l.fileURL, encoding: .utf8)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 4)
        #expect(text.hasSuffix("\n"))
    }

    @Test func missingFileIsEmpty() throws {
        let l = try ledger()
        #expect(try l.records(Rec.self).isEmpty)
        #expect(try l.repair() == false)
    }

    @Test func truncatedTailIgnoredThenRepaired() throws {
        let l = try ledger()
        try l.append(rec(1))
        try l.append(rec(2))
        try appendRaw(l, "{\"id\":3,\"no")
        #expect(try l.records(Rec.self) == [rec(1), rec(2)])
        #expect(try l.repair() == true)
        #expect(try l.repair() == false)
        #expect(try l.records(Rec.self) == [rec(1), rec(2)])
        #expect(try String(contentsOf: l.fileURL, encoding: .utf8).hasSuffix("}\n"))
    }

    @Test func appendAfterTruncation() throws {
        let l = try ledger()
        try l.append(rec(1))
        try appendRaw(l, "{\"id\":2,\"no")
        try l.append(rec(3))
        #expect(try l.records(Rec.self) == [rec(1), rec(3)])
    }

    @Test func wholeFileTruncatedRepairsToEmpty() throws {
        let l = try ledger()
        try Data("{\"id\":".utf8).write(to: l.fileURL)
        #expect(try l.records(Rec.self).isEmpty)
        #expect(try l.repair() == true)
        #expect(try Data(contentsOf: l.fileURL).isEmpty)
    }

    @Test func middleCorruptionThrows() throws {
        let l = try ledger()
        try l.append(rec(1))
        try appendRaw(l, "garbage\n")
        try l.append(rec(3))
        do { _ = try l.records(Rec.self); Issue.record("should throw") } catch {
            guard case .corrupt = error else { Issue.record("expected corrupt, got \(error)"); return }
        }
    }
}
