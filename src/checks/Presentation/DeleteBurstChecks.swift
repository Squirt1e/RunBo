import Foundation
import Core

/// The delete transition is decoration, but it sits on top of a destructive action, so the
/// facts worth pinning down are the ones a person would notice going wrong: particles that
/// never appear, a card that leaves the list while its particles are still flying, or a
/// burst that differs every time the same seed is used.
func registerDeleteBurstChecks() {
    register("delete-burst.has-the-agreed-particles") {
        let burst = DeleteBurst.make(seed: 42)
        try expectEqual(burst.particles.count, DeleteBurst.particleCount, "particles per burst")
        for particle in burst.particles {
            try expect(
                (0 ..< DeleteBurst.paletteSize).contains(particle.colorIndex),
                "colour index \(particle.colorIndex) must map onto the app's palette"
            )
            try expect(particle.radius >= 1.5 && particle.radius < 6,
                       "a \(particle.radius)pt particle is either invisible or a blob")
            try expect(particle.life > 0.1, "a particle that lives \(particle.life)s barely shows")
        }
    }

    register("delete-burst.particles-start-inside-the-card") {
        // A particle that starts outside the card reads as dust on the page rather than as
        // the card coming apart.
        for seed in UInt64(0) ..< 64 {
            let burst = DeleteBurst.make(seed: seed)
            for particle in burst.particles {
                try expect((0.01 ... 0.99).contains(particle.x),
                           "seed \(seed): x = \(particle.x) is off the card")
                try expect((0.01 ... 0.99).contains(particle.y),
                           "seed \(seed): y = \(particle.y) is off the card")
            }
        }
    }

    register("delete-burst.is-denser-in-the-middle-than-at-the-edges") {
        // The approved look: 中间多一点，四周少一点. A uniform scatter puts a quarter of the
        // particles in the middle quarter of the card, so that is the number to beat — an
        // average is what "denser" means for a random scatter, and one seed is not evidence
        // either way. The per-seed floor only rules out a degenerate burst.
        var middle = 0
        var total = 0
        for seed in UInt64(0) ..< 256 {
            let burst = DeleteBurst.make(seed: seed)
            let inMiddle = burst.particles.filter {
                (0.25 ... 0.75).contains($0.x) && (0.25 ... 0.75).contains($0.y)
            }.count
            try expect(inMiddle >= DeleteBurst.particleCount / 5,
                       "seed \(seed): only \(inMiddle) particles started anywhere near the "
                           + "middle of the card")
            middle += inMiddle
            total += burst.particles.count
        }
        let share = Double(middle) / Double(total)
        try expect(share > 0.45,
                   "only \(Int(share * 100))% of particles started in the middle quarter of the "
                       + "card; a uniform scatter would average 25%")
    }

    register("delete-burst.same-seed-same-burst") {
        let first = DeleteBurst.make(seed: 20_261_012)
        let second = DeleteBurst.make(seed: 20_261_012)
        try expectEqual(first.particles, second.particles, "the same seed must replay exactly")
        try expect(first.particles != DeleteBurst.make(seed: 7).particles,
                   "two seeds should not produce the same scatter")
    }

    register("delete-burst.finishes-before-the-card-leaves-the-list") {
        // `AppModel` removes the card at `lifetime`. If any particle outlived that, the burst
        // would be cut off mid-flight — and no seed may be the exception.
        for seed in UInt64(0) ..< 256 {
            let burst = DeleteBurst.make(seed: seed)
            try expect(burst.particlesEnd <= burst.lifetime,
                       "seed \(seed): the last particle dies at \(burst.particlesEnd)s but the "
                           + "card leaves at \(burst.lifetime)s")
        }
    }

    register("delete-burst.trajectory-is-evaluable-at-any-moment") {
        let burst = DeleteBurst.make(seed: 5)
        for particle in burst.particles {
            let start = burst.spawn(of: particle)
            try expect(abs(start.x - particle.x) < 0.0001 && abs(start.y - particle.y) < 0.0001,
                       "a particle must start where it was spawned")
            let noTravel = burst.travel(of: particle, at: particle.birth)
            try expect(abs(noTravel.x) < 0.0001 && abs(noTravel.y) < 0.0001,
                       "a particle has not moved on the frame it is born")
            try expectEqual(burst.opacity(of: particle, at: particle.birth), 0,
                            "a particle is invisible on the frame it is born")
            // `birth + life` is a double sum, so the death frame lands within rounding of the
            // boundary rather than exactly on it.
            try expect(burst.opacity(of: particle, at: particle.birth + particle.life) < 1e-9,
                       "a particle is invisible on the frame it dies")

            let end = burst.travel(of: particle, at: burst.lifetime)
            for value in [start.x, start.y, end.x, end.y] {
                try expect(value.isFinite, "the trajectory must stay a real number")
            }
            // Damping means the particle never overshoots 1/k of its speed, so a burst can
            // never throw particles across the whole window.
            let reach = 1 / DeleteBurst.damping
            try expect(abs(end.x) <= abs(particle.vx) * reach + 0.0001,
                       "x travel \(abs(end.x)) exceeds the damped reach")
            try expect(abs(end.y) <= abs(particle.vy) * reach + 0.0001,
                       "y travel \(abs(end.y)) exceeds the damped reach")
        }

        // Opacity rises then falls, and never leaves 0…1.
        for step in 0 ... 60 {
            let t = Double(step) / 60 * burst.lifetime
            for particle in burst.particles {
                let opacity = burst.opacity(of: particle, at: t)
                try expect((0 ... 1).contains(opacity), "opacity \(opacity) at t = \(t)")
            }
            try expect(burst.isFinished(at: t) == (t >= burst.particlesEnd),
                       "isFinished disagrees with the last particle's death at t = \(t)")
        }
    }

    register("delete-burst.travels-the-same-distance-on-both-axes") {
        // Travel is in reference points on both axes, and the view scales both by the card's
        // height — that is what keeps the burst a burst on a square card instead of a plume.
        // One scalar times the velocity must therefore describe the travel on both axes.
        for seed in UInt64(0) ..< 32 {
            let burst = DeleteBurst.make(seed: seed)
            for particle in burst.particles {
                let travel = burst.travel(of: particle, at: burst.lifetime)
                let speed = (particle.vx * particle.vx + particle.vy * particle.vy).squareRoot()
                try expect(speed > 0, "a particle with no speed never moves")
                let scalar = (travel.x * particle.vx + travel.y * particle.vy) / (speed * speed)
                for (moved, velocity) in [(travel.x, particle.vx), (travel.y, particle.vy)] {
                    try expect(abs(moved - velocity * scalar) < 0.01,
                               "seed \(seed): the two axes do not share one travel scalar")
                }
                // Damping bounds how far anything can go: at most speed / k, never backwards.
                try expect(scalar >= 0 && scalar <= 1 / DeleteBurst.damping + 0.001,
                           "seed \(seed): travel scalar \(scalar) is outside the damped range")
            }
        }
    }

    register("delete-burst.blips-stay-on-their-canvas") {
        // The view draws exactly what `blips` returns, and the canvas is the card plus a fixed
        // margin. A blip outside that box would simply never be seen.
        let margin: CGFloat = 120
        for seed in UInt64(0) ..< 16 {
            let burst = DeleteBurst.make(seed: seed)
            for card in [CGSize(width: 150, height: 150), CGSize(width: 350, height: 150)] {
                for step in 0 ... 20 {
                    let t = Double(step) / 20 * burst.lifetime
                    let blips = burst.blips(at: t, cardSize: card)
                    try expect(blips.count <= burst.particles.count * (DeleteBurst.trailCount + 2),
                               "seed \(seed): more blips than trails plus heads")
                    for blip in blips {
                        try expect((0 ... 1).contains(blip.alpha),
                                   "seed \(seed): alpha \(blip.alpha) is not an opacity")
                        try expect(blip.radius > 0 && blip.radius < 12,
                                   "seed \(seed): radius \(blip.radius) is not a particle")
                        try expect(blip.x > -margin && blip.x < card.width + margin,
                                   "seed \(seed): x \(blip.x) is off the canvas")
                        try expect(blip.y > -margin && blip.y < card.height + margin,
                                   "seed \(seed): y \(blip.y) is off the canvas")
                    }
                }
            }
        }
    }

    register("delete-burst.same-shape-on-a-square-and-a-wide-card") {
        // The wide card and the square card are the same height, and both axes scale by that
        // height, so a particle's displacement in points must not depend on the card's width.
        // Scaling x by the width instead is what turned the burst into a plume on a square card.
        let burst = DeleteBurst.make(seed: 99)
        let square = CGSize(width: 150, height: 150)
        let wide = CGSize(width: 350, height: 150)
        // Early enough that every particle is alive and emitting its head.
        let t = 0.05
        let onSquare = burst.blips(at: t, cardSize: square, trails: 0)
        let onWide = burst.blips(at: t, cardSize: wide, trails: 0)
        try expectEqual(onSquare.count, burst.particles.count * 2,
                        "each particle contributes a halo and a head")
        try expectEqual(onWide.count, onSquare.count, "both cards draw the same blips")
        for index in stride(from: 0, to: onSquare.count, by: 2) {
            let particle = burst.particles[index / 2]
            let spawn = burst.spawn(of: particle)
            let squareMove = CGPoint(x: onSquare[index].x - spawn.x * square.width,
                                     y: onSquare[index].y - spawn.y * square.height)
            let wideMove = CGPoint(x: onWide[index].x - spawn.x * wide.width,
                                   y: onWide[index].y - spawn.y * wide.height)
            try expect(abs(squareMove.x - wideMove.x) < 0.01
                       && abs(squareMove.y - wideMove.y) < 0.01,
                       "particle \(index / 2) moved \(squareMove) on a square card but "
                           + "\(wideMove) on a wide one")
        }
    }

    register("delete-burst.flash-only-at-the-start") {
        let burst = DeleteBurst.make(seed: 1)
        try expectEqual(burst.flashAmount(at: -0.01), 0, "nothing flashes before the burst")
        try expect(burst.flashAmount(at: 0) > 0.9, "the flash is at its brightest at the start")
        try expectEqual(burst.flashAmount(at: burst.flash), 0, "the flash is over by its duration")
        try expectEqual(burst.flashAmount(at: burst.flash + 0.2), 0, "and stays over")
    }

    register("delete-burst.reduced-motion-skips-the-particles") {
        // The system asked for less movement: no particles at all, and the list must not sit
        // around waiting for an animation nobody can see.
        let reduced = DeleteBurst.reducedMotion()
        try expect(reduced.particles.isEmpty, "reduced motion draws no particles")
        try expectEqual(reduced.flash, 0, "and no flash either")
        try expectEqual(reduced.lifetime, DeleteBurst.reducedMotionFade, "the short path")
        try expect(reduced.lifetime < DeleteBurst.make(seed: 3).lifetime,
                   "the reduced path must be shorter than the regular one")
        try expect(reduced.isFinished(at: reduced.lifetime), "nothing is left to draw")
    }
}
