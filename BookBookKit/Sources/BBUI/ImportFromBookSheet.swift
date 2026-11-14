import BBModel
import BBStore
import SwiftUI

/// The state and steps of "Import from Book…" (PD §8.1): pick a source book, tick assets,
/// templates and the style guide, rename clashes, then copy the images and run the undoable
/// `.importFromBook` command. The source is read without taking its lock, never written.
@MainActor @Observable
final class ImportFromBookModel {
    enum Step: Hashable { case choose, rename }

    let document: BookDocument
    private(set) var sourceURL: URL?
    private(set) var source: BookContent?
    /// The source's assets and templates by name, sorted once when the source loads.
    private(set) var sourceAssets: [Asset] = []
    private(set) var sourceTemplates: [Template] = []
    var selection = BookImportSelection()
    var renames: [BookImportItem: String] = [:]
    private(set) var step: Step = .choose
    private(set) var renameItems: [BookImportClash] = []
    private(set) var error: String?
    private(set) var isWorking = false
    private(set) var isDone = false

    init(document: BookDocument) { self.document = document }

    // MARK: Source

    /// Reads the book at `url` read-only (no lock) and resets the selection.
    func loadSource(at url: URL) async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        selection = BookImportSelection()
        renames = [:]
        step = .choose
        let store = BookStore(packageURL: url)
        await store.setReadOnly()
        do {
            let loaded = try await store.load()
            source = loaded
            sourceURL = url
            sourceAssets = loaded.assets.values.sorted {
                ($0.name.lowercased(), $0.id.rawValue.uuidString) < ($1.name.lowercased(), $1.id.rawValue.uuidString)
            }
            sourceTemplates = loaded.templates.values.sorted {
                ($0.name.lowercased(), $0.id.rawValue.uuidString) < ($1.name.lowercased(), $1.id.rawValue.uuidString)
            }
        } catch {
            source = nil
            sourceURL = nil
            sourceAssets = []
            sourceTemplates = []
            self.error = "Couldn't read that book. \(StoreErrorText.message(for: error))"
        }
    }

    // MARK: Clashes

    /// Clashes after the current renames, from `BookImporter.build`'s own check.
    var remainingClashes: [BookImportClash] {
        guard let source else { return [] }
        return BookImporter.clashes(source: source, target: document.content, selection: selection, renames: renames)
    }

    /// Selected templates whose front/back-matter role is dropped because the book already has it.
    var demotedTemplates: [Template] {
        guard let source else { return [] }
        let ids = BookImporter.roleDemotions(source: source, target: document.content, selection: selection)
        return sourceTemplates.filter { ids.contains($0.id) }
    }

    var hasNameClashes: Bool { !remainingClashes.isEmpty }

    func name(of item: BookImportItem) -> String {
        switch item {
        case let .asset(id): source?.assets[id]?.name ?? ""
        case let .template(id): source?.templates[id]?.name ?? ""
        }
    }

    func kindLabel(of item: BookImportItem) -> String {
        switch item {
        case let .asset(id): source?.assets[id].map { AssetTypeText.name($0.type) } ?? "Asset"
        case .template: "Template"
        }
    }

    /// Fills each clashing item with "<name> 2", "<name> 3", … until nothing clashes.
    func prefillRenames() {
        renameItems = remainingClashes
        for clash in renameItems {
            let base = name(of: clash.item).trimmingCharacters(in: .whitespacesAndNewlines)
            var n = 2
            while true {
                renames[clash.item] = "\(base) \(n)"
                if !remainingClashes.contains(where: { $0.item == clash.item }) { break }
                n += 1
            }
        }
    }

    // MARK: Steps

    var canContinue: Bool {
        source != nil && !selection.isEmpty && !isWorking && document.isEditable
    }

    /// "Continue": goes to the rename step when names clash, otherwise imports.
    func advance() async {
        guard canContinue else { return }
        if step == .choose, hasNameClashes {
            prefillRenames()
            step = .rename
            return
        }
        await runImport()
    }

    func back() {
        step = .choose
        error = nil
    }

    var canImport: Bool { canImport(clashes: remainingClashes) }

    /// `canImport` with `remainingClashes` already computed (the sheet computes them once per render).
    func canImport(clashes: [BookImportClash]) -> Bool {
        canContinue && clashes.isEmpty
            && renames.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func runImport() async {
        guard let source, let sourceURL, canContinue else { return }
        isWorking = true
        defer { isWorking = false }
        error = nil
        let trimmed = renames.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            let imported = try BookImporter.build(source: source, target: document.content,
                                                  selection: selection, renames: trimmed)
            _ = try await BookImporter.copyImages(imported.images, from: sourceURL, into: document.store)
            if selection.styleGuide {
                // The style guide's typography names fonts; bring their files along (not undoable,
                // like any font import). A font that can't be read doesn't stop the import.
                for url in BookStore(packageURL: sourceURL).fontFileURLs() {
                    _ = try? await document.importFont(from: url)
                }
            }
            guard document.perform(.importFromBook(imported)) else {
                error = "Nothing was imported."
                return
            }
            isDone = true
        } catch let BookImportError.unresolvedClashes(list) {
            error = "These names are already used: \(list.map(\.name).joined(separator: ", "))."
        } catch BookImportError.missingSourceItem {
            error = "Something you picked is no longer in the source book. Pick it again."
        } catch let storeError as StoreError {
            error = "Couldn't copy the pictures. \(StoreErrorText.message(for: storeError))"
        } catch {
            self.error = "The import failed."
        }
    }
}

