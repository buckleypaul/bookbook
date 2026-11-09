import BBAI
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

            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }

            CostSettings()
                .tabItem { Label("Cost", systemImage: "dollarsign.circle") }
        }
        .frame(width: 580, height: 480)
    }
}

/// The OpenAI key goes only to the Keychain: the field is plain view state (never
/// `@AppStorage`/`@SceneStorage`), is cleared once saved, and nothing logs it.
struct APIKeysSettings: View {
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var error: String?
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?
    @Environment(\.openWindow) private var openWindow

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
                connectionTest
                Button("Show Guided Setup…") { openWindow(id: OnboardingScene.id) }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("BookBook keeps your key in the macOS Keychain and sends it only to OpenAI.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { app.refreshKeyStatus() }
        .onDisappear { draft = ""; testResult = nil }
    }

    @ViewBuilder
    private var connectionTest: some View {
        HStack {
            Button("Test Connection") { runTest() }
                .disabled(!app.hasOpenAIKey || testing)
            if testing { ProgressView().controlSize(.small) }
            Spacer()
        }
        switch testResult {
        case let .success(count):
            Label("Connected — \(count) models available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case let .failure(advice):
            FailureAdviceView(advice: advice)
        case nil:
            EmptyView()
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            testResult = await app.testConnection(.openai)
            testing = false
        }
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
