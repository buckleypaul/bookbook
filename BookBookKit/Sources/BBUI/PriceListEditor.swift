import BBAI
import BBAICore
import SwiftUI

/// Edits a copy of the price list (A §7.10). Save writes the user's `pricelist.json` through
/// `PriceBook.save`; Reset to Built-in removes it. Rates are USD per million tokens.
struct PriceListEditor: View {
    @Environment(AppModel.self) private var app
    @State private var draft: PriceList?
    @State private var error: String?
    @State private var confirmReset = false

    private static let rateOrder = ["textIn", "imageIn", "cachedImageIn", "cachedTextIn", "textOut", "imageOut"]

    private var current: PriceList { app.prices.current }
    private var edited: PriceList { draft ?? current }
    private var isDirty: Bool { edited != current }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Price list").font(.headline)
                Spacer()
                Text(app.prices.isUserCopy ? "Your copy, as of \(edited.asOf)" : "Built-in, as of \(edited.asOf)")
                    .font(.caption).foregroundStyle(Crayon.inkSoft)
            }
            Text("Prices are in US dollars per million tokens. Estimates and each book's cost total use these rates.")
                .font(.caption).foregroundStyle(Crayon.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if let message = app.prices.userCopyError {
                CrayonInlineMessage("Your price list couldn't be used, so the built-in one is in effect. \(message)",
                                    kind: .warning)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(edited.entries.indices, id: \.self) { index in
                    entryRow(index)
                    Divider()
                }
            }
            if let error { CrayonInlineMessage(error, kind: .error) }
            HStack {
                Button("Reset to Built-in…") { confirmReset = true }
                    .disabled(!app.prices.isUserCopy && !isDirty)
                Spacer()
                Button("Revert") { draft = nil }.disabled(!isDirty)
                Button("Save") { save() }.disabled(!isDirty)
            }
        }
        .confirmationDialog("Reset the price list to the built-in one?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Reset to Built-in", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edited prices will be discarded. This can't be undone.")
        }
    }

    private func entryRow(_ index: Int) -> some View {
        let entry = edited.entries[index]
        let keys = Self.rateOrder.filter { entry.perMillionTokens[$0] != nil }
            + entry.perMillionTokens.keys.filter { !Self.rateOrder.contains($0) }.sorted()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(displayName(of: entry)).font(.callout.weight(.semibold))
                    .help(entry.model)
                Text(VersionDetailsContent.providerName(entry.provider)).font(.caption).foregroundStyle(Crayon.inkSoft)
                Spacer()
                if entry.asOf != edited.asOf {
                    Text("as of \(entry.asOf)").font(.caption).foregroundStyle(Crayon.inkSoft)
                }
                if entry.placeholder == true {
                    Text("unchecked").font(.caption2).foregroundStyle(Crayon.warning)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    HStack(spacing: 4) {
                        Text(Self.rateName(key)).font(.caption).foregroundStyle(.secondary)
                            .frame(minWidth: 64, alignment: .leading)
                        TextField(Self.rateName(key), value: rate(index, key), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .multilineTextAlignment(.trailing)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    /// The catalog's display name, as the Models pane shows it; the raw ID when the catalog doesn't list it.
    private func displayName(of entry: PriceEntry) -> String {
        app.catalog.imageModel(provider: entry.provider, id: entry.model)?.displayName
            ?? app.catalog.textModel(provider: entry.provider, id: entry.model)?.displayName
            ?? entry.model
    }

    private func rate(_ index: Int, _ key: String) -> Binding<Decimal> {
        Binding(
            get: { edited.entries[index].perMillionTokens[key] ?? 0 },
            set: { newValue in
                var list = draft ?? current
                guard list.entries.indices.contains(index) else { return }
                list.entries[index].perMillionTokens[key] = max(0, newValue)
                draft = list
            }
        )
    }

    static func rateName(_ key: String) -> String {
        switch key {
        case "textIn": "Text in"
        case "imageIn": "Image in"
        case "imageOut": "Image out"
        case "cachedImageIn": "Cached image"
        case "cachedTextIn": "Cached text"
        case "textOut": "Text out"
        default: key
        }
    }

    private func save() {
        guard var list = draft else { return }
        for index in list.entries.indices where list.entries[index] != current.entries[index] {
            list.entries[index].asOf = Date.now.formatted(.iso8601.year().month().day())
            list.entries[index].placeholder = nil
        }
        do {
            try app.prices.save(list)
            draft = nil
            error = nil
        } catch {
            self.error = "Couldn't save the price list. \(error.localizedDescription)"
        }
    }

    private func reset() {
        do {
            try app.prices.resetToBuiltIn()
            draft = nil
            error = nil
        } catch {
            self.error = "Couldn't reset the price list. \(error.localizedDescription)"
        }
    }
}
