import CoreGraphics
import Foundation
import Testing

@Test func constantInputStaysPut() {
    var filter = OneEuroFilter2D(minCutoff: 1, beta: 8)
    var output = CGPoint.zero
    for frame in 0..<60 {
        output = filter.filter(CGPoint(x: 0.5, y: 0.4), time: Double(frame) / 60)
    }
    #expect(output == CGPoint(x: 0.5, y: 0.4))
}

@Test func jitterIsDamped() {
    var filter = OneEuroFilter2D(minCutoff: 1, beta: 8)
    var raw: [Double] = []
    var filtered: [Double] = []
    for frame in 0..<240 {
        // Jitter of about 2 pixels at 720p, like a typical detector on a still hand.
        let x = 0.5 + 0.003 * sin(Double(frame) * 2.3)
        raw.append(x)
        filtered.append(filter.filter(CGPoint(x: x, y: 0.4), time: Double(frame) / 60).x)
    }
    func spread(_ values: ArraySlice<Double>) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
    #expect(spread(filtered.suffix(120)) < spread(raw.suffix(120)) * 0.5)
}

@Test func fastMotionHasLittleLag() {
    var filter = OneEuroFilter2D(minCutoff: 1, beta: 8)
    var output = CGPoint.zero
    var input = CGPoint.zero
    for frame in 0..<30 {
        // 1.5 frame heights per second: a fast wave of the hand.
        input = CGPoint(x: Double(frame) * 0.025, y: 0.4)
        output = filter.filter(input, time: Double(frame) / 60)
    }
    #expect(abs(input.x - output.x) < 0.03)
}
