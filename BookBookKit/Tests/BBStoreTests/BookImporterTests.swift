import BBModel
import CryptoKit
import Foundation
import Testing
@testable import BBStore

/// A book on disk with real image files, for the Phase 16 importer and clean-up tests.
struct DiskBook {
    var dir: URL
    var url: URL
    var store: BookStore
    var content: BookContent

    static func make(title: String = "Book") throws -> DiskBook {
        let dir = try makeTempDir()
        let url = dir.appending(path: "\(title).bookbook", directoryHint: .isDirectory)
        let content = try sampleContent(title: title)
        try BookStore.create(content, at: url)
        return DiskBook(dir: dir, url: url, store: BookStore(packageURL: url), content: content)
    }

    /// Stores `bytes` as an image and returns a version of it appended to `session`.
    @discardableResult
    mutating func addVersion(_ bytes: String, to sessionID: SessionID, starred: Bool = false) async throws -> Version {
        let ref = try await store.storeImage(Data(bytes.utf8), contentType: "public.png")
        let v = Version(image: ref, pixelSize: PixelSize(width: 10, height: 10), source: .generated,
                        createdAt: testNow, starred: starred)
        content.sessions[sessionID]?.versions.append(v)
        return v
    }

    /// Adds an asset with its session; with `primaryBytes`, a chosen version plus one unchosen extra.
    mutating func addAsset(name: String, type: AssetType = .character, primaryBytes: String?) async throws -> Asset {
        var asset = Asset.makeNew(type: type, name: name)
        asset.description = "desc \(name)"
        content.sessions[asset.sessionID] = Session(id: asset.sessionID, owner: asset.owner)
        if let primaryBytes {
            asset.chosen = try await addVersion(primaryBytes, to: asset.sessionID).id
            // One unchosen extra version that must not be copied.
            try await addVersion("extra-\(name)", to: asset.sessionID)
        }
        content.assets[asset.id] = asset
        return asset
    }

    func fileNames() -> Set<String> {
        let list = (try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: "images").path(percentEncoded: false))) ?? []
        return Set(list)
    }
}

@Suite struct BookImporterTests {
    // MARK: Clashes

    @Test func clashesAgainstTargetCaseAndWhitespaceInsensitive() async throws {
        var src = try DiskBook.make(title: "Src")
        var dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        let pip = try await src.addAsset(name: "Pip", primaryBytes: "pip")
        let oak = try await src.addAsset(name: "Oak", type: .object, primaryBytes: nil)
        _ = try await dst.addAsset(name: "  pIP ", primaryBytes: nil)
        let tmpl = Template(name: "Wide", kind: .single, boxes: [])
        src.content.templates[tmpl.id] = tmpl
        let other = Template(name: "wide", kind: .single, boxes: [])
        dst.content.templates[other.id] = other

        let sel = BookImportSelection(assets: [pip.id, oak.id], templates: [tmpl.id])
        let clashes = BookImporter.clashes(source: src.content, target: dst.content, selection: sel)
        #expect(Set(clashes.map(\.item)) == [.asset(pip.id), .template(tmpl.id)])
    }

    @Test func clashesBetweenSelectedItems() async throws {
        var src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        let a = try await src.addAsset(name: "Fox", primaryBytes: nil)
        let b = try await src.addAsset(name: "fox", type: .place, primaryBytes: nil)
        let c = try await src.addAsset(name: "Owl", primaryBytes: nil)
        let sel = BookImportSelection(assets: [a.id, b.id, c.id])
        let clashes = BookImporter.clashes(source: src.content, target: dst.content, selection: sel)
        #expect(Set(clashes.map(\.item)) == [.asset(a.id), .asset(b.id)])
    }

    @Test func renameResolvesAndClashingRenameStillThrows() async throws {
        var src = try DiskBook.make(title: "Src")
        var dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        let pip = try await src.addAsset(name: "Pip", primaryBytes: nil)
        _ = try await dst.addAsset(name: "Pip", primaryBytes: nil)
        _ = try await dst.addAsset(name: "Pip 2", primaryBytes: nil)
        let sel = BookImportSelection(assets: [pip.id])

        do {
            _ = try BookImporter.build(source: src.content, target: dst.content, selection: sel)
            Issue.record("expected unresolvedClashes")
        } catch {
            #expect(error == .unresolvedClashes([BookImportClash(item: .asset(pip.id), name: "Pip")]))
        }
        do {
            _ = try BookImporter.build(source: src.content, target: dst.content, selection: sel,
                                       renames: [.asset(pip.id): " pip 2"])
            Issue.record("expected unresolvedClashes")
        } catch {
            #expect(error == .unresolvedClashes([BookImportClash(item: .asset(pip.id), name: " pip 2")]))
        }
        let ok = try BookImporter.build(source: src.content, target: dst.content, selection: sel,
                                        renames: [.asset(pip.id): "Pip the Second"])
        #expect(ok.assets.map(\.name) == ["Pip the Second"])
    }

    @Test func missingSourceItemThrows() async throws {
        let src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        let ghost = AssetID()
        do {
            _ = try BookImporter.build(source: src.content, target: dst.content,
                                       selection: BookImportSelection(assets: [ghost]))
            Issue.record("expected missingSourceItem")
        } catch {
            #expect(error == .missingSourceItem(.asset(ghost)))
        }
    }

    // MARK: ID remapping

