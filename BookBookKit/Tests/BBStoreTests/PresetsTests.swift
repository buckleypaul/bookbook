import BBModel
import Testing
@testable import BBStore

@Suite struct TemplatePresetsTests {
    private let expected: [(TemplateID, TemplateKind, PageRole?)] = [
        (Presets.storyTemplateID, .single, nil),
        (Presets.coverTemplateID, .cover, nil),
        (Presets.fullBleedOverlayTemplateID, .single, nil),
        (Presets.textLeftImageRightTemplateID, .single, nil),
        (Presets.spreadImageTemplateID, .spread, nil),
        (Presets.textOnlyTemplateID, .single, nil),
        (Presets.titlePageTemplateID, .single, .titlePage),
        (Presets.dedicationTemplateID, .single, .dedication),
        (Presets.belongsToTemplateID, .single, .belongsTo),
        (Presets.theEndTemplateID, .single, .theEnd),
    ]

    @Test func allDecodeWithUniqueIDsMatchingConstants() throws {
        let all = try Presets.templates()
        #expect(all.count == expected.count)
        #expect(Set(all.map(\.id)).count == all.count)
        let boxIDs = all.flatMap { $0.boxes.map(\.id) }
        #expect(Set(boxIDs).count == boxIDs.count)
        for (id, kind, role) in expected {
            let t = try Presets.template(id)
            #expect(t.kind == kind, "\(t.name)")
            #expect(t.pageRole == role, "\(t.name)")
        }
    }

    @Test func framesWithinUnitSquareAndTextBoxesPresent() throws {
        for t in try Presets.templates() {
            for b in t.boxes {
                let f = b.frame
                #expect(f.x >= 0 && f.y >= 0 && f.x + f.width <= 1.0001 && f.y + f.height <= 1.0001, "\(t.name)")
            }
            #expect(!t.textBoxes.isEmpty || t.kind == .cover, "\(t.name) needs a text box")
            if t.kind != .cover { #expect(!t.textBoxes.isEmpty, "\(t.name)") }
        }
    }

    @Test func coverAndTitlePageRoles() throws {
        let cover = try Presets.coverTemplate()
        #expect(cover.boxes.contains { $0.role == .title })
        #expect(cover.boxes.contains { $0.role == .author })
        let title = try Presets.template(Presets.titlePageTemplateID)
        #expect(title.boxes.contains { $0.role == .title })
        #expect(title.boxes.contains { $0.role == .author })
        #expect(try Presets.textOnlyTemplate().imageBoxes.isEmpty)
    }

    @Test func fullBleedTemplatesBleedAllEdges() throws {
        for id in [Presets.fullBleedOverlayTemplateID, Presets.spreadImageTemplateID] {
            let t = try Presets.template(id)
            #expect(t.imageBoxes.first?.bleedEdges == .all)
        }
    }

    @Test func phase2BoxIDsUnchanged() throws {
        let story = try Presets.storyTemplate()
        #expect(story.boxes.map(\.id.description) == [
            "A1B2C3D4-0001-4000-8000-0000000000B1", "A1B2C3D4-0001-4000-8000-0000000000B2"])
        let cover = try Presets.coverTemplate()
        #expect(Array(cover.boxes.map(\.id.description).prefix(2)) == [
            "A1B2C3D4-0002-4000-8000-0000000000B1", "A1B2C3D4-0002-4000-8000-0000000000B2"])
    }
}
