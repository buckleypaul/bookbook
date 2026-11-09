import SwiftUI

extension Binding {
    /// True while the optional holds a value; setting false clears it. For alerts, dialogs and
    /// sheets driven by an optional (`isPresented: $problem.isPresent()`).
    func isPresent<Wrapped: Sendable>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}