    @Test func remapsEveryIDAndLinksStayConsistent() async throws {
        var src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        let pip = try await src.addAsset(name: "Pip", primaryBytes: "pip-front")
        var tmpl = try Presets.storyTemplate()
        tmpl.id = TemplateID()
        tmpl.name = "Source layout"
        src.content.templates[tmpl.id] = tmpl
        src.content.style.visualDescription = "watercolour"
        src.content.style.styleReferences = [try await src.store.storeImage(Data("style".utf8), contentType: "public.png")]
        let sel = BookImportSelection(assets: [pip.id], templates: [tmpl.id], styleGuide: true)
        let imp = try BookImporter.build(source: src.content, target: dst.content, selection: sel)

        let asset = try #require(imp.assets.first)
        #expect(asset.id != pip.id)
        #expect(asset.name == "Pip" && asset.description == pip.description)
        #expect(asset.revision == 1)
        #expect(asset.sessionID != pip.sessionID)

        #expect(imp.sessions.count == 1)
        let session = try #require(imp.sessions.first)
        #expect(session.id == asset.sessionID)
        #expect(session.owner == .asset(asset.id))
        #expect(session.messages.isEmpty)
        var oldVersionIDs: Set<VersionID> = []
        for s in src.content.sessions.values { oldVersionIDs.formUnion(s.versions.map(\.id)) }
        let chosen = try #require(asset.chosen)
        #expect(session.versions.map(\.id) == [chosen])   // single copy; the unchosen extra isn't carried
        for v in session.versions {
            #expect(v.source == .imported && v.parent == nil && v.provenance == nil && !oldVersionIDs.contains(v.id))
        }

        let t = try #require(imp.templates.first)
        #expect(t.id != tmpl.id && t.name == tmpl.name && t.boxes.count == tmpl.boxes.count)
        #expect(Set(t.boxes.map(\.id)).isDisjoint(with: Set(tmpl.boxes.map(\.id))))
        #expect(imp.styleGuide == src.content.style)
        #expect(imp.images.count == 2)   // 1 chosen + 1 style reference; the extra isn't included
    }

    @Test func editingTheCopyDoesNotChangeTheSource() async throws {
        var src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        let pip = try await src.addAsset(name: "Pip", primaryBytes: "pip")
        var tmpl = try Presets.storyTemplate()
        tmpl.id = TemplateID()
        tmpl.name = "Source layout"
        src.content.templates[tmpl.id] = tmpl
        let before = src.content
        var imp = try BookImporter.build(source: src.content, target: dst.content,
                                         selection: BookImportSelection(assets: [pip.id], templates: [tmpl.id]))
        imp.assets[0].name = "Changed"
        imp.assets[0].description = "changed"
        imp.templates[0].boxes[0].cornerRadius = 99
        imp.sessions[0].versions.removeAll()
        #expect(src.content == before)
    }

    @Test func styleGuideOnlyWhenSelected() async throws {
        var src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        src.content.style.visualDescription = "ink"
        let without = try BookImporter.build(source: src.content, target: dst.content, selection: BookImportSelection())
        #expect(without.styleGuide == nil)
        let with = try BookImporter.build(source: src.content, target: dst.content,
                                          selection: BookImportSelection(styleGuide: true))
        #expect(with.styleGuide?.visualDescription == "ink")
    }

    // MARK: Image copy

    @Test func copyImagesDedupsByHash() async throws {
        var src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        // Two assets whose chosen images are byte-identical, plus one distinct image.
        let a = try await src.addAsset(name: "A", primaryBytes: "same")
        let b = try await src.addAsset(name: "B", primaryBytes: "same")
        let c = try await src.addAsset(name: "C", primaryBytes: "other")
        let existing = try await dst.store.storeImage(Data("other".utf8), contentType: "public.png")
        _ = existing
        let imp = try BookImporter.build(source: src.content, target: dst.content,
                                         selection: BookImportSelection(assets: [a.id, b.id, c.id]))
        #expect(imp.images.count == 2)   // "same" once, "other" once

        let first = try await BookImporter.copyImages(imp.images, from: src.url, into: dst.store)
        #expect(first == BookImportCopyReport(copied: 1, skippedDuplicates: 1))
        let second = try await BookImporter.copyImages(imp.images, from: src.url, into: dst.store)
        #expect(second == BookImportCopyReport(copied: 0, skippedDuplicates: 2))
        for ref in imp.images { #expect(exists(dst.store.imageURL(for: ref))) }
    }

    @Test func copyImagesRejectsMissingAndCorruptSourceFiles() async throws {
        var src = try DiskBook.make(title: "Src")
        let dst = try DiskBook.make(title: "Dst")
        defer { try? FileManager.default.removeItem(at: src.dir); try? FileManager.default.removeItem(at: dst.dir) }
        let a = try await src.addAsset(name: "A", primaryBytes: "bytes")
        let chosen = try #require(a.chosen)
        let ref = try #require(src.content.sessions[a.sessionID]?.version(chosen)?.image)
        try Data("tampered".utf8).write(to: src.store.imageURL(for: ref))
        do {
            _ = try await BookImporter.copyImages([ref], from: src.url, into: dst.store)
            Issue.record("expected corrupt")
        } catch { #expect(error == .corrupt("images/\(ref.fileName)")) }
        #expect(!exists(dst.store.imageURL(for: ref)))
        try FileManager.default.removeItem(at: src.store.imageURL(for: ref))
        do {
            _ = try await BookImporter.copyImages([ref], from: src.url, into: dst.store)
            Issue.record("expected notFound")
        } catch { #expect(error == .notFound("images/\(ref.fileName)")) }
    }
}
