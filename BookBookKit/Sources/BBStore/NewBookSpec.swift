import BBModel
import Foundation

/// The new-book wizard's output (PD §8.13). Every field is optional/skippable; nil means
/// "keep the default".
public struct NewBookSpec: Hashable, Sendable {
    public var title: String
    public var author: String
    /// Page size and orientation; nil = default (Letter portrait).
    public var pageSize: PageSizePreset?
    public var orientation: Orientation?
    /// `StylePreset.id`; nil = no preset.
    public var stylePresetID: String?
    /// Optional main character: becomes a `.character` asset with this name and description.
    public var mainCharacter: MainCharacter?
    /// Ask to import story text once the book opens.
    public var importStoryAfter: Bool

    public struct MainCharacter: Hashable, Sendable {
        public var name: String
        public var description: String
        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public init(title: String, author: String = "", pageSize: PageSizePreset? = nil,
                orientation: Orientation? = nil, stylePresetID: String? = nil,
                mainCharacter: MainCharacter? = nil, importStoryAfter: Bool = false) {
        self.title = title
        self.author = author
        self.pageSize = pageSize
        self.orientation = orientation
        self.stylePresetID = stylePresetID
        self.mainCharacter = mainCharacter
        self.importStoryAfter = importStoryAfter
    }
}

extension NewBookSpec {
    /// The title as stored: trimmed, "Untitled" when blank.
    public var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// `content` (a fresh default book) with every wizard choice applied (PD §8.13). This is
    /// creation, not an edit: no `BookCommand`, and the new book's undo stack starts empty.
    ///
    /// - Page setup: `PageSetup.applying(preset:orientation:)`, the transform the Style tab uses.
    ///   Templates are stored in page-relative units, so a fresh book needs nothing else adapted.
    /// - Style preset: description, negative guidance and `presetID`, as `StyleTabModel.choosePreset`
    ///   does (via `StyleGuide.applying`, which also bumps the visual revision).
    /// - Main character: a `.character` asset with name and description, and the image session
    ///   that `.addAsset` would create for it.
    ///
    /// An unknown `stylePresetID` is ignored. An all-default spec returns `content` unchanged
    /// apart from title and author.
    public func apply(to content: BookContent, presets: [StylePreset]? = nil) -> BookContent {
        var result = content
        result.book.title = resolvedTitle
        result.book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)

        if let pageSize {
            let orientation = orientation ?? .portrait
            result.style.pageSetup = result.style.pageSetup.applying(preset: pageSize, orientation: orientation)
        } else if let orientation, result.style.pageSetup.sizePreset != .custom {
            result.style.pageSetup = result.style.pageSetup.applying(
                preset: result.style.pageSetup.sizePreset, orientation: orientation)
        }

        if let stylePresetID {
            let all = presets ?? ((try? Presets.stylePresets()) ?? [])
            if let preset = all.first(where: { $0.id == stylePresetID }) {
                var visual = result.style.visual
                visual.presetID = preset.id
                visual.visualDescription = preset.visualDescription
                visual.negativeGuidance = preset.negativeGuidance ?? StyleGuide.defaultNegativeGuidance
                result.style = result.style.applying(visual)
            }
        }

        if let character = mainCharacter {
            let name = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = character.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty || !text.isEmpty {
                var asset = Asset.makeNew(type: .character, name: name.isEmpty ? "Main character" : name)
                asset.description = text
                result.sessions[asset.sessionID] = Session(id: asset.sessionID, owner: asset.owner)
                result.assets[asset.id] = asset
            }
        }
        return result
    }
}
