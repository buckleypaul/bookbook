import BBModel
import Foundation

/// Built-in presets bundled in `Resources/Presets/` (A §3, §10).
public enum Presets {
    /// Fixed IDs of the bundled templates (PD §8.4). 0001–0002 are from Phase 2; the rest
    /// are Phase 5.
    public static let storyTemplateID = TemplateID("A1B2C3D4-0001-4000-8000-000000000001")   // Image above text
    public static let coverTemplateID = TemplateID("A1B2C3D4-0002-4000-8000-000000000001")   // Cover: image, title, author
    public static let fullBleedOverlayTemplateID = TemplateID("A1B2C3D4-0003-4000-8000-000000000001")
    public static let textLeftImageRightTemplateID = TemplateID("A1B2C3D4-0004-4000-8000-000000000001")
    public static let spreadImageTemplateID = TemplateID("A1B2C3D4-0005-4000-8000-000000000001")  // .spread
    /// Text only. Also the blank page inserted to fix a split spread (A §8.1).
    public static let textOnlyTemplateID = TemplateID("A1B2C3D4-0006-4000-8000-000000000001")
    public static let titlePageTemplateID = TemplateID("A1B2C3D4-0007-4000-8000-000000000001")   // pageRole .titlePage, title + author roles
    public static let dedicationTemplateID = TemplateID("A1B2C3D4-0008-4000-8000-000000000001")  // .dedication
    public static let belongsToTemplateID = TemplateID("A1B2C3D4-0009-4000-8000-000000000001")   // .belongsTo
    public static let theEndTemplateID = TemplateID("A1B2C3D4-000A-4000-8000-000000000001")      // .theEnd

    /// Every bundled template. Phase 2 ships two with fixed IDs: the story template
    /// "Image above text" and a cover template.
    public static func templates() throws(StoreError) -> [Template] {
        guard let url = Bundle.module.url(forResource: "TemplatePresets", withExtension: "json",
                                          subdirectory: "Presets") else {
            throw StoreError.notFound("Presets/TemplatePresets.json")
        }
        let data = try PackageCoding.io("read presets") { try Data(contentsOf: url) }
        return try PackageCoding.decode([Template].self, from: data, what: "TemplatePresets.json")
    }

    /// "Image on top, text below" (Phase 2's one story template).
    public static func storyTemplate() throws(StoreError) -> Template {
        try template(storyTemplateID)
    }

    public static func coverTemplate() throws(StoreError) -> Template {
        try template(coverTemplateID)
    }

    private static func template(_ id: TemplateID) throws(StoreError) -> Template {
        guard let t = try templates().first(where: { $0.id == id }) else {
            throw StoreError.notFound("template \(id)")
        }
        return t
    }
}
