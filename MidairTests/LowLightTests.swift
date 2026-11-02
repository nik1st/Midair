import Foundation
import Testing

/// Frames at 30 fps with a given brightness.
private struct LightSession {
    var detector = LowLightDetector()
    var time = 0.0

    mutating func feed(_ brightness: Double, lux: Double? = nil, seconds: Double) {
        for _ in 0..<Int(seconds * 30) {
            detector.update(brightness: brightness, lux: lux, time: time)
            time += 1.0 / 30
        }
    }
}

@Test func cameraStartRampIsNotDarkness() {
    var session = LightSession()
    // After the camera starts, the frame brightens from black over a second and a half while auto-exposure converges.
    for frame in 0..<45 {
        session.feed(Double(frame) / 45 * 0.3, seconds: 1.0 / 30)
    }
    session.feed(0.45, seconds: 2)
    #expect(!session.detector.isDark)
}

@Test func darknessIsDetectedOnlyAfterItHoldsForASecond() {
    var session = LightSession()
    session.feed(0.45, seconds: 1)
    #expect(!session.detector.isDark)

    // A palm covered the lens for half a second: that is not darkness yet.
    session.feed(0.05, seconds: 0.6)
    session.feed(0.45, seconds: 1)
    #expect(!session.detector.isDark)

    session.feed(0.1, seconds: 2)
    #expect(session.detector.isDark)
}

@Test func darknessHoldsBetweenThresholds() {
    var session = LightSession()
    // The first second and a half is a warm-up: darkness isn't decided yet.
    session.feed(0.1, seconds: 3)
    #expect(session.detector.isDark)

    // Between the thresholds 0.20 and 0.28 the mode doesn't change in either direction.
    session.feed(0.24, seconds: 3)
    #expect(session.detector.isDark)

    session.feed(0.4, seconds: 2)
    #expect(!session.detector.isDark)
}

@Test func lowLuxMeansDarkEvenWhenExposureKeepsFrameBright() {
    var session = LightSession()
    // Auto-exposure lifts the frame to normal brightness, but the camera estimates the light at 12 lux.
    session.feed(0.45, lux: 12, seconds: 3)
    #expect(session.detector.isDark)

    // The light came on: the frame brightness is unchanged, but the lux reading is much higher.
    session.feed(0.45, lux: 150, seconds: 2)
    #expect(!session.detector.isDark)
}

@Test func darkerFrameGetsStrongerCurve() {
    #expect(Brightening.gamma(forBrightness: 0.5) == 1)
    let dim = Brightening.gamma(forBrightness: 0.25)
    let dark = Brightening.gamma(forBrightness: 0.1)
    #expect(dark < dim && dim < 1)
    // The curve lifts the mean brightness to the target.
    #expect(abs(pow(0.25, dim) - Brightening.target) < 0.001)
    // A nearly black frame is not lifted without limit: it is all noise.
    #expect(Brightening.gamma(forBrightness: 0.001) == 0.35)
}

@Test func brighteningComparisonNeedsEnoughFramesAndKeepsOnlyRecentOnes() throws {
    var comparison = BrighteningComparison()
    for frame in 0..<20 {
        comparison.record(plainJoints: frame.isMultiple(of: 2) ? 0 : 14, brightenedJoints: 20)
    }
    #expect(comparison.summary == nil)

    for frame in 0..<20 {
        comparison.record(plainJoints: frame.isMultiple(of: 2) ? 0 : 14, brightenedJoints: 20)
    }
    let summary = try #require(comparison.summary)
    #expect(summary.frames == 40)
    #expect(summary.plainFound == 0.5)
    #expect(summary.plainJoints == 14)
    #expect(summary.brightenedFound == 1)
    #expect(summary.brightenedJoints == 20)

    for _ in 0..<BrighteningComparison.capacity {
        comparison.record(plainJoints: 21, brightenedJoints: 0)
    }
    let recent = try #require(comparison.summary)
    #expect(recent.frames == BrighteningComparison.capacity)
    #expect(recent.plainFound == 1)
    #expect(recent.brightenedFound == 0)
}
