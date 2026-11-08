import AppKit
import BBStore
import Foundation
import SwiftUI

/// Where the library folder is (A §5.4, §5.5).
public enum LibraryLocation {
    /// `UserDefaults` key for the chosen library folder.
    public static let defaultsKey = "libraryPath"
    /// Launch argument for throwaway development libraries (`-BookBookLibraryRoot /path`).
    public static let argumentKey = "BookBookLibraryRoot"

    /// Precedence: the launch argument (argument domain only, never saved), then `libraryPath`,
    /// then `Library.defaultRoot`.
    public static func resolve(arguments: [String: Any], defaults: UserDefaults) -> URL {
        if let path = arguments[argumentKey] as? String, !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        if let path = defaults.string(forKey: defaultsKey), !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return Library.defaultRoot
    }
}

/// Settings ▸ General ▸ Library: the folder path, with Choose… and an offer to move the books.
struct LibraryLocationSettings: View {
    @Environment(AppModel.self) private var app
    @State private var chosen: URL?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Location") {
                Text(app.libraryRoot.path(percentEncoded: false))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([app.libraryRoot])
                }
                Button("Choose…", action: choose)
                    .disabled(working)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Each book is a self-contained file in this folder, so you can back it up by copying it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Move your books to the new location?", isPresented: Binding(
            get: { chosen != nil }, set: { if !$0 { chosen = nil } }
        ), presenting: chosen) { url in
            Button("Move Books") { change(to: url, move: true) }
            Button("Don't Move") { change(to: url, move: false) }
            Button("Cancel", role: .cancel) { chosen = nil }
        } message: { url in
            Text("Open books close first. If you don't move them, the books in the current folder stay there and won't appear in the library until you switch back.\n\nNew location: \(url.path(percentEncoded: false))")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for your BookBook library."
        panel.directoryURL = app.libraryRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != app.libraryRoot.standardizedFileURL else { return }
        error = nil
        chosen = url
    }

    private func change(to url: URL, move: Bool) {
        chosen = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await app.changeLibraryLocation(to: url, moveBooks: move)
            } catch {
                self.error = "Not every book could be moved. \(StoreErrorText.message(for: error)) "
                    + "Any books left behind are still in the old folder."
            }
        }
    }
}
