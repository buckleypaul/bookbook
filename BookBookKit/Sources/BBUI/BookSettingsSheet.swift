import BBAI
import BBModel
import BBStore
import SwiftUI

/// Book Settings (PD §8.12, Phase 5 minimum): the title and author shown on the cover and the
/// title page. Neither is undoable (PD §8.10): the title goes through `AppModel.rename` (so the
/// library updates) and the author through `BookDocument.setAuthor`.
struct BookSettingsSheet: View {
    let document: BookDocument
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    @State private var error: String?
    @State private var saving = false
    @State private var budgetText: String
    @State private var summary = LedgerSummary()
    @State private var storage = StorageModel()
    @State private var confirmCleanUp = false

    init(document: BookDocument) {
        self.document = document
        _title = State(initialValue: document.content.book.title)
        _author = State(initialValue: document.content.book.author)
        _budgetText = State(initialValue: document.content.book.budget.map(CostText.field) ?? "")
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Book Settings").font(.headline)
            Form {
                TextField("Title", text: $title)
                TextField("Author", text: $author)
            }
            .disabled(!document.isEditable)
            Text("The title and author appear on the cover and the title page.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            costSection
            Divider()
            storageSection
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!document.isEditable || trimmedTitle.isEmpty || saving
                              || CostText.parse(budgetText) == .invalid)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { summary = await app.ledgerSummary(for: document.id) }
        .task { await storage.refresh(document) }
    }

    // MARK: Storage (PD §8.12)

    @ViewBuilder
    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Storage").font(.headline)
            HStack {
                Text("Size on disk")
                Spacer()
                Text(storage.sizeText).monospacedDigit().fontWeight(.semibold)
            }
            HStack {
                Button("Clean Up…") { confirmCleanUp = true }
                    .disabled(!document.isEditable || storage.plan.isEmpty || storage.isWorking)
                if storage.plan.isEmpty {
                    Text("Nothing to clean up").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(storage.plan.versionIDs.count) unused \(storage.plan.versionIDs.count == 1 ? "version" : "versions"), frees \(StorageModel.bytes(storage.plan.bytesFreed))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Clean Up deletes versions that aren't starred and aren't used on a page, as an asset's chosen picture or as a sheet item.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Delete \(storage.plan.versionIDs.count) unused versions?", isPresented: $confirmCleanUp) {
            Button("Delete", role: .destructive) {
                Task {
                    if let message = await storage.cleanUp(document) { error = message }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees about \(StorageModel.bytes(storage.plan.bytesFreed)). Starred versions and versions in use are kept. This can't be undone.")
        }
    }

    // MARK: Cost (PD §8.12)

    @ViewBuilder
    private var costSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cost").font(.headline)
            HStack {
                Text("Spent so far")
                Spacer()
                Text(CostText.amount(summary.total)).monospacedDigit().fontWeight(.semibold)
            }
            ForEach(CostKind.allCases, id: \.self) { kind in
                if let amount = summary.byKind[kind], amount != 0 {
                    HStack {
                        Text(Self.costLabel(kind)).foregroundStyle(.secondary)
                        Spacer()
                        Text(CostText.amount(amount)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            if summary.includesEstimates {
                Text("Includes estimates for requests whose actual cost wasn't reported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Budget  $")
                TextField("Budget", text: $budgetText, prompt: Text("None"))
                    .labelsHidden()
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .disabled(!document.isEditable)
                Text("Leave empty for no budget.").font(.caption).foregroundStyle(.secondary)
            }
            if CostText.parse(budgetText) == .invalid {
                Text("Enter an amount such as 25, or leave it empty.").font(.caption).foregroundStyle(.red)
            }
            if !summary.recent.isEmpty {
                DisclosureGroup("Recent Requests") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(summary.recent) { record in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(record.at.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.secondary)
                                    Text(CostText.kindName(record.kind))
                                    Text(record.model + (record.quality.map { " · " + VersionDetailsContent.qualityName($0) } ?? ""))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Text(CostText.statusName(record.status)).foregroundStyle(.secondary)
                                    Text(CostText.record(record)).monospacedDigit()
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
    }

    /// The breakdown labels of PD §8.12: images, consistency checks, templates.
    static func costLabel(_ kind: CostKind) -> String {
        switch kind {
        case .image: "Images"
        case .consistency: "Consistency checks"
        case .template: "Templates"
        }
    }

    /// Title first, then the author only once the title has been applied, so a failed rename
    /// doesn't leave the book half-changed.
    private func save() {
        let book = document.content.book
        switch CostText.parse(budgetText) {
        case .empty: if book.budget != nil { _ = app.setBudget(nil, in: document) }
        case let .value(v): if book.budget != v { _ = app.setBudget(v, in: document) }
        case .invalid: return
        }
        let newAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let applyAuthor = {
            if newAuthor == document.content.book.author || document.setAuthor(newAuthor) {
                dismiss()
            } else {
                error = "Couldn't change the author."
            }
        }
        guard trimmedTitle != book.title else {
            applyAuthor()
            return
        }
        guard let entry = app.entry(for: document.id) else {
            // Not in the library index (yet): set it on the open book directly.
            if document.rename(to: trimmedTitle) { applyAuthor() } else { error = "Couldn't change the title." }
            return
        }
        saving = true
        let title = trimmedTitle
        Task {
            defer { saving = false }
            do {
                try await app.rename(entry, to: title)
                applyAuthor()
            } catch {
                self.error = "Couldn't change the title. \(StoreErrorText.message(for: error))"
            }
        }
    }
}

/// Size on disk and the Clean up flow of Book Settings (PD §8.12, A §10).
@MainActor @Observable
final class StorageModel {
    private(set) var size: Int64 = 0
    private(set) var plan = CleanUpPlan(versionIDs: [], fileNames: [], bytesFreed: 0)
    private(set) var isWorking = false

    var sizeText: String { Self.bytes(size) }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    func refresh(_ document: BookDocument) async {
        let store = document.store
        plan = CleanUp.plan(for: document.content) { store.imageFileSize($0) }
        size = await Task.detached { store.sizeOnDisk() }.value
    }

    /// Applies the plan: removes the versions (not undoable), saves, then deletes the files that
    /// nothing uses any more. Returns an error message, or nil.
    func cleanUp(_ document: BookDocument) async -> String? {
        guard document.isEditable, !plan.isEmpty, !isWorking else { return nil }
        isWorking = true
        defer { isWorking = false }
        let store = document.store
        let plan = CleanUp.plan(for: document.content) { store.imageFileSize($0) }
        let affected = CleanUp.affectedSessions(plan, in: document.content)
        document.performIrreversible { content in
            CleanUp.apply(plan, to: &content)
            return DirtySet(sessions: affected)
        }
        await document.flush()
        var message: String?
        if document.lastSaveError == nil {
            // Earlier undo steps may point at the versions and files just deleted (PD §8.12:
            // Clean up cannot be undone), so the window's undo history goes with them.
            document.undoManager?.removeAllActions()
        }
        if document.lastSaveError != nil {
            message = "Couldn't save the cleaned-up book, so no picture files were deleted."
        } else {
            do {
                try await store.deleteImages(named: plan.fileNames)
            } catch {
                message = "Some picture files couldn't be deleted. \(StoreErrorText.message(for: error))"
            }
        }
        await refresh(document)
        return message
    }
}
