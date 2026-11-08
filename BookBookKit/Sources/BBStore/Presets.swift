import BBModel
import Foundation

/// Built-in presets bundled in `Resources/Presets/` (A §3, §10).
public enum Presets {
    /// Fixed IDs of the Phase 2 templates.
    public static let storyTemplateID = TemplateID("A1B2C3D4-0001-4000-8000-000000000001")
    public static let coverTemplateID = TemplateID("A1B2C3D4-0002-4000-8000-000000000001")

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
