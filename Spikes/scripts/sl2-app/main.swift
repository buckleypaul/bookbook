// SL-2 probe app (implementation-plan.md §4.3). Built and run by Spikes/scripts/sl2-run.sh as a
// real, activatable .app, because continuous checking does not run inside the `swift test` host
// (see Spikes/notes/local-spikes.md).
//
// It builds a window with a layer-backed canvas and a TextKit 2 NSTextView on top, with continuous
// spelling and grammar checking and allowsUndo = false, types text with misspellings, and reports:
//   - whether NSTextView.willSwitchToNSLayoutManagerNotification fired (the fallback assertion),
//   - whether textLayoutManager is still non-nil,
//   - which ranges got spelling/grammar markers, read from the NSTextLayoutManager's rendering
//     attributes (key .spellingState). It never touches textView.layoutManager, except in
//     `--mode tk1-control`, which does so on purpose to show the observer works and to read the
//     TextKit 1 temporary attributes for comparison.
//
// Output: `SPIKE-RESULT SL-2 <key>: <value>` lines on stdout, then the app quits.

import AppKit

let arguments = CommandLine.arguments
let mode = arguments.firstIndex(of: "--mode").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "tk2"
let sample = "The quick brwon fox jumpd over the lazzy dog. She go to the park yesterday and they was happy. " +
             "Me and him is going home."

func result(_ key: String, _ value: Any) {
    print("SPIKE-RESULT SL-2 [\(mode)] \(key): \(value)")
    fflush(stdout)
}

final class FallbackObserver: NSObject {
    private(set) var count = 0
    init(_ view: NSTextView) {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(fired(_:)),
                                               name: NSTextView.willSwitchToNSLayoutManagerNotification, object: view)
    }
    @objc private func fired(_ note: Notification) { count += 1 }
}

@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var canvas: NSView!
    var observer: FallbackObserver!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 480),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SL-2 spike (\(mode))"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        content.wantsLayer = true
        window.contentView = content

        canvas = NSView(frame: content.bounds)
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2).cgColor
        let pageLayer = CALayer()
        pageLayer.frame = CGRect(x: 40, y: 40, width: 560, height: 400)
        pageLayer.backgroundColor = NSColor.white.cgColor
        canvas.layer?.addSublayer(pageLayer)
        content.addSubview(canvas)

        textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 80, y: 120, width: 480, height: 240)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.allowsUndo = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont(name: "Georgia", size: 20) ?? .systemFont(ofSize: 20)
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        canvas.addSubview(textView)
        observer = FallbackObserver(textView)

        result("textLayoutManager at start", textView.textLayoutManager != nil)
        if mode == "tk1-control" {
            _ = textView.layoutManager          // CONTROL ONLY: forces the switch to TextKit 1
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        Task { await run() }
    }

    func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Spelling and grammar ranges as UTF-16 offsets.
    func markers() -> (spelling: [String], grammar: [String]) {
        let ns = textView.string as NSString
        var spelling: [String] = [], grammar: [String] = []
        func add(_ raw: Any?, _ range: NSRange) {
            let bits = (raw as? Int) ?? (raw as? NSNumber)?.intValue ?? 0
            if bits & NSAttributedString.SpellingState.spelling.rawValue != 0 { spelling.append(ns.substring(with: range)) }
            if bits & NSAttributedString.SpellingState.grammar.rawValue != 0 { grammar.append(ns.substring(with: range)) }
        }
        if let tlm = textView.textLayoutManager, let storage = tlm.textContentManager {
            tlm.enumerateRenderingAttributes(from: tlm.documentRange.location, reverse: false) { _, attributes, range in
                if let raw = attributes[.spellingState] {
                    let start = storage.offset(from: storage.documentRange.location, to: range.location)
                    let length = storage.offset(from: range.location, to: range.endLocation)
                    add(raw, NSRange(location: start, length: length))
                }
                return true
            }
        } else if mode == "tk1-control", let lm = textView.layoutManager {
            var i = 0
            while i < ns.length {
                var r = NSRange()
                let raw = lm.temporaryAttribute(.spellingState, atCharacterIndex: i, effectiveRange: &r)
                if raw != nil { add(raw, r) }
                i = max(i + 1, NSMaxRange(r))
            }
        }
        return (spelling, grammar)
    }

    func run() async {
        await sleep(1)
        result("app active / window key / first responder",
               "\(NSApp.isActive) / \(window.isKeyWindow) / \(window.firstResponder === textView)")

        // Ground truth from NSSpellChecker (what preflight will use, §8.3).
        let ns = sample as NSString
        let truth = NSSpellChecker.shared.check(
            sample, range: NSRange(location: 0, length: ns.length),
            types: NSTextCheckingTypes(NSTextCheckingResult.CheckingType.spelling.rawValue |
                                       NSTextCheckingResult.CheckingType.grammar.rawValue),
            options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        let truthSpelling = truth.filter { $0.resultType == .spelling }.map { ns.substring(with: $0.range) }
        let truthGrammar = truth.filter { $0.resultType == .grammar }.map { ns.substring(with: $0.range) }
        result("NSSpellChecker spelling", truthSpelling)
        result("NSSpellChecker grammar", truthGrammar)

        // Type the sample a word at a time, like a user.
        let start = Date()
        for word in sample.split(separator: " ", omittingEmptySubsequences: false) {
            textView.insertText(String(word) + " ", replacementRange: textView.selectedRange())
            await sleep(0.02)
        }
        var marks = markers()
        for _ in 0..<80 where marks.spelling.count < truthSpelling.count || marks.grammar.count < truthGrammar.count {
            await sleep(0.1)
            marks = markers()
        }
        await sleep(0.5)
        marks = markers()
        result("seconds until markers", String(format: "%.2f", Date().timeIntervalSince(start)))
        result("spelling markers", marks.spelling)
        result("grammar markers", marks.grammar)
        var inStorage = false
        textView.textStorage?.enumerateAttribute(.spellingState, in: NSRange(location: 0, length: textView.string.utf16.count)) { v, _, _ in
            if v != nil { inStorage = true }
        }
        result("text storage carries spellingState", inStorage)
        result("spelling matches NSSpellChecker", Set(marks.spelling) == Set(truthSpelling))

        // Correct one word and change the font of a range, then re-check.
        let range = (textView.string as NSString).range(of: "brwon")
        if range.location != NSNotFound {
            textView.insertText("brown", replacementRange: range)
            textView.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 22),
                                               range: NSRange(location: 0, length: 3))
            await sleep(1.5)
            result("after correcting 'brwon': spelling markers", markers().spelling)
        }

        result("allowsUndo", textView.allowsUndo)
        result("undoManager canUndo", textView.undoManager?.canUndo ?? false)
        result("textLayoutManager at end", textView.textLayoutManager != nil ? "present (TextKit 2)" : "nil (TextKit 1)")
        result("willSwitchToNSLayoutManager notifications", observer.count)
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probe = Probe()
app.delegate = probe
app.run()
