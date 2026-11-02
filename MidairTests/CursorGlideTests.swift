import CoreGraphics
import Foundation
import Testing

/// A 30 fps camera and a 120 Hz screen: frames every 1/30 s, ticks every 1/120 s with a phase offset `phase`.
private func run(frames: Int, delta: CGVector, phase: Double = 0.003, jitter: (Int) -> Double = { _ in 0 }) -> [CGVector] {
    var glide = CursorGlide()
    let frame = 1.0 / 30
    let tick = 1.0 / 120
    var steps: [CGVector] = []
    var nextFrame = 0
    var time = phase
    while time < Double(frames) * frame + 0.1 {
        while nextFrame < frames, Double(nextFrame) * frame + jitter(nextFrame) <= time {
            glide.add(delta, now: Double(nextFrame) * frame + jitter(nextFrame), duration: frame + 0.004)
            nextFrame += 1
        }
        steps.append(glide.step(now: time))
        time += tick
    }
    return steps
}

@Test func glideDeliversExactlyWhatTheEngineAsked() {
    let steps = run(frames: 30, delta: CGVector(dx: 12, dy: -6))
    #expect(abs(steps.map(\.dx).reduce(0, +) - 360) < 1e-9)
    #expect(abs(steps.map(\.dy).reduce(0, +) + 180) < 1e-9)
}

@Test func steadyHandGivesEvenStepsOnEveryTick() {
    let steps = run(frames: 60, delta: CGVector(dx: 12, dy: 0))
    // After ramp-up each 120 Hz tick moves the cursor by a quarter of a frame's move, with no per-frame steps.
    let middle = steps[40..<200].map(\.dx)
    #expect(middle.allSatisfy { abs($0 - 3) < 0.35 })
}

@Test func unevenFramesDoNotStallTheCursor() {
    // Frames arrive alternately early and 3 ms late: Vision doesn't always take the same time.
    let steps = run(frames: 60, delta: CGVector(dx: 12, dy: 0), jitter: { $0.isMultiple(of: 2) ? 0.003 : 0 })
    let middle = steps[40..<200].map(\.dx)
    #expect(middle.allSatisfy { $0 > 1 })
}

@Test func glideLagStaysAboutOneFrame() {
    var glide = CursorGlide()
    var delivered = 0.0
    var asked = 0.0
    var lags: [Double] = []
    for tick in 0..<240 {
        let time = Double(tick) / 120
        if tick.isMultiple(of: 4) {
            glide.add(CGVector(dx: 10, dy: 0), now: time, duration: 1.0 / 30 + 0.004)
            asked += 10
        }
        delivered += glide.step(now: time + 0.001).dx
        lags.append(asked - delivered)
    }
    // The lag is about one frame's move and does not build up over time.
    #expect(lags.max()! < 12.5)
    #expect(lags.suffix(40).max()! <= lags[40..<80].max()! + 1e-6)
}

@Test func flushHandsOverTheRestAtOnce() {
    var glide = CursorGlide()
    glide.add(CGVector(dx: 20, dy: 8), now: 0, duration: 1.0 / 30)
    _ = glide.step(now: 0.008)
    let rest = glide.flush()
    #expect(glide.isIdle)
    #expect(rest.dx > 0 && rest.dx < 20)
    #expect(glide.step(now: 0.016) == .zero)
}

@Test func lateTickDeliversEverything() {
    var glide = CursorGlide()
    glide.add(CGVector(dx: 9, dy: 3), now: 0, duration: 1.0 / 30)
    let step = glide.step(now: 0.2)
    #expect(step == CGVector(dx: 9, dy: 3))
    #expect(glide.isIdle)
}

@Test func cancelDropsTheRest() {
    var glide = CursorGlide()
    glide.add(CGVector(dx: 9, dy: 3), now: 0, duration: 1.0 / 30)
    glide.cancel()
    #expect(glide.isIdle)
    #expect(glide.step(now: 0.01) == .zero)
}
