import BBModel
import BBStore
import SwiftUI

/// The Settings scene (A §6.1): General, and API Keys (A §5.5, plan §2.2).
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            Form {
                LibraryLocationSettings()
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            APIKeysSettings()
                .tabItem { Label("API Keys", systemImage: "key") }
        }
        .frame(width: 520, height: 300)
    }
}

/// The OpenAI key goes only to the Keychain: the field is plain view state (never
/// `@AppStorage`/`@SceneStorage`), is cleared once saved, and nothing logs it.
struct APIKeysSettings: View {
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                SecureField("OpenAI API key", text: $draft, prompt: Text("Paste your key"))
                    .privacySensitive()
                    .onSubmit(save)
                HStack {
                    if app.hasOpenAIKey {
                        Label("Saved in your Keychain", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("No key saved", systemImage: "key.slash").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive, action: remove)
                        .disabled(!app.hasOpenAIKey)
                    Button("Save", action: save)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("BookBook keeps your key in the macOS Keychain and sends it only to OpenAI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { app.refreshKeyStatus() }
        .onDisappear { draft = "" }
    }

    private func save() {
        do {
            if try app.saveOpenAIKey(draft) { error = nil }
            draft = ""
        } catch {
            self.error = StoreErrorText.message(for: error)
            draft = ""
        }
    }

    private func remove() {
        do {
            try app.removeOpenAIKey()
            error = nil
        } catch {
            self.error = StoreErrorText.message(for: error)
        }
    }
}
