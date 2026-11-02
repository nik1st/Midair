import CoreGraphics

/// Spreads the cursor movement from one camera frame over the time until the next frame arrives.
/// The camera delivers 30 frames per second while the display draws 60-120: without spreading,
/// the cursor jumps every 33 ms and the motion looks choppy.
///
/// The remainder is released on display ticks in fractions proportional to the time left until `deadline`.
/// A new delta is added to the unreleased remainder and moves the deadline: the cursor lags behind the engine
/// by at most one frame even if frames arrive unevenly, and never goes further than the engine commanded.
struct CursorGlide: Sendable {
    /// The part of the delta not yet released, in screen points.
    private(set) var pending = CGVector.zero
    private var deadline = 0.0
    /// The tick from which the fraction for the next release is measured.
    private var lastTick: Double?

    var isIdle: Bool { pending == .zero }

    /// Delta from a new frame at `now`: together with the remainder it must be released within `duration` seconds.
    mutating func add(_ delta: CGVector, now: Double, duration: Double) {
        // The fraction is measured from the previous tick, not from the frame's arrival: otherwise the first tick
        // after a frame would release less than the others and the cursor would twitch at the camera rate.
        // After idling there is no previous tick.
        if isIdle { lastTick = now }
        pending.dx += delta.dx
        pending.dy += delta.dy
        deadline = now + max(duration, 0)
    }

    /// How much to release on display tick `now`: the remainder spread evenly up to the deadline, all of it after.
    mutating func step(now: Double) -> CGVector {
        guard !isIdle else { return .zero }
        let from = lastTick ?? now
        lastTick = now
        let fraction = deadline > from ? min(max((now - from) / (deadline - from), 0), 1) : 1
        guard fraction < 1 else { return flush() }
        let step = CGVector(dx: pending.dx * fraction, dy: pending.dy * fraction)
        pending.dx -= step.dx
        pending.dy -= step.dy
        return step
    }

    /// The whole remainder at once: before a button press the cursor must be where the engine has taken it.
    mutating func flush() -> CGVector {
        defer { pending = .zero }
        return pending
    }

    /// The remainder is no longer needed: the user grabbed the mouse, gestures are paused,
    /// or the cursor was placed at a point.
    mutating func cancel() {
        pending = .zero
    }
}
