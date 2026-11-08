import BBModel
import Foundation
import Testing
@testable import BBStore

/// Phase 6: template files are deleted in the save's journal transaction, and a delete
/// followed by an undo (re-insert) writes the file back.
@Suite struct TemplateDeletionTests {
    @Test func deleteRemovesFile_undoRestoresAfterReload() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        let extra = Template(name: "Extra", kind: .single,
                             boxes: [Box(frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1), content: .image)])
        content.templates[extra.id] = extra
        try BookStore.create(content, at: url)
        let file = url.appending(path: PackageCoding.templatePath(extra.id))
        #expect(exists(file))
        let store = BookStore(packageURL: url)

        content.templates[extra.id] = nil
        try await store.save(content, dirty: DirtySet(deletedTemplates: [extra.id]))
        #expect(!exists(file))
        #expect(try await BookStore(packageURL: url).load().templates[extra.id] == nil)

        content.templates[extra.id] = extra
        try await store.save(content, dirty: DirtySet(templates: [extra.id]))
        #expect(exists(file))
        #expect(try await BookStore(packageURL: url).load().templates[extra.id] == extra)
    }

    @Test func deleteThenReinsertInOneSaveWritesIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "B.bookbook")
        var content = try sampleContent()
        let extra = Template(name: "Extra", kind: .single, boxes: [])
        content.templates[extra.id] = extra
        try BookStore.create(content, at: url)

        // Accumulated like the autosave: delete, then undo.
        var dirty = DirtySet(deletedTemplates: [extra.id])
        dirty.formUnion(DirtySet(templates: [extra.id]))
        #expect(dirty.deletedTemplates.isEmpty && dirty.templates == [extra.id])
        // And the reverse order.
        var reverse = DirtySet(templates: [extra.id])
        reverse.formUnion(DirtySet(deletedTemplates: [extra.id]))
        #expect(reverse.templates.isEmpty && reverse.deletedTemplates == [extra.id])

        let store = BookStore(packageURL: url)
        try await store.save(content, dirty: dirty)
        #expect(try await BookStore(packageURL: url).load().templates[extra.id] == extra)
        // Even an inconsistent set (both) resolves to a write.
        try await store.save(content, dirty: DirtySet(templates: [extra.id], deletedTemplates: [extra.id]))
        #expect(exists(url.appending(path: PackageCoding.templatePath(extra.id))))
    }
}
