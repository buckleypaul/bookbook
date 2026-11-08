// SL-2 (implementation-plan.md §4.3): can a TextKit 2 NSTextView laid over a layer-backed canvas
// run continuous spelling and grammar checking with allowsUndo = false, without falling back to
// TextKit 1?
//
// A throwaway AppKit window is built programmatically inside the test process: a layer-backed
// "canvas" view with an NSTextView(usingTextLayoutManager: true) as a subview, configured as the
// inline editor will be. The test watches NSTextView.willSwitchToNSLayoutManagerNotification for
// that view (the fallback assertion of architecture.md §8.3), types text with misspellings through
// insertText(_:replacementRange:), pumps events, and then looks for spelling and grammar markers.
//
// On TextKit 2, NSTextView puts its markers in the NSTextLayoutManager's *rendering attributes*
// (key NSAttributedString.Key.spellingState, value NSAttributedString.SpellingState bits), not in
// the text storage. The test reads them with enumerateRenderingAttributes(from:reverse:using:),
// which never touches textView.layoutManager.
//
// FINDING: inside the `swift test` host the markers never appear, for TextKit 2 *or* TextKit 1,
// even with the app activated, the window key and checkTextInDocument(_:) called (the host never
// runs NSApplication.run()). So this test asserts only what holds in-process (no fallback, TextKit 2
// kept, allowsUndo off, the control fires) and records the marker count. The marker check runs in a
// real .app: Spikes/scripts/sl2-run.sh (source Spikes/scripts/sl2-app/main.swift).
//
// Only the clearly-labelled CONTROL test touches textView.layoutManager, on its own view.
//
// Findings are printed as `SPIKE-RESULT SL-2 <key>: <value>` lines.

import AppKit
import Foundation
import Synchronization
import Testing

/// Counts notifications delivered on any thread (selector-based, so nothing non-Sendable is captured).
final class NotificationCounter: NSObject, Sendable {
    private let count = Mutex(0)

    init(_ name: Notification.Name, object: AnyObject) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(received(_:)), name: name, object: object)
    }

    @objc nonisolated private func received(_ note: Notification) {
        count.withLock { $0 += 1 }
    }

    var value: Int { count.withLock { $0 } }

    func stop() { NotificationCenter.default.removeObserver(self) }
}

/// True in a logged-in GUI session (a window server is reachable).
let sl2HasWindowServer = CGSessionCopyCurrentDictionary() != nil

@MainActor
@Suite("SL-2 TextKit 2 spelling and grammar over a layer-backed canvas", .serialized,
       .enabled(if: sl2HasWindowServer, "needs a logged-in GUI session"))
struct SL2SpellCheckTextKit2Tests {
    static func result(_ key: String, _ value: Any) {
        print("SPIKE-RESULT SL-2 \(key): \(value)")
    }

    /// Pumps AppKit events until `condition` holds or `timeout` passes. Returns elapsed seconds.
    @discardableResult
    static func spin(timeout: TimeInterval, until condition: () -> Bool) -> TimeInterval {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { break }
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
        return Date().timeIntervalSince(start)
    }

    struct Harness {
        let window: NSWindow
        let canvas: NSView
        let textView: NSTextView
    }

