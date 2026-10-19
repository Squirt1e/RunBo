import Foundation

/// The transition that plays when the user confirms deleting a card: the card flashes,
/// fades out, and a burst of particles flies out of it.
///
/// This is pure arithmetic on purpose — no SwiftUI, no display — so the self-check
/// harness can assert the rules (how many particles, where they start, that they are all
/// gone before the card leaves the list) without rendering anything. The app maps
/// `Particle.colorIndex` onto `Theme.particlePalette` and draws the result.
public struct DeleteBurst: Equatable, Sendable {
    /// One particle.
    ///
    /// Position and velocity are in card fractions, not points: the card is as wide as
    /// the window allows (the grid columns are flexible, down to 240pt) and a temporary
    /// terminal card is much shorter than a preset card, so fractions are what keeps the
    /// same burst looking the same on any card. The radius stays in points — particles
    /// are a few points across, and scaling that down with a narrow card would make them
    /// invisible.
    public struct Particle: Equatable, Sendable {
        /// 0…1 across the card, 0 = leading edge.
        public let x: CGFloat
        /// 0…1 down the card, 0 = top edge.
        public let y: CGFloat
        /// Reference points per second, on both axes.
        ///
        /// Points rather than card fractions, so the burst keeps its shape whatever the card's
        /// aspect ratio: a square card and a wide card are the same height, and the view scales
        /// both axes by the height alone.
        public let vx: CGFloat
        public let vy: CGFloat
        /// Radius in points.
        public let radius: CGFloat
        /// Seconds after the burst starts before this particle appears.
        public let birth: Double
        /// Seconds this particle stays visible.
        public let life: Double
        /// Index into the app's particle palette.
        public let colorIndex: Int
    }

    public let particles: [Particle]
    /// How long the card flashes white at the start. Zero when particles are suppressed.
    public let flash: Double
    /// How long the card takes to fade from opaque to invisible.
    public let fade: Double
    /// How long the card stays mounted. Every particle is gone by this point.
    public let lifetime: Double

    // MARK: - Constants

    /// Particles in one burst.
    public static let particleCount = 30
    /// Colours the app is expected to provide; `Particle.colorIndex` stays below this.
    public static let paletteSize = 6
    /// Other cards ease into the freed slot over this long.
    public static let reflow: Double = 0.34
    /// Reduced motion: one short fade, no particles, no waiting around.
    public static let reducedMotionFade: Double = 0.12
    /// Trail samples per particle, and the spacing between them (one frame at 30fps).
    public static let trailCount = 5
    public static let trailStep: Double = 1.0 / 30.0

    private static let flashDuration: Double = 0.09
    private static let fadeDuration: Double = 0.33
    private static let lifetimeDuration: Double = 0.42
    private static let fadeIn: Double = 0.05

    /// Damping of the trajectory, in 1/s. Equivalent to keeping 87% of the speed each
    /// frame at 30fps.
    ///
    /// Public because it is the bound on how far a particle can ever travel:
    /// `speed / damping`. The checks assert against it.
    public static let damping: Double = 3.4
    /// The card the particle speeds were tuned against.
    public static let referenceWidth: CGFloat = 564
    public static let referenceHeight: CGFloat = 149
    private static let inset: CGFloat = 14

    // MARK: - Making a burst

    /// A fresh burst. The seed decides the particle scatter, so the app can pass a random
    /// one for variety while the checks pass a fixed one for reproducibility.
    public static func make(seed: UInt64 = .random(in: .min ... .max)) -> DeleteBurst {
        var generator = SplitMix64(seed: seed)
        let halfWidth = (referenceWidth - inset * 2) / 2 / referenceWidth
        let halfHeight = (referenceHeight - inset * 2) / 2 / referenceHeight

        let particles = (0 ..< particleCount).map { index in
            // Triangular distribution per axis: dense in the middle, sparse at the edges.
            let x = 0.5 + (unit(&generator) + unit(&generator) - 1) * halfWidth
            let y = 0.5 + (unit(&generator) + unit(&generator) - 1) * halfHeight
            let angle = unit(&generator) * 2 * .pi
            let speed = 240 + 240 * unit(&generator)
            return Particle(
                x: x,
                y: y,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed,
                radius: 1.9 + 1.7 * unit(&generator),
                birth: 0.04 * unit(&generator),
                life: 0.20 + 0.18 * unit(&generator),
                colorIndex: index % paletteSize
            )
        }
        return DeleteBurst(particles: particles, flash: flashDuration,
                           fade: fadeDuration, lifetime: lifetimeDuration)
    }

    /// What plays when the system asks for reduced motion: the card simply fades, and the
    /// list is free to move on immediately afterwards.
    public static func reducedMotion() -> DeleteBurst {
        DeleteBurst(particles: [], flash: 0, fade: reducedMotionFade,
                    lifetime: reducedMotionFade)
    }

    // MARK: - Evaluating a burst

