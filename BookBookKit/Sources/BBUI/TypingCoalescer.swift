import BBModel
import Foundation

/// Decides whether a `setRichText` joins the open typing undo step (A §6.3). Pure: no undo
/// manager, no model; the clock is injected so tests can control time.
///
/// An edit coalesces when it's a `setRichText` with `coalescing: true`, for the same page and
/// box as the previous coalescing edit, less than `pause` after it. A box switch, a pause of
/// `pause` or more, a formatting change (`coalescing: false`), any other command, or `close()`
/// ends the step; the next typing edit starts a new one.
struct TypingCoalescer {
    /// The typing pause that ends an undo step.
    static let pause: TimeInterval = 1

    private struct Step {
        var page: PageID
        var box: BoxID
        var lastEdit: Date
    }

    private let clock: () -> Date
    private var open: Step?

    init(clock: @escaping () -> Date) {
        self.clock = clock
    }

    /// True while a typing step is open.
    var isOpen: Bool { open != nil }

    /// Records `command` (which is about to be applied) and returns true if it merges into the
    /// open step, i.e. it must not register a new undo entry.
    mutating func shouldCoalesce(_ command: BookCommand) -> Bool {
        guard case let .setRichText(page, box, _, coalescing) = command, coalescing else {
            open = nil
            return false
        }
        let now = clock()
        defer { open = Step(page: page, box: box, lastEdit: now) }
        guard let step = open, step.page == page, step.box == box else { return false }
        let elapsed = now.timeIntervalSince(step.lastEdit)
        return elapsed >= 0 && elapsed < Self.pause
    }

    /// Ends the open step (undo/redo, the editor closing, a failed edit).
    mutating func close() {
        open = nil
    }
}
