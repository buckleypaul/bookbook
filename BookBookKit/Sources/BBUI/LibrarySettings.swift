import AppKit
import BBAI
import BBStore
import Foundation
import SwiftUI

/// Where the library folder is (A §5.4, §5.5).
public enum LibraryLocation {
    /// `UserDefaults` key for the chosen library folder.
    public static let defaultsKey = "libraryPath"
    /// Launch argument for throwaway development libraries (`-BookBookLibraryRoot /path`).
    public static let argumentKey = "BookBookLibraryRoot"

    /// The `-BookBookLibraryRoot /path` launch argument's folder, or nil when absent or empty.
    public static func argumentRoot(arguments: [String: Any]) -> URL? {
        guard let path = arguments[argumentKey] as? String, !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// Precedence: the launch argument (argument domain only, never saved), then `libraryPath`,
    /// then `Library.defaultRoot`.
    public static func resolve(arguments: [String: Any], defaults: UserDefaults) -> URL {
        if let root = argumentRoot(arguments: arguments) { return root }
        if let path = defaults.string(forKey: defaultsKey), !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return Library.defaultRoot
    }
}

/// The warning before switching the library folder while requests are queued (queue.json is
/// shared by every library, and results for books outside the new library can't be delivered).
enum LibrarySwitchWarning {
    /// Waiting, running or retrying entries (the queue badge count) plus finished-but-undelivered
    /// pictures.
    static func pendingCount(_ snapshot: QueueSnapshot) -> Int {
        QueueBadgeModel(snapshot: snapshot).count + snapshot.undeliveredCount
    }

    static func message(count: Int) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "request is" : "requests are"
        return "\(count) \(noun) still queued for books in the current library; their pictures will be lost. Switch anyway?"
    }
}

/// Settings ▸ General ▸ Library: the folder path, with Choose… and an offer to move the books.
struct LibraryLocationSettings: View {
    @Environment(AppModel.self) private var app
    @State private var chosen: URL?
    @State private var confirmSwitch: URL?
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
        .alert("Switch library?", isPresented: Binding(
            get: { confirmSwitch != nil }, set: { if !$0 { confirmSwitch = nil } }
        ), presenting: confirmSwitch) { url in
            Button("Switch Anyway", role: .destructive) { chosen = url }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(LibrarySwitchWarning.message(count: pendingCount) ?? "")
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
        if pendingCount > 0 { confirmSwitch = url } else { chosen = url }
    }

    private var pendingCount: Int {
        LibrarySwitchWarning.pendingCount(app.queueSnapshot)
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