    /// A particle's starting point, as a fraction of the card's width and height.
    public func spawn(of particle: Particle) -> CGPoint {
        CGPoint(x: particle.x, y: particle.y)
    }

    /// How far a particle has travelled by `t` seconds after the burst started, in reference
    /// points on both axes.
    ///
    /// The speed only decays (`p(t) = p₀ + v₀·(1 - e^(-k·t)) / k`), so any moment can be
    /// evaluated straight from the clock: no frame-to-frame state, no timer, and a dropped
    /// frame cannot push a particle off its path.
    public func travel(of particle: Particle, at t: Double) -> CGPoint {
        let age = max(0, t - particle.birth)
        let distance = (1 - exp(-Self.damping * age)) / Self.damping
        return CGPoint(x: particle.vx * distance, y: particle.vy * distance)
    }

    /// One circle of a burst at a moment in time, in card-relative points.
    public struct Blip: Equatable, Sendable {
        public let x: CGFloat
        public let y: CGFloat
        public let radius: CGFloat
        public let colorIndex: Int
        public let alpha: Double
    }

    /// Everything to draw at `t` for a card of `size`: each particle's trails first, then its
    /// head, so a head always lands on top of its own trail.
    ///
    /// The whole frame is computed here rather than in the view. That is partly because the
    /// arithmetic belongs with the rules, and partly because the release optimiser trips a SIL
    /// assertion when these calls are made from inside the view's draw loop.
    public func blips(at t: Double, cardSize: CGSize,
                      trails: Int = DeleteBurst.trailCount,
                      trailStep: Double = DeleteBurst.trailStep) -> [Blip] {
        var blips: [Blip] = []
        let scale = cardSize.height / Self.referenceHeight
        for particle in particles {
            let alpha = opacity(of: particle, at: t)
            if alpha <= 0.01 { continue }
            for step in stride(from: 1, through: max(1, trails), by: 1) where trails > 0 {
                let earlier = t - Double(step) * trailStep
                if earlier <= particle.birth { continue }
                let weight = 1 - Double(step) / Double(trails + 1)
                let spot = canvasPoint(of: particle, at: earlier, cardSize: cardSize, scale: scale)
                blips.append(Blip(x: spot.x, y: spot.y,
                                  radius: particle.radius * (0.35 + 0.55 * weight),
                                  colorIndex: particle.colorIndex,
                                  alpha: alpha * 0.22 * weight))
            }
            let head = canvasPoint(of: particle, at: t, cardSize: cardSize, scale: scale)
            // A soft halo first, so a particle reads as a spark rather than a speck — this is
            // what keeps it visible on a dark background.
            blips.append(Blip(x: head.x, y: head.y, radius: particle.radius * 2.3,
                              colorIndex: particle.colorIndex, alpha: alpha * 0.14))
            blips.append(Blip(x: head.x, y: head.y, radius: particle.radius,
                              colorIndex: particle.colorIndex, alpha: alpha))
        }
        return blips
    }

    /// Spawn (a fraction of the card) plus travel (reference points, both axes scaled by the
    /// card's height) in card-relative points.
    private func canvasPoint(of particle: Particle, at t: Double,
                             cardSize: CGSize, scale: CGFloat) -> CGPoint {
        let start = spawn(of: particle)
        let moved = travel(of: particle, at: t)
        return CGPoint(x: start.x * cardSize.width + moved.x * scale,
                       y: start.y * cardSize.height + moved.y * scale)
    }

    /// Spawn plus travel, in fractions of the *reference* card. Used by the checks; the view
    /// composes `spawn` and `travel` itself so it can scale both axes by the card's height.
    public func position(of particle: Particle, at t: Double) -> CGPoint {
        let start = spawn(of: particle)
        let moved = travel(of: particle, at: t)
        return CGPoint(x: start.x + moved.x / Self.referenceWidth,
                       y: start.y + moved.y / Self.referenceHeight)
    }

    /// A particle's opacity at `t`, 0…1: a short fade in, then a linear fade out.
    public func opacity(of particle: Particle, at t: Double) -> Double {
        let age = t - particle.birth
        guard age > 0, age < particle.life else { return 0 }
        return min(1, age / Self.fadeIn) * (1 - age / particle.life)
    }

    /// How white the card is at `t`, 0…1 — the flash at the very start of the burst.
    public func flashAmount(at t: Double) -> Double {
        guard flash > 0, t >= 0, t < flash else { return 0 }
        return 1 - t / flash
    }

    /// True once nothing is left to draw.
    public func isFinished(at t: Double) -> Bool {
        particles.allSatisfy { t >= $0.birth + $0.life }
    }

    /// The moment the last particle disappears, relative to the start of the burst.
    public var particlesEnd: Double {
        particles.map { $0.birth + $0.life }.max() ?? 0
    }
}

/// Deterministic generator, so a seed always produces the same burst.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One uniform sample in 0…1 from a generator.
private func unit(_ generator: inout SplitMix64) -> CGFloat {
    CGFloat(Double.random(in: 0 ..< 1, using: &generator))
}
