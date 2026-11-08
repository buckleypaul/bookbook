// SL-3 (implementation-plan.md §4.3): does WindowGroup(for: BookID.self) bring an already-open
// book to the front (opening the same value twice gives one window), and restore windows at
// relaunch, on macOS 27?
//
// Throwaway SwiftUI app shaped like architecture.md §6.1: a Library Window plus a
// WindowGroup(for: BookID.self). Run it through Spikes/scripts/sl3-run.sh, which wraps the
// executable in a real .app bundle (bundle id app.bookbook.spike.sl3) so restoration works.
//
// Launch arguments (all optional):
//   --auto open-twice      open A, open B, open A again; report window counts and the front window
//   --auto restore-setup   open A and B, report, then quit with NSApp.terminate
//   --auto restore-check   open nothing; after a delay report which windows came back, then quit
// Without --auto it is an ordinary app for hand checks.
//
// Output: `SPIKE-RESULT SL-3 <key>: <value>` lines on stdout.

import AppKit
import SwiftUI

struct BookID: Codable, Hashable, Sendable {
    let id: UUID
    static let a = BookID(id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-00000000000A")!)
    static let b = BookID(id: UUID(uuidString: "BBBBBBBB-0000-4000-8000-00000000000B")!)
    var title: String {
        switch self {
        case .a: "Book A"
        case .b: "Book B"
        default: "Book \(id.uuidString.prefix(8))"
        }
    }
}

enum Scenario: String {
    case openTwice = "open-twice"
    case restoreSetup = "restore-setup"
    case restoreCheck = "restore-check"

    static let current: Scenario? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--auto"), args.indices.contains(i + 1) else { return nil }
        return Scenario(rawValue: args[i + 1])
    }()
}

@MainActor
func report(_ key: String, _ value: Any) {
    print("SPIKE-RESULT SL-3 [\(Scenario.current?.rawValue ?? "manual")] \(key): \(value)")
    fflush(stdout)
}

@MainActor
enum WindowCensus {
    static var visible: [NSWindow] { NSApp.windows.filter { $0.isVisible } }
    static func count(_ title: String) -> Int { visible.filter { $0.title == title }.count }
    static var titles: [String] { visible.map(\.title).sorted() }
    /// Front-to-back order of the visible titled windows.
    static var frontToBack: [String] { NSApp.orderedWindows.filter { $0.isVisible }.map(\.title) }

    static func reportAll(_ label: String) {
        report("\(label) windows-for-A", count(BookID.a.title))
        report("\(label) windows-for-B", count(BookID.b.title))
        report("\(label) visible windows", titles)
        report("\(label) front-to-back", frontToBack)
        report("\(label) key window", NSApp.keyWindow?.title ?? "none")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.activate()
            let keep = UserDefaults.standard.object(forKey: "NSQuitAlwaysKeepsWindows")
            report("NSQuitAlwaysKeepsWindows as the app sees it", keep.map { "\($0)" } ?? "unset (system default)")
        }
    }
}

@main
struct SL3App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Library", id: "library") {
            LibraryView()
        }
        WindowGroup(for: BookID.self) { $bookID in
            BookWindow(bookID: bookID)
        }
    }
}

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var ran = false

    var body: some View {
        VStack(spacing: 12) {
            Text("SL-3 Library").font(.title2)
            Button("Open Book A") { openWindow(value: BookID.a) }
            Button("Open Book B") { openWindow(value: BookID.b) }
            Button("Report windows") { WindowCensus.reportAll("manual") }
        }
        .padding(30)
        .frame(minWidth: 280, minHeight: 200)
        .task {
            guard !ran, let scenario = Scenario.current else { return }
            ran = true
            await run(scenario)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func run(_ scenario: Scenario) async {
        await pause(1.0)
        switch scenario {
        case .openTwice:
            openWindow(value: BookID.a)
            await pause(1.0)
            openWindow(value: BookID.b)
            await pause(1.0)
            WindowCensus.reportAll("after A,B")
            openWindow(value: BookID.a)          // the same value again
            await pause(1.5)
            WindowCensus.reportAll("after A again")
            // Bring B to front from another path (a Book window's button would do the same).
            openWindow(value: BookID.b)
            await pause(1.0)
            WindowCensus.reportAll("after B again")
            NSApp.terminate(nil)
        case .restoreSetup:
            openWindow(value: BookID.a)
            await pause(0.8)
            openWindow(value: BookID.b)
            await pause(1.5)
            WindowCensus.reportAll("before quit")
            NSApp.terminate(nil)
        case .restoreCheck:
            await pause(2.0)
            WindowCensus.reportAll("after relaunch")
            NSApp.terminate(nil)
        }
    }
}

struct BookWindow: View {
    let bookID: BookID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            Text(bookID?.title ?? "No book").font(.largeTitle)
            Text(bookID?.id.uuidString ?? "-").font(.caption.monospaced())
            HStack {
                Button("Open Book A") { openWindow(value: BookID.a) }
                Button("Open Book B") { openWindow(value: BookID.b) }
            }
            Button("Report windows") { WindowCensus.reportAll("manual") }
        }
        .padding(30)
        .frame(minWidth: 360, minHeight: 220)
        .navigationTitle(bookID?.title ?? "No book")
    }
}