    /// A window with a layer-backed canvas and a TextKit 2 text view on top of it, configured as
    /// BookBook's inline text editor will be (§8.3): continuous spelling + grammar, no own undo.
    static func makeHarness() -> Harness {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SL-2 spike"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        content.wantsLayer = true
        window.contentView = content

        let canvas = NSView(frame: content.bounds)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2).cgColor
        let pageLayer = CALayer()
        pageLayer.frame = CGRect(x: 40, y: 40, width: 560, height: 400)
        pageLayer.backgroundColor = NSColor.white.cgColor
        canvas.layer?.addSublayer(pageLayer)
        content.addSubview(canvas)

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 80, y: 120, width: 480, height: 240)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.allowsUndo = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont(name: "Georgia", size: 20) ?? .systemFont(ofSize: 20)
        canvas.addSubview(textView)
        app.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(textView)
        return Harness(window: window, canvas: canvas, textView: textView)
    }

    /// Substrings that carry a spellingState rendering attribute, split by kind.
    static func markers(in textView: NSTextView) -> (spelling: [String], grammar: [String]) {
        guard let tlm = textView.textLayoutManager, let storage = tlm.textContentManager else { return ([], []) }
        let ns = textView.string as NSString
        var spelling: [String] = []
        var grammar: [String] = []
        tlm.enumerateRenderingAttributes(from: tlm.documentRange.location, reverse: false) { _, attributes, range in
            if let raw = attributes[.spellingState] {
                let bits = (raw as? Int) ?? (raw as? NSNumber)?.intValue ?? 0
                let start = storage.offset(from: storage.documentRange.location, to: range.location)
                let length = storage.offset(from: range.location, to: range.endLocation)
                let r = NSRange(location: start, length: length)
                if bits & NSAttributedString.SpellingState.spelling.rawValue != 0 { spelling.append(ns.substring(with: r)) }
                if bits & NSAttributedString.SpellingState.grammar.rawValue != 0 { grammar.append(ns.substring(with: r)) }
            }
            return true
        }
        return (spelling, grammar)
    }

    static let sample = "The quick brwon fox jumpd over the lazzy dog. She go to the park yesterday and they was happy."

    @Test("continuous spelling and grammar on TextKit 2 does not fall back to TextKit 1")
    func spellingWithoutFallback() throws {
        let harness = Self.makeHarness()
        let textView = harness.textView
        defer { harness.window.close() }
        let fallback = NotificationCounter(NSTextView.willSwitchToNSLayoutManagerNotification, object: textView)
        defer { fallback.stop() }

        #expect(textView.textLayoutManager != nil, "the view should start on TextKit 2")
        Self.result("canvas layer-backed", harness.canvas.layer != nil)

        textView.insertText(Self.sample, replacementRange: NSRange(location: 0, length: 0))
        #expect(textView.string == Self.sample)

        // Ground truth from the checker itself (what preflight will use, §8.3).
        let ns = Self.sample as NSString
        let truth = NSSpellChecker.shared.check(
            Self.sample, range: NSRange(location: 0, length: ns.length),
            types: NSTextCheckingTypes(NSTextCheckingResult.CheckingType.spelling.rawValue |
                                       NSTextCheckingResult.CheckingType.grammar.rawValue),
            options: nil, inSpellDocumentWithTag: textView.spellCheckerDocumentTag,
            orthography: nil, wordCount: nil)
        let truthSpelling = truth.filter { $0.resultType == .spelling }.map { ns.substring(with: $0.range) }
        Self.result("NSSpellChecker spelling (in test host)", truthSpelling)
        #expect(Set(truthSpelling) == ["brwon", "jumpd", "lazzy"], "NSSpellChecker works in-process")

        // Let continuous checking run, then force a full check too.
        Self.spin(timeout: 3) { !Self.markers(in: textView).spelling.isEmpty }
        textView.checkTextInDocument(nil)
        Self.spin(timeout: 2) { !Self.markers(in: textView).spelling.isEmpty }

        let marks = Self.markers(in: textView)
        Self.result("app active / window key (in test host)", "\(NSApp.isActive) / \(harness.window.isKeyWindow)")
        Self.result("spelling markers in test host (expected none; see sl2-run.sh)", marks.spelling)
        Self.result("grammar markers in test host", marks.grammar)
        Self.result("allowsUndo", textView.allowsUndo)
        Self.result("textLayoutManager after checking",
                    textView.textLayoutManager != nil ? "present (TextKit 2)" : "nil (fell back)")
        Self.result("willSwitchToNSLayoutManager notifications", fallback.value)

        #expect(fallback.value == 0, "continuous checking must not switch the view to TextKit 1")
        #expect(textView.textLayoutManager != nil)
        #expect(!textView.allowsUndo)
    }

    @Test("editing, correcting and restyling keeps TextKit 2 with no undo in the view")
    func editingKeepsTextKit2() throws {
        let harness = Self.makeHarness()
        let textView = harness.textView
        defer { harness.window.close() }
        let fallback = NotificationCounter(NSTextView.willSwitchToNSLayoutManagerNotification, object: textView)
        defer { fallback.stop() }

        textView.insertText("Helo wrld", replacementRange: NSRange(location: 0, length: 0))
        Self.spin(timeout: 0.5) { false }
        textView.insertText("Hello", replacementRange: NSRange(location: 0, length: 4))
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        textView.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 22),
                                           range: NSRange(location: 0, length: 5))
        Self.spin(timeout: 0.5) { false }
        Self.result("after edit: text", textView.string)
        Self.result("after edit: undoManager canUndo", textView.undoManager?.canUndo ?? false)
        Self.result("after edit: willSwitchToNSLayoutManager notifications", fallback.value)
        #expect(textView.string == "Hello wrld")
        #expect(fallback.value == 0)
        #expect(textView.textLayoutManager != nil)
        #expect(textView.undoManager?.canUndo != true, "allowsUndo = false: the view registers no undo")
    }

    /// CONTROL TEST. This is the only place that touches `NSTextView.layoutManager`, on a separate,
    /// throwaway view, to prove the observer above would catch a fallback. Never do this in app code.
    @Test("CONTROL: touching textView.layoutManager does fire the fallback notification")
    func controlLayoutManagerAccessFallsBack() throws {
        let harness = Self.makeHarness()
        let textView = harness.textView
        defer { harness.window.close() }
        let fallback = NotificationCounter(NSTextView.willSwitchToNSLayoutManagerNotification, object: textView)
        defer { fallback.stop() }

        #expect(textView.textLayoutManager != nil)
        _ = textView.layoutManager          // deliberate: this is what the app must never do
        Self.spin(timeout: 0.2) { fallback.value > 0 }
        Self.result("CONTROL notifications after .layoutManager", fallback.value)
        Self.result("CONTROL textLayoutManager after .layoutManager",
                    textView.textLayoutManager == nil ? "nil (TextKit 1)" : "present")
        #expect(fallback.value == 1)
        #expect(textView.textLayoutManager == nil)
    }
}