struct ImportFromBookSheet: View {
    let document: BookDocument
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: ImportFromBookModel
    @State private var chosenBook: BookID?

    init(document: BookDocument) {
        self.document = document
        _model = State(initialValue: ImportFromBookModel(document: document))
    }

    private var otherBooks: [LibraryEntry] {
        app.libraryEntries.filter { $0.id != document.id }
    }

    var body: some View {
        // `BookImporter.clashes` runs once per render.
        let clashes = model.remainingClashes
        VStack(alignment: .leading, spacing: 12) {
            CrayonHeader("Import from Book", color: Crayon.grape)
            switch model.step {
            case .choose: chooseStep
            case .rename: renameStep(clashes: clashes)
            }
            if let error = model.error {
                CrayonInlineMessage(error, kind: .warning, textStyle: .callout)
            }
            CrayonSheetFooter(model.step == .rename || clashes.isEmpty ? "Import" : "Continue", color: Crayon.grape,
                              isDisabled: model.step == .rename ? !model.canImport(clashes: clashes) : !model.canContinue) {
                Task {
                    await model.advance()
                    if model.isDone { dismiss() }
                }
            } leading: {
                if model.isWorking { ProgressView().controlSize(.small) }
            } secondary: {
                if model.step == .rename { Button("Back") { model.back() } }
            }
        }
        .crayonSheet(width: 480)
    }

    // MARK: Choose

    @ViewBuilder
    private var chooseStep: some View {
        if otherBooks.isEmpty {
            Text("There are no other books in your library to import from.")
                .foregroundStyle(Crayon.inkSoft)
        } else {
            Picker("Source book", selection: $chosenBook) {
                Text("Choose a book").tag(BookID?.none)
                ForEach(otherBooks) { Text($0.title).tag(BookID?.some($0.id)) }
            }
            .onChange(of: chosenBook) { _, id in
                guard let entry = otherBooks.first(where: { $0.id == id }) else { return }
                Task { await model.loadSource(at: entry.url) }
            }
        }
        if model.source != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.sourceAssets.isEmpty && model.sourceTemplates.isEmpty {
                        Text("This book has no assets or templates.").foregroundStyle(Crayon.inkSoft)
                    }
                    if !model.sourceAssets.isEmpty {
                        Text("Assets").font(Crayon.font(.subheadline, weight: .heavy))
                        ForEach(model.sourceAssets) { asset in
                            Toggle(isOn: binding(asset: asset.id)) {
                                HStack {
                                    Text(asset.name.isEmpty ? "Untitled" : asset.name)
                                    Text(AssetTypeText.name(asset.type)).foregroundStyle(Crayon.inkSoft)
                                }
                            }
                        }
                    }
                    if !model.sourceTemplates.isEmpty {
                        Text("Templates").font(Crayon.font(.subheadline, weight: .heavy)).padding(.top, 4)
                        ForEach(model.sourceTemplates) { template in
                            Toggle(template.name, isOn: binding(template: template.id))
                        }
                    }
                    Text("Style").font(Crayon.font(.subheadline, weight: .heavy)).padding(.top, 4)
                    Toggle("Style guide", isOn: Binding(
                        get: { model.selection.styleGuide },
                        set: { model.selection.styleGuide = $0 }))
                    ForEach(model.demotedTemplates) { template in
                        Text("\(template.name) will be kept as a regular template: this book already has a page with that role.")
                            .font(.caption).foregroundStyle(Crayon.inkSoft)
                    }
                    if model.selection.styleGuide {
                        Text("Replaces this book's style guide (page size is kept). You can undo it.")
                            .font(.caption).foregroundStyle(Crayon.inkSoft)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(height: 240)
            .crayonCard(cornerRadius: Crayon.smallCornerRadius)
            Text("Imports are independent copies: editing one doesn't change the other.")
                .font(.caption).foregroundStyle(Crayon.inkSoft)
        }
    }

    private func binding(asset id: AssetID) -> Binding<Bool> {
        Binding(get: { model.selection.assets.contains(id) },
                set: { if $0 { model.selection.assets.insert(id) } else { model.selection.assets.remove(id) } })
    }

    private func binding(template id: TemplateID) -> Binding<Bool> {
        Binding(get: { model.selection.templates.contains(id) },
                set: { if $0 { model.selection.templates.insert(id) } else { model.selection.templates.remove(id) } })
    }

    // MARK: Rename

    @ViewBuilder
    private func renameStep(clashes: [BookImportClash]) -> some View {
        Text("These names are already used in this book. Give each copy a new name.")
            .foregroundStyle(Crayon.inkSoft)
        let stillClashing = Set(clashes.map(\.item))
        ForEach(model.renameItems) { clash in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.kindLabel(of: clash.item)).foregroundStyle(Crayon.inkSoft)
                        .frame(width: 80, alignment: .leading)
                    TextField(model.name(of: clash.item), text: Binding(
                        get: { model.renames[clash.item] ?? "" },
                        set: { model.renames[clash.item] = $0 }))
                }
                if stillClashing.contains(clash.item) {
                    CrayonInlineMessage("That name is already used.", kind: .error)
                }
            }
        }
    }
}
