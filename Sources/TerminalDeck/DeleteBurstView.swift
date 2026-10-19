import SwiftUI
import TerminalDeckKit

/// The farewell of one deleted card: the white flash at the start, then the particles flying
/// out of it.
///
/// Everything is evaluated from the clock rather than animated frame by frame — see
/// `DeleteBurst.position(of:at:)` — so the canvas can be drawn at any moment and a dropped
/// frame cannot bend a particle's path.
struct DeleteBurstView: View {
    let burst: DeleteBurst
    /// The transition's clock; set when the window can paint again.
    let startedAt: Date
    /// The card's own size; the canvas around it is larger by `margin`.
    let cardSize: CGSize

    /// How far outside the card a particle may travel before the canvas clips it. A damped
    /// particle never covers more than `topSpeed / damping` ≈ 112pt, so this is generous.
    static let margin: CGFloat = 120

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if burst.particles.isEmpty {
            // Reduced motion: the card just fades, and `CardShell` handles that.
            EmptyView()
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, _ in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    guard elapsed >= 0, elapsed <= burst.lifetime else { return }
                    drawFlash(&context, at: elapsed)
                    drawParticles(&context, at: elapsed)
                }
            }
            .frame(width: cardSize.width + Self.margin * 2,
                   height: cardSize.height + Self.margin * 2)
            .allowsHitTesting(false)
        }
    }

    /// The card lights up for the first 90ms, then fades out under it.
    private func drawFlash(_ context: inout GraphicsContext, at elapsed: Double) {
        let amount = burst.flashAmount(at: elapsed)
        guard amount > 0.004 else { return }
        // The same white reads much brighter over a dark card, so dark mode gets less of it.
        let peak = colorScheme == .dark ? 0.22 : 0.5
        context.fill(
            Path(roundedRect: cardRect, cornerRadius: DeckTheme.cardRadius),
            with: .color(.white.opacity(amount * peak))
        )
    }

    private func drawParticles(_ context: inout GraphicsContext, at elapsed: Double) {
        let palette = DeckTheme.particlePalette
        for blip in burst.blips(at: elapsed, cardSize: cardSize) {
            let color = palette[blip.colorIndex % palette.count]
            context.fill(
                circle(at: CGPoint(x: Self.margin + blip.x, y: Self.margin + blip.y),
                       radius: blip.radius),
                with: .color(color.opacity(blip.alpha))
            )
        }
    }

    private func circle(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))
    }

    private var cardRect: CGRect {
        CGRect(x: Self.margin, y: Self.margin, width: cardSize.width, height: cardSize.height)
    }
}
