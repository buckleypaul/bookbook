import BBAI
import BBAICore
import BBModel
import SwiftUI

/// Settings ▸ Models: default image model and quality, availability, and custom model IDs
/// (PD §8.11, A §7.1).
struct ModelSettings: View {
    @Environment(AppModel.self) private var app
    @State private var customID = ""
    @State private var family = ""
    @State private var addError: String?

    private let provider = ProviderID.openai

    var body: some View {
        @Bindable var prefs = app.preferences
        let models = app.imageModels(for: provider)
        Form {
            Section("Default image model") {
                Picker("Model", selection: $prefs.defaultImageModelID) {
                    ForEach(models, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                ForEach(models, id: \.id) { model in
                    HStack {
                        Text(model.displayName).font(.callout)
                        if model.copiesFrom != nil {
                            Text("custom").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        badge(for: model)
                    }
                }
                if case let .unavailable(successor) = app.missingDefaultModel {
                    switchPrompt(successor: successor)
                }
            }
            Section {
                Picker("Default quality", selection: $prefs.defaultQuality) {
                    ForEach(QualityLevel.allCases, id: \.self) {
                        Text(VersionDetailsContent.qualityName($0)).tag($0)
                    }
                }
            } footer: {
                Text(ModelSettings.qualityExplanation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Templates", selection: $prefs.defaultTemplateModelID) {
                    ForEach(textChoices(.text, selected: prefs.defaultTemplateModelID), id: \.id) {
                        Text($0.displayName).tag($0.id)
                    }
                }
                Picker("Consistency check", selection: $prefs.defaultConsistencyModelID) {
                    ForEach(textChoices(.vision, selected: prefs.defaultConsistencyModelID), id: \.id) {
                        Text($0.displayName).tag($0.id)
                    }
                }
                Toggle("Check each picture for consistency", isOn: $prefs.consistencyCheckEnabled)
            } header: {
                Text("AI helpers")
            } footer: {
                Text(ModelSettings.consistencyNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(prefs.customModels) { spec in
                    HStack {
                        Text(spec.id).font(.callout.monospaced())
                        Text("copies \(spec.copiesFrom)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", role: .destructive) { app.removeCustomModel(spec) }
                            .controlSize(.small)
                    }
                }
                TextField("Model ID", text: $customID, prompt: Text("Model ID"))
                Picker("Copies", selection: $family) {
                    ForEach(models.filter { $0.copiesFrom == nil }, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                HStack {
                    Spacer()
                    Button("Add") { add(models) }
                        .disabled(customID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Custom model ID")
            } footer: {
                Text("Use a model ID BookBook doesn't list yet. It behaves and is priced like the model it copies.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if family.isEmpty { family = models.first { $0.copiesFrom == nil }?.id ?? "" }
        }
        .task {
            if app.hasOpenAIKey, app.modelAvailability.isEmpty { _ = await app.testConnection(provider) }
        }
    }

    static let qualityExplanation = "Draft is fast and the cheapest, good for trying ideas. Standard suits most pages. "
        + "High takes longer and costs the most, for final art. For OpenAI these map to the low, medium and high "
        + "quality settings."

    static let consistencyNote = "After each picture is made, a small vision model compares it with your characters, "
        + "props and places and warns about differences. It adds a small cost to each picture, a fraction of a cent "
        + "at the default model. You can also check any picture by hand."

    /// Non-retired catalog models of `kind` (plus the current choice, so the picker never shows blank).
    private func textChoices(_ kind: TextModelKind, selected: String) -> [CatalogTextModel] {
        app.catalog.textModels(kind: kind).filter { $0.status != .retired || $0.id == selected }
    }

    @ViewBuilder
    private func badge(for model: CatalogModel) -> some View {
        switch app.modelAvailability[model.id] ?? .unknown {
        case .available:
            Label("Available", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case let .unavailable(successor):
            HStack(spacing: 6) {
                Label("Unavailable", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.orange)
                if let successor {
                    Button("Switch to \(name(of: successor))") { app.preferences.defaultImageModelID = successor }
                        .controlSize(.small)
                }
            }
        case .unknown:
            Text("Not checked").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func switchPrompt(successor: String?) -> some View {
        HStack {
            Label("Your default model isn't available to your account.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            if let successor {
                Button("Switch to \(name(of: successor))") { app.preferences.defaultImageModelID = successor }
                    .controlSize(.small)
            }
        }
    }

    private func name(of id: String) -> String {
        app.imageModels(for: provider).first { $0.id == id }?.displayName ?? id
    }

    private func add(_ models: [CatalogModel]) {
        let id = customID.trimmingCharacters(in: .whitespaces)
        let chosen = family.isEmpty ? (models.first { $0.copiesFrom == nil }?.id ?? "") : family
        if app.addCustomModel(id: id, copying: chosen, provider: provider) {
            customID = ""
            addError = nil
        } else {
            addError = "Couldn't add \(id). That ID may already exist."
        }
    }
}
