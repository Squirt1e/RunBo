import SwiftUI

/// Immediate feedback, without a spring or an animation that can delay keyboard actions.
struct DeckIconPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? DeckTheme.text.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
    }
}
