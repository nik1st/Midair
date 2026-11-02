import CoreGraphics
import Foundation

/// The 1€ filter (Casiez, Roussel, Vogel, CHI 2012) for a point on a plane.
///
/// On slow movements the cutoff frequency is low and jitter is damped, on fast ones it grows with speed
/// and lag is barely noticeable. Speed is computed from the vector magnitude,
/// so both axes are smoothed the same way.
struct OneEuroFilter2D {
    /// Cutoff frequency at rest, in Hz. Lower means stronger smoothing.
    var minCutoff: Double
    /// How fast the cutoff frequency grows with speed (units: Hz per frame height per second).
    var beta: Double
    var derivativeCutoff: Double = 1

    private var value: CGPoint?
    private var speed: Double = 0
    private var time: Double?

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func filter(_ point: CGPoint, time now: Double) -> CGPoint {
        guard let previous = value, let then = time, now > then else {
            value = point
            time = now
            speed = 0
            return point
        }
        let dt = now - then
        let rawSpeed = hypot(point.x - previous.x, point.y - previous.y) / dt
        speed += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawSpeed - speed)
        let a = Self.alpha(cutoff: minCutoff + beta * speed, dt: dt)
        let filtered = CGPoint(x: previous.x + a * (point.x - previous.x), y: previous.y + a * (point.y - previous.y))
        value = filtered
        time = now
        return filtered
    }

    mutating func reset() {
        value = nil
        time = nil
        speed = 0
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
