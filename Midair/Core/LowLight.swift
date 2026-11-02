import Foundation

/// Detects darkness from the frame's mean brightness and from the illuminance the camera itself estimates.
/// Both signals are smoothed, and the mode switches only if the signal stays past the threshold for a second,
/// so a palm in front of the lens or a flash on the screen doesn't toggle it.
///
/// Exposure can't be controlled on macOS (no modes, no metering point, no ISO). Frame brightness drops late:
/// auto-exposure first pulls it up with gain, and the frame gets noisy. Lux readings show up earlier, but they
/// arrive in an undocumented frame attachment and not every camera provides them.
struct LowLightDetector: Sendable {
    /// Below the first brightness the frame is dark, above the second it is normal again: the gap prevents chatter.
    static let darkBelow = 0.2
    static let brightAbove = 0.28
    /// The same for illuminance, in lux.
    static let darkLux = 25.0
    static let brightLux = 40.0
    /// How long the signal must stay past the threshold for the mode to switch.
    static let hold = 1.0
    /// Smoothing time constant, in seconds.
    static let smoothing = 0.5
    /// After the camera starts, the frame fades in from black for about a second while auto-exposure converges:
    /// we make no darkness decision during this time.
    static let warmUp = 1.5

    private(set) var isDark = false
    /// Smoothed brightness from 0 to 1, `nil` until the first frame.
    private(set) var brightness: Double?
    /// Smoothed illuminance in lux, if the camera reports it.
    private(set) var lux: Double?
    private var firstTime: Double?
    private var lastTime: Double?
    private var crossingSince: Double?

    mutating func update(brightness sample: Double, lux luxSample: Double? = nil, time: Double) {
        let dt = lastTime.map { max(time - $0, 0) } ?? 0
        lastTime = time
        let firstTime = self.firstTime ?? time
        self.firstTime = firstTime
        let weight = 1 - exp(-dt / Self.smoothing)
        let level = brightness.map { $0 + (sample - $0) * weight } ?? sample
        brightness = level
        lux = luxSample.map { sample in lux.map { $0 + (sample - $0) * weight } ?? sample }
        let luxDark = lux.map { $0 < Self.darkLux } ?? false
        let luxBright = lux.map { $0 > Self.brightLux } ?? true
        let warm = time - firstTime >= Self.warmUp
        guard warm, isDark ? level > Self.brightAbove && luxBright : level < Self.darkBelow || luxDark else {
            crossingSince = nil
            return
        }
        let since = crossingSince ?? time
        crossingSince = since
        if time - since >= Self.hold {
            isDark.toggle()
            crossingSince = nil
        }
    }
}

/// Brightening of a dark frame before recognition.
enum Brightening {
    /// The mean brightness to raise a dark frame to.
    static let target = 0.4

    /// The exponent of the `x^gamma` curve that raises the mean brightness `brightness` to roughly `target`.
    /// Such a curve lifts shadows more than highlights and doesn't blow out a face lit by the screen.
    static func gamma(forBrightness brightness: Double) -> Double {
        guard brightness > 0, brightness < target else { return 1 }
        return max(log(target) / log(brightness), 0.35)
    }
}

/// Comparison of recognition on the same dark frames, as is and brightened.
/// Remembers only the latest pairs, so the result follows the lighting instead of accumulating since launch.
struct BrighteningComparison: Sendable {
    struct Summary: Sendable, Equatable {
        var frames: Int
        /// Fraction of frames where Vision found a hand.
        var plainFound: Double
        var brightenedFound: Double
        /// How many of the 21 joints are visible on average when a hand is found.
        var plainJoints: Double
        var brightenedJoints: Double
    }

    static let capacity = 150
    /// With fewer pairs the difference would be down to chance.
    static let minimumFrames = 30

    private struct Pair {
        var plain: Int
        var brightened: Int
    }

    private var pairs: [Pair] = []

    mutating func record(plainJoints: Int, brightenedJoints: Int) {
        pairs.append(Pair(plain: plainJoints, brightened: brightenedJoints))
        if pairs.count > Self.capacity { pairs.removeFirst(pairs.count - Self.capacity) }
    }

    var summary: Summary? {
        guard pairs.count >= Self.minimumFrames else { return nil }
        func side(_ joints: [Int]) -> (found: Double, joints: Double) {
            let found = joints.filter { $0 > 0 }
            let mean = found.isEmpty ? 0 : Double(found.reduce(0, +)) / Double(found.count)
            return (Double(found.count) / Double(joints.count), mean)
        }
        let plain = side(pairs.map(\.plain))
        let brightened = side(pairs.map(\.brightened))
        return Summary(frames: pairs.count, plainFound: plain.found, brightenedFound: brightened.found,
                       plainJoints: plain.joints, brightenedJoints: brightened.joints)
    }
}
