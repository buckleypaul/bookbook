import SwiftUI

/// The shape of a chat bubble in the session thread: rounded, with a small "tail" corner.
enum ThreadBubble {
    static let shape = UnevenRoundedRectangle(topLeadingRadius: Crayon.cornerRadius,
                                              bottomLeadingRadius: 4,
                                              bottomTrailingRadius: Crayon.cornerRadius,
                                              topTrailingRadius: Crayon.cornerRadius,
                                              style: .continuous)
}
