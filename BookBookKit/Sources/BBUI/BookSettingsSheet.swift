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
                        Text(CostText.kindName(kind)).foregroundStyle(.secondary)
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
