import BBModel
import Foundation
import Testing
@testable import BBStore

@Suite struct Phase16bCostImportTests {
    @Test func protectedVersionAndLineageAreKept() async throws {
        var book = try DiskBook.make(title: "Protect")
        defer { try? FileManager.default.removeItem(at: book.dir) }
        let storyID = try #require(book.content.book.pageOrder.first)
        let (_, slot) = try #require(book.content.pages[storyID]?.images.first)
        let parent = try await book.addVersion("parent", to: slot.sessionID)
        let child = try await book.addVersion("child", to: slot.sessionID)
        book.content.sessions[slot.sessionID]?.versions[1].parent = parent.id
        let loose = try await book.addVersion("loose", to: slot.sessionID)

        let plain = CleanUp.plan(for: book.content) { _ in 1 }
        #expect(plain.versionIDs.isSuperset(of: [parent.id, child.id, loose.id]))
        let protected = CleanUp.plan(for: book.content, protecting: [child.id]) { _ in 1 }
        #expect(!protected.versionIDs.contains(child.id))
        #expect(!protected.versionIDs.contains(parent.id))
        #expect(protected.versionIDs.contains(loose.id))
    }

    @Test func lenientLedgerSkipsBadMiddleLine() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = CostLedger(packageURL: dir)
        func rec() -> CostRecord {
            CostRecord(at: Date(timeIntervalSince1970: 1), kind: .image, provider: .openai, model: "m",
                       quality: .draft, target: nil, status: .completed, estimated: 1, actual: nil,
                       basis: .estimate, priceListAsOf: nil)
        }
        try ledger.append(rec())
        let handle = try FileHandle(forWritingTo: ledger.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        try ledger.append(rec())

        #expect(throws: StoreError.self) { try ledger.records(CostRecord.self) }
        let read = try ledger.lenientRecords(CostRecord.self)
        #expect(read.records.count == 2)
        #expect(read.skipped == 1)
    }

    @Test func importedRoleIsClearedWhenTargetHasIt() throws {
        var target = try sampleContent()
        target.templates = target.templates.filter { $0.value.pageRole == nil }
        let holder = Template(name: "Holder", kind: .single, boxes: [], pageRole: .dedication)
        target.templates[holder.id] = holder
        var source = try sampleContent()
        let a = Template(name: "Imported Role", kind: .single, boxes: [], pageRole: .dedication)
        let b = Template(name: "Second Role", kind: .single, boxes: [], pageRole: .theEnd)
        source.templates[a.id] = a
        source.templates[b.id] = b
        let sel = BookImportSelection(templates: [a.id, b.id])
        #expect(BookImporter.roleDemotions(source: source, target: target, selection: sel) == [a.id])
        let built = try BookImporter.build(source: source, target: target, selection: sel)
        let byName = Dictionary(uniqueKeysWithValues: built.templates.map { ($0.name, $0) })
        #expect(byName["Imported Role"]?.pageRole == nil)
        #expect(byName["Second Role"]?.pageRole == .theEnd)
    }

    @Test func twoImportedTemplatesSameRoleKeepOnlyFirst() throws {
        var target = try sampleContent()
        target.templates = target.templates.filter { $0.value.pageRole == nil }
        var source = try sampleContent()
        let a = Template(name: "A", kind: .single, boxes: [], pageRole: .belongsTo)
        let b = Template(name: "B", kind: .single, boxes: [], pageRole: .belongsTo)
        source.templates[a.id] = a
        source.templates[b.id] = b
        let built = try BookImporter.build(source: source, target: target,
                                           selection: BookImportSelection(templates: [a.id, b.id]))
        #expect(built.templates.map(\.pageRole) == [.belongsTo, nil])
    }
}
