import BBAICore
import BBModel
import Foundation
@testable import BBAI

/// Builds assets with real sessions and chosen versions inside a `BookContent` (Phase 10).
/// Image refs are named `<name>-primary`, `<name>-view-<view>`, `<name>-expr-<expression>`, `<name>-slot-<label>`.
enum Cast {
    struct Options {
        var primaryChosen = true
        /// Sheet items with a chosen version; nil = all of them.
        var chosenSheet: Set<SheetItemKind>?
        var lockedSheet: Set<SheetItemKind> = []
        var customExpressions: [String] = []
        /// Extra (non-primary) reference slots, all chosen.
        var extraSlots: [String] = []
        var primaryIsRealPerson = false
    }

    static func slug(_ name: String) -> String { name.lowercased().replacingOccurrences(of: " ", with: "-") }

    static func ref(_ name: String, _ suffix: String) -> ImageRef {
        ImageRef(sha256: "\(slug(name))-\(suffix)", contentType: "public.png")
    }

    static func suffix(_ kind: SheetItemKind) -> String {
        switch kind {
        case let .view(view): "view-\(view.rawValue)"
        case let .expression(name): "expr-\(name)"
        }
    }

    @discardableResult
    static func add(_ type: AssetType, _ name: String, description: String = "", revision: Int = 1,
                    options: Options = Options(), to content: inout BookContent) -> Asset {
        var asset = Asset.makeNew(type: type, name: name)
        asset.description = description
        asset.revision = revision
        asset.revisionHighWater = revision
        asset.references += options.extraSlots.map { ReferenceSlot(label: $0, isPrimary: false) }
        if type == .character {
            asset.sheet?.items += options.customExpressions.map { SheetItem(kind: .expression($0)) }
        }
        func makeVersion(_ ref: ImageRef, realPerson: Bool = false) -> Version {
            Version(image: ref, pixelSize: PixelSize(width: 1024, height: 1024), source: realPerson ? .imported : .generated,
                    createdAt: Date(timeIntervalSince1970: 0), depictsRealPerson: realPerson ? true : nil)
        }
        for index in asset.references.indices {
            let slot = asset.references[index]
            var session = Session(id: slot.sessionID, owner: .assetReference(asset.id, slot.id))
            let chosen = slot.isPrimary ? options.primaryChosen : true
            if chosen {
                let version = makeVersion(ref(name, slot.isPrimary ? "primary" : "slot-\(slug(slot.label))"),
                                          realPerson: slot.isPrimary && options.primaryIsRealPerson)
                session.versions = [version]
                asset.references[index].chosen = version.id
            }
            content.sessions[session.id] = session
        }
        for index in (asset.sheet?.items ?? []).indices {
            let item = asset.sheet!.items[index]
            var session = Session(id: item.sessionID, owner: .sheetItem(asset.id, item.id))
            if options.chosenSheet?.contains(item.kind) ?? true {
                let version = makeVersion(ref(name, suffix(item.kind)))
                session.versions = [version]
                asset.sheet!.items[index].chosen = version.id
            }
            asset.sheet!.items[index].locked = options.lockedSheet.contains(item.kind)
            content.sessions[session.id] = session
        }
        content.assets[asset.id] = asset
        return asset
    }

    /// Bytes for every version image and style reference in the book.
    static func imageData(_ content: BookContent, size: Int = 8) -> [ImageRef: Data] {
        var data: [ImageRef: Data] = [:]
        for session in content.sessions.values { for version in session.versions { data[version.image] = Data(count: size) } }
        for ref in content.style.styleReferences { data[ref] = Data(count: size) }
        return data
    }

    static func sheetItem(_ asset: Asset, _ kind: SheetItemKind) -> SheetItem? {
        asset.sheet?.items.first { $0.kind == kind }
    }
}

/// "@Name" in stored form.
func mention(_ asset: Asset) -> String { MentionText.token(for: asset.id) }

func assetIntent(_ message: String, story: Bool = false) -> GenerationIntent {
    intent(message, story: story)
}

func assemble(_ target: GenerationTarget, _ intent: GenerationIntent, content: BookContent, messageID: MessageID? = nil,
              model: CatalogModel? = nil, imageData: [ImageRef: Data]? = nil) throws -> (ImageRequest, AssemblyReport) {
    try ContextAssembler.assemble(intent: intent, target: target, messageID: messageID, content: content,
                                  model: model ?? testModel(), imageData: imageData ?? Cast.imageData(content))
}

func sentLabels(_ report: AssemblyReport) -> [String] { report.referencesSent.map(\.label) }
